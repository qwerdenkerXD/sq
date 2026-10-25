#!/usr/bin/env bash
# The test double behind tests/bin/{squeue,sinfo,sacct,sstat,scontrol}: renders
# whatever output format sq asked for from a hand-written fixture, and logs
# every call.
#
#   tests/bin/<tool> -> stub.sh <tool> <argv...>
#
# Environment (set by tests/run.sh; without them the stub refuses to run, so it
# can never be mistaken for Slurm):
#   SQSTUB_FIXTURE  fixture directory; the stub reads <dir>/sinfo, <dir>/sacct,
#                   <dir>/sstat, <dir>/scontrol-node, <dir>/squeue, or
#                   <dir>/squeue-all when squeue gets "-t all" (whatever its
#                   format), or <dir>/squeue-queue when it gets "-t PD,R" (sq
#                   job's whole queue), or <dir>/squeue-alloc when its format asks for
#                   StateCompact and tres-alloc (sq's allocation call, so it can
#                   fail on its own), or <dir>/squeue-tres when it asks for
#                   tres-alloc alone (sq's mirror call, ditto).  A fixture
#                   without squeue-tres answers the mirror call from the file the
#                   queue call reads: its records alone, whole (every directive
#                   but @defaults and @include is skipped), JobID from each
#                   record's A (-O JobID is %A) and tres-alloc from its
#                   tres_alloc, else N/A, which Slurm prints for a job without
#                   TRES and sq reads as no total.  A call that names jobs
#                   (squeue --jobs=LIST, sacct -j LIST) reads <file>.LIST
#                   instead where the fixture has one (squeue-all.11950,
#                   sacct.11950,11958): two calls of one tool at once, which no
#                   @step can tell apart, each get their own answer.  A
#                   fixture without scontrol-node answers scontrol -o show node
#                   from its sinfo file, as the mirror call is answered: its
#                   records alone, each node once (sinfo -N prints one record per
#                   partition), as a line of the figures sinfo has, in
#                   scontrol's order: NodeName, CPUAlloc, CPUTot, CPULoad, then
#                   the memory run whole as every Slurm prints it (RealMemory,
#                   AllocMem, 0 where sinfo has none, FreeMem, N/A where it has
#                   none, Sockets=1 Boards=1), then State=IDLE.  No
#                   MemSpecLimit, so a node reads as one without (scontrol
#                   prints it only when set).
#                   A record of scontrol-node (a line starting NodeName=) is
#                   read as Slurm printed it: before the first raw " Reason=",
#                   " Comment=" or " Extra=" (free text, which may hold
#                   anything), each raw "(^| )Key=" is a key Slurm printed, its
#                   value up to the next space, escapes then decoded; the rest
#                   is free text.  So text that looks like a key inside a value
#                   (an OS naming RealMemory=, a forged line after \n) is
#                   written with "=" as \x3d (\\x3d through a printf %b
#                   helper): no key here, an "=" once printed.  A forged line
#                   goes inside a value (\n), never on a fixture line of its
#                   own.  Refused: a key sq maps (NodeName, Arch, CPUTot,
#                   CPUEfctv, CPUAlloc, RealMemory, AllocMem, MemSpecLimit,
#                   State, Partitions) twice before the free text, and a
#                   NodeName an earlier line had, unless the fixture has a
#                   sinfo file of its own.
#                   scontrol -o show node LIST prints, per element of LIST in
#                   order, the record whose NodeName is that element (one twice
#                   in LIST, twice), else "Node <name> not found" on stdout and
#                   exit 1 at the end, as Slurm does; the records are printed
#                   where the file ends or at an @exit (one other than 0 prints
#                   no "not found" of its own: a failure where it stands), every
#                   other directive acting where it stands.  Lines that are no
#                   record are printed where they stand.
#                   sinfo -O CPUsState,NodeList,PartitionName,Memory,AllocMem,
#                   StateComplete (sq job's figure call) of a fixture without a
#                   sinfo file is made from the records of scontrol-node alone
#                   (@include and @defaults followed, every other directive
#                   skipped): one row per partition of each record with
#                   Partitions, CPUsState A/I/O/T from CPUAlloc and CPUTot, T-A
#                   other where State has DRAIN or its base is DOWN, else idle;
#                   NodeList NodeName, Memory RealMemory, AllocMem, StateComplete
#                   State in lower case.  A sinfo file wins, and needs those
#                   fields.
#                   scontrol --json show node reads <dir>/scontrol-node.json,
#                   printed verbatim (every line but a directive, blank ones
#                   too, no escape decoded); without it, ONE document is made
#                   in json-c's pretty layout from the NodeName= records of
#                   scontrol-node (their keys as above, the first of a name
#                   counting): NodeName -> name, CPUTot -> cpus,
#                   CPUEfctv -> effective_cpus, CPUAlloc -> alloc_cpus,
#                   RealMemory -> real_memory, AllocMem -> alloc_memory,
#                   MemSpecLimit -> specialized_memory (0 when absent), State
#                   split on "+" and Partitions on "," into arrays; a figure
#                   that is no number becomes a string, a key absent no member,
#                   and the free text, decoded, the reason.
#                   Without scontrol-node, from the lines derived from sinfo as
#                   for -o (without the memory run's added fields and State, as
#                   before).  The file's directives act on it as on -o (the
#                   document is printed where the file ends or at @exit)
#   SQSTUB_JSONC    the json-c whose pretty layout a made document has: 0.17
#                   (the default, as bioserver: an empty [] on one line), 0.16
#                   (json-c 0.14-0.16: an empty array as "[" and "]" lines) or
#                   0.13 (json-c 0.13 and older: depth d indented 2d+1, the
#                   last line " }")
#   SQSTUB_NOJSON   1: scontrol --json fails as Slurm 22.05's does, before
#                   any directive: "scontrol: unrecognized option '--json'",
#                   exit 1
#   SQSTUB_LOG      file every invocation is appended to, one line per call:
#                   CALL <tool> <argv, %q-quoted> <VAR=%q value | VAR(unset)>...
#                   (the fixed list below, then every other SQUEUE_*, SACCT_*,
#                   SCONTROL_* and SINFO_* that is set), and a STUBERROR line for every refusal of the stub
#                   itself.  Its directory is the run's own (tests/run.sh makes
#                   one per run): the call counter of @step and the files of
#                   @file live there, and \{run} in a value names it
#   SQSTUB_IGNORE_TERM  a tool name: that tool ignores SIGTERM, so sq's timeout
#                   has to kill it, and timeout then exits 137, not 124
#   SQSTUB_SKEW     seconds the clock steps once the stub has answered: -1
#                   prints every \{now...} and \{epoch...} 1 s later, as a
#                   clock stepped back 1 s would leave it for sq (default 0)
#
# Formats, as the real tools take them (see tests/FAITHFULNESS.md):
#   sinfo   -o FMT or -O FMT             %<letter> grammar or Field:0suffix
#                                        grammar, needs -h and -N; --local
#                                        accepted (logged)
#   squeue  -o FMT, -O FMT, else $SQUEUE_FORMAT, else $SQUEUE_FORMAT2
#           (%<letter> grammar or Field:suffix grammar), needs -h
#   sacct   -o F1,F2,... with -p or -P and -n, --delimiter=D (default "|")
#   sstat   -o F1,F2,... with -p or -P, -n, -a and --noconvert
#   scontrol -o show node [LIST]: each record line of the file printed as
#                                        written (escapes decoded; a line with
#                                        no backslash as it is), as scontrol's
#                                        one line per node has no format to
#                                        render; with LIST, see SQSTUB_FIXTURE
#   scontrol --json show node: see SQSTUB_FIXTURE
# Anything the stub cannot render exactly the way Slurm would (field widths,
# headers, unsized -O fields, an unknown option) is refused with exit 97 and a
# STUBERROR line, never approximated.
#
# Fixture format, one record per line, fields by name:
#   i=1001; j=train; u=alice; t=R          letters for %-formats, Slurm's field
#   JobID=5000_1; State=FAILED             names (any case) for -O and sacct;
#   tres_alloc=cpu=1,mem=4G                a "-" in a name is written "_"
# Fields are separated by ";", spaces around names and values are ignored.
# Escapes in values: \n newline  \t tab  \r CR  \e ESC  \a BEL  \s space
#                    \xHH any byte  \; semicolon  \\ backslash
#                    \{run} the run's directory (see SQSTUB_LOG)
#                    \{now-1h30m} the time that long before the stub runs
#                    (\{now}, \{now+2d}; d h m s), as SLURM_TIME_FORMAT=standard
#                    prints it: write every time sq reads an age from this way,
#                    so the screen does not change with the date of the run
#                    \{epoch-1h30m} the same, as an integer epoch, as
#                    SLURM_TIME_FORMAT=%s prints it (sq job asks for that)
# Lines starting with "#" and blank lines are ignored.  Directives, run in order:
#   @defaults k=v; ...  fields every later record has unless it sets them
#   @include FILE       read FILE (relative to this file, or absolute) here
#   @trail TEXT         append TEXT after the NEXT record's last separator: a
#                       record that does not end where its format says
#   @cut                print the NEXT record without its last separator and
#                       its newline: a stream cut off as that record ends
#   @raw TEXT           print TEXT (escapes decoded) as one output line
#   @stderr TEXT        print TEXT (escapes decoded) on stderr
#   @exit N             stop here with exit code N
#   @hang [SECONDS]     block for SECONDS (default 30; 2.9 too): exercises sq's timeout
#   @step N             what follows, up to the next @step, answers the N-th
#                       call of this tool with this format in this run, and
#                       every later one until a higher @step takes over; what
#                       comes before the first @step answers every call.  A
#                       call before the first step gets only that part.  Only
#                       in the tool's own file, never in an @include (and an
#                       @signal, read before any step is, fires on every call)
#   @file OP PATH [ARG] a side effect on PATH, relative to the run's directory
#                       (escapes decoded; no "..", never absolute), when the
#                       call is served: in a step only on the call that starts
#                       it.  OP: create (a new file holding ARG), append ARG,
#                       truncate, chmod MODE, touch DATE (touch -d DATE), fifo
#                       (a FIFO nothing writes)
#   @signal N           die by signal N before printing anything, as a crash
#                       does (no core is dumped).  Read by this script, not
#                       the renderer, whose gawk would catch a SIGSEGV itself,
#                       so it counts on any line of the tool's own file (the
#                       first one, before anything else runs), never from an
#                       @include
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
# composed first and appended in one write, as sq job asks several tools at
# once and their lines must not mix
line=$(printf 'CALL\t%s\t' "$tool"; [ $# -gt 0 ] && printf '%q ' "$@"
	for v in SQUEUE_FORMAT SQUEUE_FORMAT2 SLURM_TIME_FORMAT SLURM_BITSTR_LEN \
	         SQ_NONCE SQ_NONCE2 SQ_NONCE3 SLURM_CLUSTERS SLURM_JSON; do
		if [ -n "${!v+set}" ]; then printf '\t%s=%q' "$v" "${!v}"
		else printf '\t%s(unset)' "$v"; fi
	done
	for v in $(compgen -e); do      # any other squeue, sacct, scontrol or sinfo setting that reached it
		case $v in SQUEUE_FORMAT|SQUEUE_FORMAT2) ;; SQUEUE_*|SACCT_*|SCONTROL_*|SINFO_*) printf '\t%s=%q' "$v" "${!v}" ;; esac
	done)
