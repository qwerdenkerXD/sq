#!/usr/bin/env bash
# The test double behind tests/bin/{squeue,sinfo,sacct}: renders whatever output
# format sq asked for from a hand-written fixture, and logs every call.
#
#   tests/bin/<tool> -> stub.sh <tool> <argv...>
#
# Environment (set by tests/run.sh; without them the stub refuses to run, so it
# can never be mistaken for Slurm):
#   SQSTUB_FIXTURE  fixture directory; the stub reads <dir>/sinfo, <dir>/sacct,
#                   <dir>/squeue, or <dir>/squeue-all when squeue gets "-t all"
#   SQSTUB_LOG      file every invocation is appended to, one line per call:
#                   CALL <tool> <argv, %q-quoted> <VAR=%q value | VAR(unset)>...
#                   and a STUBERROR line for every refusal of the stub itself
#
# Formats, as the real tools take them (see tests/FAITHFULNESS.md):
#   sinfo   -o FMT or -O FMT             %<letter> grammar or Field:0suffix
#                                        grammar, needs -h and -N
#   squeue  -o FMT, -O FMT, else $SQUEUE_FORMAT, else $SQUEUE_FORMAT2
#           (%<letter> grammar or Field:suffix grammar), needs -h
#   sacct   -o F1,F2,... with -p or -P and -n, --delimiter=D (default "|")
# Anything the stub cannot render exactly the way Slurm would (field widths,
# headers, unsized -O fields, an unknown option) is refused with exit 97 and a
# STUBERROR line, never approximated.
#
# Fixture format, one record per line, fields by name:
#   i=1001; j=train; u=alice; t=R          letters for %-formats, Slurm's field
#   JobID=5000_1; State=FAILED             names (any case) for -O and sacct
# Fields are separated by ";", spaces around names and values are ignored.
# Escapes in values: \n newline  \t tab  \r CR  \e ESC  \a BEL  \s space
#                    \xHH any byte  \; semicolon  \\ backslash
# Lines starting with "#" and blank lines are ignored.  Directives, run in order:
#   @defaults k=v; ...  fields every later record has unless it sets them
#   @include FILE       read FILE (relative to this file, or absolute) here
#   @trail TEXT         append TEXT after the NEXT record's last separator: a
#                       record that does not end where its format says
#   @raw TEXT           print TEXT (escapes decoded) as one output line
#   @stderr TEXT        print TEXT (escapes decoded) on stderr
#   @exit N             stop here with exit code N
#   @hang [SECONDS]     block for SECONDS (default 30): exercises sq's timeout
# Records are printed in file order: the stub sorts and filters nothing.

set -u
tool=$1; shift
stubdir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

refuse() {
	printf 'stub %s: %s\n' "$tool" "$*" >&2
	[ -n "${SQSTUB_LOG:-}" ] && printf 'STUBERROR\t%s\t%s\n' "$tool" "$*" >> "$SQSTUB_LOG"
	exit 97
}

[ -n "${SQSTUB_LOG:-}" ]     || refuse "SQSTUB_LOG is not set: this is sq's test stub, not Slurm"
[ -n "${SQSTUB_FIXTURE:-}" ] || refuse "SQSTUB_FIXTURE is not set: this is sq's test stub, not Slurm"