printf '%s\n' "$line" >> "$SQSTUB_LOG"

# ---- argv: every option sq can send, nothing else --------------------------
mode=; fmt=; noheader=0; nodes=0; trail=1; delim='|'; parsable=0; allsteps=0; noconvert=0; mirror=0 derive=0 json=0 figrows=0
cmd_o=; cmd_O=; states=; jobs=; show=; nodelist=; listed=0
need_value() { [ $# -ge 2 ] || refuse "$1 needs a value"; }
while [ $# -gt 0 ]; do
	a=$1; v=
	case $tool:$a in
		# a value attached as --opt=value or -Xvalue
		*:--*=*) v=${a#*=}; a=${a%%=*} ;;
		squeue:-[SturpAqjMnwLRoO]?*|sacct:-[SEurAqjMo]?*|sinfo:-[oO]?*|sstat:-[jo]?*)
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
		sinfo:--local)             shift_n=1 ;;     # logged; one cluster is all the stub has

		squeue:-h|squeue:--noheader) noheader=1; shift_n=1 ;;
		squeue:-o|squeue:--format)   take "$@"; cmd_o=$val ;;
		squeue:-O|squeue:--Format)   take "$@"; cmd_O=$val ;;
		squeue:-t|squeue:--states|squeue:--state) take "$@"; states=$val ;;
		squeue:-j|squeue:--job|squeue:--jobs) take "$@"; jobs=$val ;;   # picks <file>.LIST, if any
		squeue:-S|squeue:--sort|squeue:-u|squeue:--user|squeue:--users|\
		squeue:-p|squeue:--partition|squeue:--partitions|\
		squeue:-A|squeue:--account|squeue:--accounts|squeue:-q|squeue:--qos|\
		squeue:-M|squeue:--cluster|squeue:--clusters|\
		squeue:-n|squeue:--name|squeue:-w|squeue:--nodelist|squeue:--node|squeue:--nodes|\
		squeue:-L|squeue:--licenses|squeue:--license|squeue:-R|squeue:--reservation)
			take "$@" ;;              # a filter: logged above, never applied
		squeue:--me|squeue:-a|squeue:--all|squeue:--hide|\
		squeue:-P|squeue:--priority|squeue:--federation|squeue:--local|squeue:--sibling)
			[ "$has" = 0 ] || refuse "$a takes no value"; shift_n=1 ;;
		# these change what squeue prints (one row per task; unconverted sizes):
		# rendered as written, so a fixture given them is written that way
		squeue:-r|squeue:--array|squeue:--noconvert)
			[ "$has" = 0 ] || refuse "$a takes no value"; shift_n=1 ;;

		sacct:-p|sacct:--parsable)   parsable=1; trail=1; shift_n=1 ;;
		sacct:-P|sacct:--parsable2)  parsable=1; trail=0; shift_n=1 ;;
		sacct:-n|sacct:--noheader)   noheader=1; shift_n=1 ;;
		sacct:-a|sacct:--allusers) shift_n=1 ;;
		# sq job asks for unconverted sizes (bytes for usage, M for TRES), and a
		# fixture writes them that way; --array (a pending array's remainder one
		# row per task) is rendered as written too
		sacct:--noconvert|sacct:--array) shift_n=1 ;;
		# which cluster's jobs: logged, never applied, as a filter
		sacct:--local|sacct:--federation) shift_n=1 ;;
		# refused like any option the stub does not render: sacct -X drops the
		# step rows, the only ones carrying a signal (seen live)
		sacct:--delimiter)           take "$@"; delim=$val ;;
		sacct:-o|sacct:--format)     take "$@"; cmd_o=$val ;;
		sacct:-j|sacct:--jobs)       take "$@"; jobs=$val ;;   # picks <file>.LIST, if any
		sacct:-S|sacct:--starttime|sacct:-E|sacct:--endtime|sacct:-u|sacct:--user|\
		sacct:-r|sacct:--partition|sacct:-A|sacct:--account|sacct:--accounts|\
		sacct:-q|sacct:--qos|sacct:-M|sacct:--clusters)
			take "$@" ;;              # a filter: logged above, never applied

		# sstat as sq asks it: --noconvert and -a are required, as without them
		# sstat prints K-suffixed sizes and skips the .batch step, neither of
		# which is emulated
		sstat:-p|sstat:--parsable)   parsable=1; trail=1; shift_n=1 ;;
		sstat:-P|sstat:--parsable2)  parsable=1; trail=0; shift_n=1 ;;
		sstat:-n|sstat:--noheader)   noheader=1; shift_n=1 ;;
		sstat:-a|sstat:--allsteps)   allsteps=1; shift_n=1 ;;
		sstat:--noconvert)           noconvert=1; shift_n=1 ;;
		sstat:-o|sstat:--format|sstat:--fields) take "$@"; cmd_o=$val ;;
		sstat:-j|sstat:--jobs)       take "$@" ;;   # a filter: logged above, never applied

		# scontrol as sq asks it: --json or -o, then show node (or nodes)
		scontrol:-o|scontrol:--oneliner) noheader=1; shift_n=1 ;;
		scontrol:--json)             [ "$has" = 0 ] || refuse "--json=PARSER is not emulated"; json=1; shift_n=1 ;;
		scontrol:show)               [ -z "$show" ] || refuse "show twice"; show=what; shift_n=1 ;;
		scontrol:node|scontrol:nodes) [ "$show" = what ] || refuse "'$a' without show"; show=node; shift_n=1 ;;
		# show node LIST: the nodes named, in that order (scontrol -o only)
		scontrol:[!-]*) [ "$show" = node ] && [ $listed = 0 ] || refuse "argument '$a' is not emulated"
		                nodelist=$a; listed=1; shift_n=1 ;;

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
		file=sinfo
		# sq job's figure call, of a fixture with no sinfo of its own: its rows
		# from the scontrol-node records alone (render.awk, figure_rows)
		[ -f "$SQSTUB_FIXTURE/sinfo" ] || [ ! -f "$SQSTUB_FIXTURE/scontrol-node" ] || { file=scontrol-node; figrows=1; } ;;
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
		# question (finished jobs too), not a narrower one; "-t PD,R" is sq
		# job's whole queue, a question of its own as well
		case $states in [Aa][Ll][Ll]) file=squeue-all ;; PD,R) file=squeue-queue ;; *) file=squeue ;; esac
		# sq's allocation call and its mirror call are questions of their own
		# too, answered apart, so a case can fail either alone; but "-t all"
		# and "-t PD,R" first, whatever the format holds (sq job asks for
		# tres-alloc with both)
		[ "$file" != squeue ] ||
		case $mode:$fmt in
			long:*[Ss][Tt][Aa][Tt][Ee][Cc][Oo][Mm][Pp][Aa][Cc][Tt]*[Tt][Rr][Ee][Ss]-[Aa][Ll][Ll][Oo][Cc]*) file=squeue-alloc ;;
			long:*[Tt][Rr][Ee][Ss]-[Aa][Ll][Ll][Oo][Cc]*)
				if [ -f "$SQSTUB_FIXTURE/squeue-tres" ]; then file=squeue-tres; else mirror=1; fi ;;
		esac ;;
	sacct)
		[ $parsable = 1 ] || refuse "only -p/-P output is emulated"
		[ $noheader = 1 ] || refuse "header lines are not emulated: pass -n"
		[ -n "$cmd_o" ]   || refuse "sacct's default format is not emulated: pass -o"
		mode=sacct; fmt=$cmd_o; file=sacct ;;
	sstat)   # rendered like sacct -p/-P, from <fixture>/sstat
		[ $parsable = 1 ]  || refuse "only -p/-P output is emulated"
		[ $noheader = 1 ]  || refuse "header lines are not emulated: pass -n"
		[ $allsteps = 1 ]  || refuse "without -a sstat skips the .batch step: not emulated"
		[ $noconvert = 1 ] || refuse "converted (K-suffixed) sizes are not emulated: pass --noconvert"
		[ -n "$cmd_o" ]    || refuse "sstat's default format is not emulated: pass -o"
		mode=sacct; fmt=$cmd_o; file=sstat ;;
	scontrol)
		[ "$show" = node ]  || refuse "only 'show node' is emulated"
		if [ $json = 1 ]; then
			[ $noheader = 0 ] || refuse "--json and -o together are not emulated"
			[ $listed = 0 ]   || refuse "--json show node LIST is not emulated"
			if [ "${SQSTUB_NOJSON:-}" = 1 ]; then   # Slurm 22.05's getopt, then its hint
				printf '%s\n' "scontrol: unrecognized option '--json'" 'Try "scontrol --help" for more information' >&2
				exit 1
			fi
			case ${SQSTUB_JSONC:-0.17} in 0.13|0.16|0.17) ;; *) refuse "SQSTUB_JSONC is not 0.13, 0.16 or 0.17" ;; esac
			mode=json; fmt="--json show node"; file=scontrol-node.json
			if [ -f "$SQSTUB_FIXTURE/scontrol-node.json" ]; then mode=jsonfile
			elif [ -f "$SQSTUB_FIXTURE/scontrol-node" ]; then file=scontrol-node
			else file=sinfo; derive=1
			fi
		else
			[ $noheader = 1 ]   || refuse "only the one-line form (-o) or --json is emulated"
			mode=raw; fmt="show node"; file=scontrol-node
			[ $listed = 0 ] || [ -n "$nodelist" ] || refuse "an empty node list is not emulated"
			[ -f "$SQSTUB_FIXTURE/scontrol-node" ] || { file=sinfo; derive=1; }
		fi ;;
	*) refuse "unknown tool" ;;
esac

path=$SQSTUB_FIXTURE/$file
[ -z "$jobs" ] || [ ! -f "$path.$jobs" ] || path=$path.$jobs
[ -f "$path" ] || refuse "fixture $path does not exist (an unexpected call?)"

# which call of this tool with this format this is, counted per run (two
# processes may ask at once, hence the lock)
rundir=${SQSTUB_LOG%/*}
counter=$rundir/.stubcalls.$tool.$(printf '%s' "$fmt" | cksum | cut -d' ' -f1)
{
	flock 9 || refuse "cannot lock $counter"
	call=$(cat "$counter" 2>/dev/null); call=$(( ${call:-0} + 1 ))
	printf '%s\n' "$call" > "$counter"
} 9>> "$counter.lock"

# an ignored signal stays ignored across exec, and in the sleep of an @hang
[ "${SQSTUB_IGNORE_TERM:-}" != "$tool" ] || trap '' TERM
# a core limit of exactly 1 byte dumps nothing, even where cores go to a pipe
# (systemd-coredump, WSL), which ignore a limit of 0; bash's ulimit counts in
# blocks, hence prlimit, and without it 0 still stops a core file
sig=; [ "$mirror" = 1 ] || [ "$derive" = 1 ] || [ "$figrows" = 1 ] ||   # a call answered from another tool's file: records alone
	sig=$(LC_ALL=C sed -n 's/^@signal[[:space:]]\{1,\}\([0-9]\{1,\}\)[[:space:]]*$/\1/p' "$path" | head -n 1)
if [ -n "$sig" ]; then
	prlimit --pid $$ --core=1 2>/dev/null || ulimit -c 0 2>/dev/null
	kill -"$sig" $$; refuse "still alive after @signal $sig"
fi
own_sinfo=0; [ ! -f "$SQSTUB_FIXTURE/sinfo" ] || own_sinfo=1
[ $listed = 0 ] || export STUB_LIST=$nodelist
STUB_TOOL=$tool STUB_MODE=$mode STUB_FMT=$fmt STUB_DELIM=$delim STUB_TRAIL=$trail STUB_FIGROWS=$figrows STUB_OWN_SINFO=$own_sinfo \
STUB_FILE=$path STUB_MIRROR=$mirror STUB_DERIVE=$derive STUB_CALL=$call STUB_RUN=$rundir LC_ALL=C exec gawk -f "$stubdir/json.awk" -f "$stubdir/render.awk"