# ---- the log line, written before anything can fail -------------------------
{
	printf 'CALL\t%s\t' "$tool"
	[ $# -gt 0 ] && printf '%q ' "$@"
	for v in SQUEUE_FORMAT SQUEUE_FORMAT2 SLURM_TIME_FORMAT SLURM_BITSTR_LEN \
	         SQ_NONCE SQ_NONCE2 SQ_NONCE3; do
		if [ -n "${!v+set}" ]; then printf '\t%s=%q' "$v" "${!v}"
		else printf '\t%s(unset)' "$v"; fi
	done
	printf '\n'
} >> "$SQSTUB_LOG"

# ---- argv: every option sq can send, nothing else --------------------------
mode=; fmt=; noheader=0; nodes=0; trail=1; delim='|'; parsable=0
cmd_o=; cmd_O=; states=
need_value() { [ $# -ge 2 ] || refuse "$1 needs a value"; }
while [ $# -gt 0 ]; do
	a=$1; v=
	case $tool:$a in
		# a value attached as --opt=value or -Xvalue
		*:--*=*) v=${a#*=}; a=${a%%=*} ;;
		squeue:-[SturpAqjMnwLRoO]?*|sacct:-[SEurAqjMo]?*|sinfo:-[oO]?*)
			v=${a#??}; a=${a:0:2} ;;
		*) v= ;;
	esac
	has=$([ "$1" != "$a" ] && echo 1 || echo 0)
	take() {   # the option's value: attached, or the next argument
		if [ "$has" = 1 ]; then val=$v; shift_n=1
		else need_value "$@"; val=$2; shift_n=2; fi
	}
	case $tool:$a in
		sinfo:-h|sinfo:--noheader) noheader=1; shift_n=1 ;;
		sinfo:-N|sinfo:--Node)     nodes=1; shift_n=1 ;;
		sinfo:-hN|sinfo:-Nh)       noheader=1; nodes=1; shift_n=1 ;;
		sinfo:-o|sinfo:--format)   take "$@"; cmd_o=$val ;;
		sinfo:-O|sinfo:--Format)   take "$@"; cmd_O=$val ;;

		squeue:-h|squeue:--noheader) noheader=1; shift_n=1 ;;
		squeue:-o|squeue:--format)   take "$@"; cmd_o=$val ;;
		squeue:-O|squeue:--Format)   take "$@"; cmd_O=$val ;;
		squeue:-t|squeue:--states|squeue:--state) take "$@"; states=$val ;;
		squeue:-S|squeue:--sort|squeue:-u|squeue:--user|squeue:--users|\
		squeue:-p|squeue:--partition|squeue:--partitions|\
		squeue:-A|squeue:--account|squeue:--accounts|squeue:-q|squeue:--qos|\
		squeue:-j|squeue:--job|squeue:--jobs|squeue:-M|squeue:--cluster|squeue:--clusters|\
		squeue:-n|squeue:--name|squeue:-w|squeue:--nodelist|squeue:--node|squeue:--nodes|\
		squeue:-L|squeue:--licenses|squeue:--license|squeue:-R|squeue:--reservation)
			take "$@" ;;              # a filter: logged above, never applied
		squeue:--me|squeue:--all|squeue:--hide|\
		squeue:--priority|squeue:--federation|squeue:--local|squeue:--sibling)
			[ "$has" = 0 ] || refuse "$a takes no value"; shift_n=1 ;;

		sacct:-p|sacct:--parsable)   parsable=1; trail=1; shift_n=1 ;;
		sacct:-P|sacct:--parsable2)  parsable=1; trail=0; shift_n=1 ;;
		sacct:-n|sacct:--noheader)   noheader=1; shift_n=1 ;;
		sacct:-a|sacct:--allusers) shift_n=1 ;;
		# refused like any option the stub does not render: --array and --noconvert
		# change what squeue prints (one row per task; unconverted sizes), and sacct
		# -X drops the step rows, the only ones carrying a signal (seen live)
		sacct:--delimiter)           take "$@"; delim=$val ;;
		sacct:-o|sacct:--format)     take "$@"; cmd_o=$val ;;
		sacct:-S|sacct:--starttime|sacct:-E|sacct:--endtime|sacct:-u|sacct:--user|\
		sacct:-r|sacct:--partition|sacct:-A|sacct:--account|sacct:--accounts|\
		sacct:-q|sacct:--qos|sacct:-j|sacct:--jobs|sacct:-M|sacct:--clusters)
			take "$@" ;;              # a filter: logged above, never applied

		*) refuse "option '$1' is not emulated" ;;
	esac
	shift "$shift_n"
done

# ---- which format, in which grammar ----------------------------------------
case $tool in
	sinfo)
		[ $noheader = 1 ] || refuse "header lines are not emulated: pass -h"
		[ $nodes = 1 ]    || refuse "only the node-oriented (-N) listing is emulated"
		# measured on 23.11: an -o after -O is parsed in -O's grammar
		if   [ -n "$cmd_o" ] && [ -n "$cmd_O" ]; then refuse "both -o and -O given"
		elif [ -n "$cmd_o" ]; then mode=pct;  fmt=$cmd_o
		elif [ -n "$cmd_O" ]; then mode=long; fmt=$cmd_O
		else refuse "sinfo's default format is not emulated: pass -o or -O"
		fi
		file=sinfo ;;
	squeue)
		[ $noheader = 1 ] || refuse "header lines are not emulated: pass -h"
		# precedence measured on 23.11: the command line beats the environment,
		# and SQUEUE_FORMAT beats SQUEUE_FORMAT2 when both are set
		if   [ -n "$cmd_o" ] && [ -n "$cmd_O" ]; then refuse "both -o and -O given"
		elif [ -n "$cmd_o" ]; then mode=pct;  fmt=$cmd_o
		elif [ -n "$cmd_O" ]; then mode=long; fmt=$cmd_O
		elif [ -n "${SQUEUE_FORMAT:-}" ];  then mode=pct;  fmt=$SQUEUE_FORMAT
		elif [ -n "${SQUEUE_FORMAT2:-}" ]; then mode=long; fmt=$SQUEUE_FORMAT2
		else refuse "squeue's default format is not emulated: set a format"
		fi
		# "-t all" is the one filter that picks the fixture: it is a different
		# question (finished jobs too), not a narrower one
		case $states in [Aa][Ll][Ll]) file=squeue-all ;; *) file=squeue ;; esac ;;
	sacct)
		[ $parsable = 1 ] || refuse "only -p/-P output is emulated"
		[ $noheader = 1 ] || refuse "header lines are not emulated: pass -n"
		[ -n "$cmd_o" ]   || refuse "sacct's default format is not emulated: pass -o"
		mode=sacct; fmt=$cmd_o; file=sacct ;;
	*) refuse "unknown tool" ;;
esac

path=$SQSTUB_FIXTURE/$file
[ -f "$path" ] || refuse "fixture $path does not exist (an unexpected call?)"

STUB_TOOL=$tool STUB_MODE=$mode STUB_FMT=$fmt STUB_DELIM=$delim STUB_TRAIL=$trail \
STUB_FILE=$path LC_ALL=C exec gawk -f "$stubdir/render.awk"
