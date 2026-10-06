#!/usr/bin/env bash
# sq's regression suite: sq against stubbed Slurm clients, asserting properties
# of its output (counts, rows, captions, escapes, widths, exit codes), never a
# snapshot of it.
#
#   tests/run.sh [-k|--keep] [NAME...]     NAME: run only the case of that name
#
# Needs bash, gawk, coreutils, and util-linux `script` and `setsid` for the
# terminal cases.  The stubs in tests/bin stand in for squeue/sinfo/sacct
# (tests/lib/stub.sh says how, tests/FAITHFULNESS.md how they were checked
# against the real ones); tests/bin/stty only logs and runs the real stty.
# Every case must see a stub answer, so the suite cannot pass against a real
# Slurm by accident.
#
# Results: PASS, FAIL, XFAIL (a known defect, still there, in the documented
# way) and XPASS (a known defect no longer reproduces: remove its xfail marker).
# The run fails on any FAIL or XPASS.
#
# Known gaps, left out on purpose because they are cosmetic: right alignment
# of numeric columns, the truncation of a long drain reason, the bar glyphs.

set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sq=${SQ_UNDER_TEST:-${here%/*}/sq}    # SQ_UNDER_TEST: another build of sq, e.g. an installed one
fixtures=$here/fixtures
keep=0; only=()
for a in "$@"; do
	case $a in
		-k|--keep) keep=1 ;;
		-h|--help) sed -n '2,16{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
		-*) printf 'run.sh: unknown option %s\n' "$a" >&2; exit 2 ;;
		*) only+=("$a") ;;
	esac
done

# sq measures widths with gawk's length(), which counts characters only in a
# UTF-8 locale; pick one that exists, rather than inherit whatever the caller has
utf8=
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
	LC_ALL=$l gawk 'BEGIN { exit length("…") != 1 }' 2>/dev/null && { utf8=$l; break; }
done
[ -n "$utf8" ] || { echo "run.sh: no UTF-8 locale available (tried C.UTF-8, en_US.UTF-8)" >&2; exit 2; }

# TMPDIR is honoured; with -k the evidence stays there, under a recognisable name
work=$(mktemp -d "${TMPDIR:-/tmp}/sq-tests.XXXXXX") || exit 2
if [ $keep = 1 ]; then echo "evidence kept in $work"; else trap 'rm -rf "$work"' EXIT; fi
# a killed run still runs the EXIT trap, so its work dir goes too
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

ESC=$'\033'

# ============================================================================
# running sq
# ============================================================================
# sq_run FIXTURE [VAR=value | -VAR]... -- [sq args...]
# Runs sq in a clean environment: the stubs first on PATH, a fresh HOME (the
# bell's state file lives under it), a small timeout and a fixed size; VAR=value
# adds or overrides a variable, -VAR removes one.  --no-bell is always passed.
# NOTTY=1 runs sq in a new session (setsid), so it has no controlling terminal.
# Leaves OUT, ERR, LOG (the stub log) and RC for the assertions below.
sq_run() {
	local fixture=$1; shift
	local -A env=([PATH]="$here/bin:$PATH" [LC_ALL]=$utf8
	              [SQSTUB_FIXTURE]=$([[ $fixture == /* ]] && echo "$fixture" || echo "$fixtures/$fixture")
	              [SQ_TIMEOUT]=3 [SQ_WIDTH]=120 [SQ_HEIGHT]=50)
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		case $1 in -*) unset "env[${1#-}]" ;; *=*) env[${1%%=*}]=${1#*=} ;; esac
		shift
	done
	[ $# -gt 0 ] && shift
	run_n=$((run_n+1))
	RUN=$T_DIR/run$run_n; mkdir -p "$RUN/home"
	OUT=$RUN/out ERR=$RUN/err LOG=$RUN/log; : > "$LOG"
	env[HOME]=$RUN/home; env[SQSTUB_LOG]=$LOG
	local -a envlist=(); local k
	# sq's own mktemp -d lands under the run, so a sq killed before its EXIT trap
	# (the 30s bound below) leaves nothing behind once $work is removed
	mkdir -p "$RUN/tmp"; env[TMPDIR]=$RUN/tmp
	for k in "${!env[@]}"; do envlist+=("$k=${env[$k]}"); done
	if [ -n "${PTY:-}" ]; then pty_exec "${envlist[@]}" -- "$@"
	else  # bounded, so a hanging sq fails its case instead of hanging the suite;
		# setsid outside timeout, so a hanging sq stays timeout's own child
		env -i "${envlist[@]}" ${NOTTY:+setsid -w} timeout -k 2 30 "$sq" --no-bell "$@" > "$OUT" 2> "$ERR" < /dev/null; RC=$?
		[ $RC -ne 124 ] || T_FAIL+=("sq did not finish within 30s")
	fi
	note_run
}

# The pty variant: sq on a pseudo-terminal of PTY_ROWS x PTY_COLS made by
# util-linux script, so [ -t 1 ] and tput see a terminal.  stdout of script is
# the terminal's output, so OUT gets CRs and colour; plain() takes them out.
# PTY_STDIN=FILE gives sq that stdin instead of the terminal.
pty_exec() {
	local -a envlist=()
	while [ "$1" != -- ]; do envlist+=("$1"); shift; done; shift
	if ! command -v script > /dev/null; then
		T_FAIL+=("util-linux script is not installed (needed for the pty cases)"); RC=127; : > "$OUT"; return
	fi
	local inner
	inner="stty rows $PTY_ROWS cols $PTY_COLS; exec $(printf '%q ' "$sq" --no-bell "$@")"
	[ -n "${PTY_STDIN:-}" ] && inner="$inner < $(printf '%q' "$PTY_STDIN")"
	# --foreground: without it timeout stops script's child with SIGTTOU in the pty
	env -i "${envlist[@]}" SHELL=/bin/sh \
		timeout --foreground -k 2 20 script -qec "$inner" /dev/null > "$OUT" 2> "$ERR" < /dev/null
	RC=$?
}

note_run() {   # every run: count the stub calls, and any stub refusal is a FAIL
	local n; n=$(grep -c '^CALL' "$LOG")
	T_CALLS=$((T_CALLS + n))
	if grep -q '^STUBERROR' "$LOG"; then
		T_FAIL+=("stub refused: $(grep -m1 '^STUBERROR' "$LOG" | cut -f2- | tr '\t' ' ')")
	fi
}

# ============================================================================
# reading the output (plain text; pty output goes through plain() first)
# ============================================================================
plain() { gawk '{ gsub(/\033\[[0-9;]*m/, ""); gsub(/\r/, ""); print }' "$OUT"; }
has()   { plain | grep -qF -- "$1"; }
lacks() { ! has "$1"; }
lines_matching() { plain | grep -E -- "$1"; }          # ERE over whole lines
matches()        { plain | grep -qE -- "$1"; }
escapes()  { LC_ALL=C tr -cd "$ESC" < "$OUT" | wc -c; }
bels()     { LC_ALL=C tr -cd '\a' < "$OUT" | wc -c; }
# every ESC byte starts an SGR sequence of sq's own shape, so none came from data
escapes_all_sgr() {
	local sgr; sgr=$(LC_ALL=C grep -o "$ESC\[[0-9;]*m" "$OUT" | wc -l)
	[ "$sgr" -eq "$(escapes)" ]
}
# the widest line in characters, colour and CRs removed
width() { plain | LC_ALL=$utf8 gawk '{ if (length($0) > m) m = length($0) } END { print m+0 }'; }

# the blocks of sq's screen, found by what they start with
section() {   # section queue|recent|footer: that block's lines
	plain | LC_ALL=$utf8 gawk -v want="$1" '
		BEGIN { RS = ""; HDR = "^ *[A-Z][A-Z/_()]*( +[A-Z][A-Z/_()]*)* *$" }   # a table header
		{ split($0, L, "\n"); first = L[1] }
		want == "queue"  && first ~ /^ *(queue is empty|job list unavailable|no readable rows|⚠ queue output)/ { print; exit }
		want == "queue"  && first ~ HDR { print; exit }
		want == "recent" && first ~ /^ *(recently finished|finished jobs unavailable)/ { print; exit }
		want == "footer" && first ~ /^ *[0-9]+ jobs / { print; exit }'
}
rows() {      # rows queue|recent: the data rows of a table, header and notes left out
	section "$1" | LC_ALL=$utf8 gawk 'NR == 1 && /^ *[A-Z][A-Z\/_()]*( +[A-Z][A-Z\/_()]*)* *$/ { next }   # the queue header
		/^ *(recently finished|finished jobs unavailable)/          { next }
		/^ *JOBID +NAME +STATE +EXIT /                               { next }
		/^ *(↳|\+[0-9]+ more|queue is empty|job list unavailable|no readable rows|⚠)/ { next }
		{ print }'
}
nrows() { rows "$1" | grep -c .; }
# the first cell of a row is exactly CELL: sq's left margin, CELL, then a space
# or the end of the line, so "…_[1-20] ×20" is not satisfied by "×200" or "_[]"
row_cell() {  # row_cell queue|recent CELL
	rows "$1" | CELL=$2 LC_ALL=$utf8 gawk 'BEGIN { cell = ENVIRON["CELL"] }
		{ sub(/^ +/, "") } index($0, cell) == 1 && substr($0, length(cell) + 1, 1) ~ /^( |)$/ { f = 1 }
		END { exit !f }'
}
row_first_fields() { rows "$1" | gawk '{ print $1 }'; }
# the N of every "×N" on a row of array BASE (its id is BASE or starts BASE_)
xmarks() {    # xmarks queue|recent BASE
	rows "$1" | B=$2 LC_ALL=$utf8 gawk '($1 == ENVIRON["B"] || index($1, ENVIRON["B"] "_") == 1) && $2 ~ /^×[0-9]+$/ { print substr($2, 2) }'
}
# 4b(ii) of the array-count spec: a row that shows ×K must show the right K, and
# the totals must count it as K.  Silent while no ×K is shown (a single job has none).
only_xmark()  { ! xmarks "$1" "$2" | grep -qvx "$3"; }     # only_xmark SECTION BASE N
footer_jobs()  { section footer | gawk 'NR == 1 { print $1 }'; }
more_count()   { plain | gawk '/^ *\+[0-9]+ more$/ { sub(/^ *\+/, ""); print $1 }'; }
xmark_counted_in_footer() {   # xmark_counted_in_footer BASE N: ×N shown -> footer counts N
	[ -z "$(xmarks queue "$1")" ] || [ "$(footer_jobs)" = "$2" ]
}
# a left-aligned column lines up: in every queue row a cell starts exactly where
# the header names it (after a space), so no name can shift the columns after it
column_aligned() {   # column_aligned HEADER, e.g. USER
	section queue | H=$1 LC_ALL=$utf8 gawk 'NR == 1 { p = index($0 " ", " " ENVIRON["H"] " ") + 1; if (p < 2) exit 1; next }
		{ n++; if (substr($0, p-1, 1) != " " || substr($0, p, 1) == " " || substr($0, p, 1) == "") bad++ }
		END { exit !(p >= 2 && n > 0 && !bad) }'
}
footer_is() { # footer_is JOBS RUNNING PENDING OTHER
	section footer | grep -qE "^ *$1 jobs +$2 running +$3 pending +$4 other\$"
}
no_footer()  { [ -z "$(section footer)" ]; }
no_skips()   { lacks unreadable && lacks incomplete; }
rc_is()      { [ "$RC" -eq "$1" ]; }
# how often sq asked the terminal its size (tests/bin/stty logs every call)
stty_size_calls() { gawk -F'\t' '$1 == "STTY" && $2 == "size" { n++ } END { print n+0 }' "$LOG"; }
err_empty()  { [ ! -s "$ERR" ]; }
out_empty()  { [ ! -s "$OUT" ]; }

# ---- the stub log: one CALL line per invocation, see tests/lib/stub.sh ------
calls() {     # calls sinfo|squeue|sacct|queue|fallback: how many
	case $1 in
		queue)    gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && (" " $3) !~ / -t all / { n++ } END { print n+0 }' "$LOG" ;;
		fallback) gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && (" " $3) ~ / -t all /  { n++ } END { print n+0 }' "$LOG" ;;
		*)        gawk -F'\t' -v t="$1" '$1 == "CALL" && $2 == t { n++ } END { print n+0 }' "$LOG" ;;
	esac
}
calls_are() { # calls_are SINFO QUEUE FALLBACK SACCT
	[ "$(calls sinfo)" = "$1" ] && [ "$(calls queue)" = "$2" ] &&
	[ "$(calls fallback)" = "$3" ] && [ "$(calls sacct)" = "$4" ]
}
argv_has() {  # argv_has TOOL WORD...: some call got these words in a row
	local want; want=" $(printf '%q ' "${@:2}")"
	W=$want gawk -F'\t' -v t="$1" '$1 == "CALL" && $2 == t && index(" " $3, ENVIRON["W"]) { f = 1 } END { exit !f }' "$LOG"
}
argv_lacks() { # argv_lacks TOOL WORD: no call of TOOL got WORD as an argument
	local want; want=" $(printf '%q ' "$2")"
	W=$want gawk -F'\t' -v t="$1" '$1 == "CALL" && $2 == t { n++; if (index(" " $3, ENVIRON["W"])) f = 1 } END { exit !(n > 0 && !f) }' "$LOG"
}
# env_of TOOL N VAR: VAR as call N of TOOL saw it, or "(unset)"
env_of() {
	local q; q=$(env_of_quoted "$@")
	if [ -z "$q" ] || [ "$q" = "(unset)" ]; then printf '%s' "$q"
	else eval "printf '%s' $q"; fi      # the stub wrote it with printf %q
}
env_of_quoted() {
	gawk -F'\t' -v t="$1" -v n="$2" -v v="$3" '
		$1 == "CALL" && $2 == t && ++c == n {
			for (i = 4; i <= NF; i++) {
				if ($i == v "(unset)") { print "(unset)"; exit }
				if (index($i, v "=") == 1) { print substr($i, length(v) + 2); exit }
			}
		}' "$LOG"
}
all_calls_env() {   # all_calls_env VAR VALUE TOOL...: every call of these tools had VAR=VALUE
	local want; want=$(printf '%q' "$2")
	W=$want gawk -F'\t' -v v="$1" -v tools=" ${*:3} " '
		$1 == "CALL" && index(tools, " " $2 " ") { n++; if (index($0 "\t", "\t" v "=" ENVIRON["W"] "\t")) ok++ }
		END { exit !(n > 0 && n == ok) }' "$LOG"
}
no_call_env() {     # no_call_env VAR TOOL...: no call of these tools had VAR set
	gawk -F'\t' -v v="$1" -v tools=" ${*:2} " '
		$1 == "CALL" && index(tools, " " $2 " ") { n++; if (index($0, "\t" v "(unset)")) un++ }
		END { exit !(n > 0 && n == un) }' "$LOG"
}

# ============================================================================
# cases and verdicts
# ============================================================================
#   need  WHY CMD...   must hold, in every case (a FAIL otherwise)
#   want  WHY CMD...   the correct behaviour; in an xfail case, what is broken
#   today WHY CMD...   in an xfail case: the defect's documented signature, so a
#                      defect that changes shape is a FAIL rather than an XFAIL
#   xfail REASON       marks the case a known defect
need()  { "${@:2}" || T_FAIL+=("$1"); }
want()  { "${@:2}" || T_WANT+=("$1"); }
today() { "${@:2}" || T_TODAY+=("$1"); }
xfail() { T_XFAIL=$1; }

n_pass=0 n_fail=0 n_xfail=0 n_xpass=0
verdict() {
	local status reason
	[ "$T_CALLS" -gt 0 ] || T_FAIL+=("no stub was called: tests/bin is not answering for Slurm")
	if [ ${#T_FAIL[@]} -gt 0 ]; then
		status=FAIL; reason=$(IFS=$'\x1f'; echo "${T_FAIL[*]}")
		[ ${#T_WANT[@]} -gt 0 ] && [ -z "$T_XFAIL" ] && reason="$reason"$'\x1f'"$(IFS=$'\x1f'; echo "${T_WANT[*]}")"
	elif [ -z "$T_XFAIL" ]; then
		if [ ${#T_WANT[@]} -gt 0 ]; then status=FAIL; reason=$(IFS=$'\x1f'; echo "${T_WANT[*]}")
		else status=PASS; reason=$T_TITLE; fi
	elif [ ${#T_WANT[@]} -eq 0 ]; then
		status=XPASS; reason="no longer broken, remove the xfail marker: $T_XFAIL"
	elif [ ${#T_TODAY[@]} -gt 0 ]; then
		status=FAIL; reason="known defect changed shape ($(IFS=$'\x1f'; echo "${T_TODAY[*]}")): $T_XFAIL"
	else
		status=XFAIL; reason=$T_XFAIL
	fi
	case $status in
		PASS) n_pass=$((n_pass+1)) ;; FAIL) n_fail=$((n_fail+1)) ;;
		XFAIL) n_xfail=$((n_xfail+1)) ;; XPASS) n_xpass=$((n_xpass+1)) ;;
	esac
	printf '%-5s  %-24s %s\n' "$status" "$T_NAME" "${reason//$'\x1f'/; }"
	[ $status = FAIL ] || [ $status = XPASS ] && [ $keep = 0 ] && printf '       evidence: rerun with -k\n'
	return 0
}

# ---- 1. empty queue, two idle nodes ----------------------------------------
c_empty() {
	T_TITLE="empty queue: 'queue is empty', footer 0 jobs"
	sq_run empty --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: sinfo, queue, sacct once each, no fallback" calls_are 1 1 0 1
	need "'queue is empty'"           has "queue is empty"
	need "footer 0/0/0/0"             footer_is 0 0 0 0
	need "both idle nodes listed"     eval '[ "$(lines_matching "^ +node0[12] .* 0/32 cpu .* idle$" | wc -l)" -eq 2 ]'
	need "caption: nothing in this window" has "recently finished · last 2h · nothing in this window"
	need "no unreadable/incomplete note"   no_skips
	need "no warning sign"            lacks "⚠"
}

# ---- 2. a normal mixed queue ------------------------------------------------
c_mixed() {
	T_TITLE="mixed queue: footer 6 jobs / 3 running / 2 pending / 1 other"
	sq_run mixed --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: sinfo, queue, sacct once each" calls_are 1 1 0 1
	need "footer 6/3/2/1"             footer_is 6 3 2 1
	need "6 queue rows"               eval '[ "$(nrows queue)" -eq 6 ]'
	need "rows are 1101..1106"        eval '[ "$(row_first_fields queue | sort | paste -sd,)" = 1101,1102,1103,1104,1105,1106 ]'
	need "USER and NODE/REASON columns line up" eval 'column_aligned USER && column_aligned NODE/REASON'
	need "pending reason with its backfill estimate" eval 'rows queue | grep -qE "^ +1103 .*PENDING .*\(Resources\) → 2099-01-01$"'
	need "no estimate where squeue has none" eval 'rows queue | grep -qE "^ +1102 .*PENDING .*\(Priority\)$"'
	need "finished row 1001 COMPLETED" eval 'rows recent | grep -qE "^ +1001 +done +COMPLETED "'
	need "finished block has 1 row (steps folded)" eval '[ "$(nrows recent)" -eq 1 ]'
	need "no unreadable/incomplete note" no_skips
	need "queue call: squeue -h -S t,i" argv_has squeue -h -S t,i
	need "every call has SLURM_TIME_FORMAT=standard" all_calls_env SLURM_TIME_FORMAT standard sinfo squeue sacct
	need "queue format framed by SQ_NONCE, ends in hidden %t %l %S" eval '
		f=$(env_of squeue 1 SQUEUE_FORMAT); n=$(env_of squeue 1 SQ_NONCE)
		[ "$f" = "%i$n%i$n%j$n%u$n%T$n%M$n%L$n%C$n%m$n%R$n%t$n%l$n%S$n" ]'
	need "sacct: -p --delimiter=SQ_NONCE2 -n -S now-2hours -E now -a -o <8 fields>" eval '
		argv_has sacct -p "--delimiter=$(env_of sacct 1 SQ_NONCE2)" -n -S now-2hours -E now -a -o JobID,User,State,ExitCode,Elapsed,End,NodeList,JobName'
	need "sacct's delimiter is not the queue nonce" eval '[ "$(env_of sacct 1 SQ_NONCE2)" != "$(env_of sacct 1 SQ_NONCE)" ]'
	need "sinfo: -hN -o framed by SQ_NONCE3" eval '
		n=$(env_of sinfo 1 SQ_NONCE3); argv_has sinfo -hN -o "%C$n%N$n%e$n%m$n%T$n%E$n%H$n"'
	sq_run mixed SQ_ETA=0 --
	need "SQ_ETA=0: rc 0"             rc_is 0
	need "SQ_ETA=0: no estimate"      eval 'rows queue | grep -qE "^ +1103 .*PENDING .*\(Resources\)$"'
}

# ---- 3. running array tasks fold into one row --------------------------------
c_array_fold() {
	T_TITLE="running tasks _0.._3 fold into one row 1234_[0-3] ×4; -x expands them"
	sq_run array-running --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "folded cell '1234_[0-3] ×4'" row_cell queue "1234_[0-3] ×4"
	need "exactly one row of 1234"    eval '[ "$(rows queue | grep -c "^ *1234_")" -eq 1 ]'
	need "the single job stays its own row" row_cell queue 2000
	need "footer counts tasks: 5/5/0/0" footer_is 5 5 0 0
	sq_run array-running -- -x
	need "-x: rc 0"                   rc_is 0
	need "-x: four rows 1234_0..3"    eval '[ "$(row_first_fields queue | grep -c "^1234_[0-3]$")" -eq 4 ]'
	need "-x: no fold marker"         lacks "×"
	need "-x: footer unchanged"       footer_is 5 5 0 0
}
c_fold_split() {
	T_TITLE="tasks that differ in a displayed column do not fold together"
	sq_run array-split --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "'1300_[0-1,3] ×3' on node01" eval 'row_cell queue "1300_[0-1,3] ×3" && rows queue | grep -qE "^ +1300_\[0-1,3\] ×3 .* node01$"'
	need "'1300_2' alone, on node02"  eval 'row_cell queue 1300_2 && rows queue | grep -qE "^ +1300_2 .* node02$"'
	need "two rows"                   eval '[ "$(nrows queue)" -eq 2 ]'
	need "footer 4/4/0/0"             footer_is 4 4 0 0
}

# ---- 4. a drain reason with "|" and a newline --------------------------------
c_drain_reason() {
	T_TITLE="drain reason with '|' and newline stays on node02's ↳ line"
	sq_run drained --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "node01 line intact (idle)"  matches "^ +node01 .* 0/32 cpu .* idle$"
	need "node02 line intact (drained)" matches "^ +node02 .* 0/32 cpu .* drained$"
	need "reason on the ↳ line right after node02, newline scrubbed to ?" eval '
		plain | grep -A1 -E "^ +node02 " | tail -1 | grep -qE "^ +↳ bad\|disk\?replace · since 2026-10-01$"'
	need "no unreadable node note"    no_skips
	need "no node caption"            lacks "node output"
	need "footer 0 jobs"              footer_is 0 0 0 0
}

# ---- 5. hostile job names, and a record that does not end where it should ----
c_hostile_names() {
	T_TITLE="names with | tab newline ESC and a fake record: 5 real rows, no forgery, no raw ESC"
	sq_run hostile-names --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "exactly rows 3001..3005"    eval '[ "$(row_first_fields queue | paste -sd,)" = 3001,3002,3003,3004,3005 ]'
	need "no forged row 424242/424243" eval '! row_first_fields queue | grep -qE "^42424[23]"'
	need "footer 5/5/0/0"             footer_is 5 5 0 0
	need "no ESC byte in a plain pipe" eval '[ "$(escapes)" -eq 0 ]'
	need "no BEL byte"                eval '[ "$(bels)" -eq 0 ]'
	need "pipe kept, tab/newline/ESC scrubbed to ?" eval 'has "pipe|name" && has "tab?name" && has "nl?name" && has "esc?[2Jclear?]0;pwn?"'
	need "no unreadable note"         no_skips
	need "USER and STATE columns line up under their headers" eval 'column_aligned USER && column_aligned STATE'
	sq_run hostile-names COLUMNS=120 LINES=50 --
	need "colour on: rc 0"            rc_is 0
	need "colour on: escapes present" eval '[ "$(escapes)" -gt 0 ]'
	need "colour on: every ESC is sq's own SGR" escapes_all_sgr
	need "colour on: footer 5 jobs"   eval 'section footer | grep -qE "^ *5 jobs "'
}
c_trailing_junk() {
	T_TITLE="a record with text after its last separator is skipped with the note"
	sq_run trailing-junk --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "only 1201 shown"            eval '[ "$(row_first_fields queue | paste -sd,)" = 1201 ]'
	need "'↳ 1 unreadable queue row skipped'" has "↳ 1 unreadable queue row skipped"
	need "footer 1/1/0/0"             footer_is 1 1 0 0
}

# ---- 6. squeue failing, hanging, or answering garbage -------------------------
# With the job list unavailable sq still prints a "0 jobs" footer: a number it
# does not know.  What it should print instead is not decided here, only that
# it must not claim zero.
c_squeue_fails() {
	T_TITLE=; xfail "squeue rc 1: the job list is unavailable, yet the footer claims 0 jobs"
	sq_run squeue-fails --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: queue once, no fallback, sacct still asked" calls_are 1 1 0 1
	need "banner carries squeue's first stderr line" matches "^  ⚠ slurm unreachable · squeue: error: Unable to contact"
	need "'job list unavailable'"     has "job list unavailable"
	need "finished block still from sacct" eval 'rows recent | grep -qE "^ +1001 +done +COMPLETED "'
	want "no '0 jobs' footer while the job list is unavailable" eval '! section footer | grep -qE "^ *0 jobs "'
	today "footer 0/0/0/0"            footer_is 0 0 0 0
}
c_squeue_hangs() {
	T_TITLE=; xfail "squeue hangs (cut at SQ_TIMEOUT=1): the job list is unavailable, yet the footer claims 0 jobs"
	local t0=$SECONDS
	sq_run squeue-hangs SQ_TIMEOUT=1 --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: queue once, no fallback" calls_are 1 1 0 1
	need "finished within 10s"        eval '[ $((SECONDS - t0)) -lt 10 ]'
	need "banner 'no response after 1s'" matches "^  ⚠ slurm unreachable · no response after 1s$"
	need "'job list unavailable'"     has "job list unavailable"
	want "no '0 jobs' footer while the job list is unavailable" eval '! section footer | grep -qE "^ *0 jobs "'
	today "footer 0/0/0/0"            footer_is 0 0 0 0
}
c_squeue_garbage() {
	T_TITLE="squeue answers unframed text: 'queue output unreadable', no footer"
	sq_run squeue-garbage --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "caption 'queue output unreadable'" has "⚠ queue output unreadable (output format overridden?)"
	need "no row from the garbage"    lacks "train"
	need "no footer from an unreadable stream" no_footer
	need "no unreachable banner"      lacks "slurm unreachable"
}
c_both_fail() {
	T_TITLE="squeue and sacct both fail: no fallback call, caption carries sacct's error"
	sq_run both-fail --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: no squeue -t all after squeue itself failed" calls_are 1 1 0 1
	need "banner carries squeue's error" matches "^  ⚠ slurm unreachable · squeue: error: Unable to contact"
	need "caption: finished jobs unavailable, with sacct's error" matches "^  finished jobs unavailable · sacct: error: Problem"
}

# ---- 7. the finished block from sacct ----------------------------------------
c_finished() {
	T_TITLE="sacct: COMPLETED and FAILED tasks of one array fold apart; a timeout shows its signal; newest first"
	sq_run finished --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "'5000_[0-3] ×4' COMPLETED"  eval 'row_cell recent "5000_[0-3] ×4" && rows recent | grep -qE "^ +5000_\[0-3\] ×4 +sweep +COMPLETED "'
	need "'5000_[4-5] ×2' FAILED exit 1" eval 'row_cell recent "5000_[4-5] ×2" && rows recent | grep -qE "^ +5000_\[4-5\] ×2 +sweep +FAILED +1 "'
	need "5100 TIMEOUT shows 0/sig15 from its step" eval 'rows recent | grep -qE "^ +5100 +longrun +TIMEOUT +0/sig15 "'
	need "newest first: 5100 (ended last) is the first row" eval '[ "$(row_first_fields recent | head -1)" = 5100 ]'
	need "3 finished rows, no step row" eval '[ "$(nrows recent)" -eq 3 ] && ! rows recent | grep -q "batch"'
	need "caption from sacct"         eval 'section recent | head -1 | grep -qE "^ +recently finished · last 2h$"'
	need "no unreadable note"         no_skips
}
c_user_filter() {
	T_TITLE="-u alice reaches squeue and sacct as -u alice, and sacct gets no -a"
	sq_run empty -- -u alice
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: queue and sacct"     calls_are 1 1 0 1
	need "queue call: -u alice"       argv_has squeue -h -S t,i -u alice
	need "sacct: -u alice"            argv_has sacct -u alice
	need "sacct: no -a (sacct takes the last of -u/-a, so -a would mean everybody)" argv_lacks sacct -a
	need "caption names the filter"   has "recently finished · last 2h · user=alice"
}

# ---- 8. sacct fails: the squeue -t all fallback -----------------------------
c_sacct_fallback() {
	T_TITLE="sacct rc 1: finished block falls back to squeue -t all, caption says so"
	sq_run sacct-fails --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: sacct, then the fallback" calls_are 1 1 1 1
	need "every call has SLURM_TIME_FORMAT=standard" all_calls_env SLURM_TIME_FORMAT standard sinfo squeue sacct
	need "fallback argv: squeue -t all -h" argv_has squeue -t all -h
	need "fallback uses SQUEUE_FORMAT2 and not SQUEUE_FORMAT" eval '
		[ "$(env_of squeue 2 SQUEUE_FORMAT)" = "(unset)" ] && [ "$(env_of squeue 2 SQUEUE_FORMAT2)" != "(unset)" ]'
	need "fallback -O list framed by SQ_NONCE" eval '
		n=$(env_of squeue 2 SQ_NONCE)
		[ "$(env_of squeue 2 SQUEUE_FORMAT2)" = "JobID:$n,StateCompact:$n,State:$n,exit_code:$n,TimeUsed:$n,EndTime:$n,ArrayJobID:$n,ArrayTaskID:$n,UserName:$n,Name:$n" ]'
	need "queue call uses SQUEUE_FORMAT and not SQUEUE_FORMAT2" eval '
		[ "$(env_of squeue 1 SQUEUE_FORMAT2)" = "(unset)" ] && [ "$(env_of squeue 1 SQUEUE_FORMAT)" != "(unset)" ]'
	need "caption names the cause"    eval 'section recent | head -1 | grep -qE "^ +recently finished · recent only \(no accounting\) · sacct: error: Problem"'
	need "finished 6001 shown"        eval 'rows recent | grep -qE "^ +6001 +finished-one +COMPLETED "'
	need "running 3001 only in the queue" eval '[ "$(row_first_fields recent | grep -c "^3001$")" -eq 0 ] && row_cell queue 3001'
	need "footer 1/1/0/0"             footer_is 1 1 0 0
}

# ---- 9. option refusals ------------------------------------------------------
# A refused option exits 2 before any Slurm call, so each case pairs it with an
# accepted run that differs only in that option: that run proves the stubs are
# the ones answering, and that the refusal is about the value.
refusal() {   # refusal FIXTURE "REFUSED ARGS" "ACCEPTED ARGS"
	local -a bad=() ok=()
	eval "bad=($2)"; eval "ok=($3)"
	sq_run "$1" -- "${bad[@]}"
	need "refused: rc 2"              rc_is 2
	need "refused: zero bytes on stdout" out_empty
	need "refused: says why on stderr" eval 'grep -q "^sq: " "$ERR"'
	need "refused: no Slurm call"     eval '[ "$(grep -c "^CALL" "$LOG")" -eq 0 ]'
	sq_run "$1" -- "${ok[@]}"
	need "accepted twin: rc 0"        rc_is 0
	need "accepted twin: stubs called" eval '[ "$(calls queue)" -eq 1 ]'
}
c_refuse_t_empty() {
	T_TITLE="-t '' refused (rc 2, empty stdout); -t R accepted and forwarded"
	refusal empty "-t ''" "-t R"
	need "-t R forwarded to the queue call" argv_has squeue -h -S t,i -t R
}
c_refuse_states_eq() {
	T_TITLE="--states= refused (rc 2, empty stdout); --states=R accepted"
	refusal empty "--states=" "--states=R"
	need "--states=R forwarded"       argv_has squeue -h -S t,i --states=R
}
c_accept_S_empty() {
	T_TITLE="-S '' accepted (rc 0) and forwarded as given"
	sq_run empty -- -S ''
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "forwarded after sq's own sort" argv_has squeue -h -S t,i -S ''
	need "no sacct (-S has no sacct twin), fallback instead" calls_are 1 1 1 0
	need "caption says why"           has "recent only (-S has no sacct equivalent)"
}
c_refuse_s()    { T_TITLE="-s refused; -u alice accepted";      refusal empty "-s" "-u alice"; }
c_refuse_json() { T_TITLE="--json refused; --all accepted";     refusal empty "--json" "--all"; }
c_refuse_O()    { T_TITLE="-O x refused; -o i,j accepted";      refusal empty "-O x" "-o i,j"; }

# ---- 10. colour and size ------------------------------------------------------
c_colour() {
	T_TITLE="colour: plain pipe 0 escapes, COLUMNS+LINES >0, NO_COLOR=1 0"
	sq_run mixed --
	need "plain pipe: rc 0"           rc_is 0
	need "plain pipe: stubs called"   calls_are 1 1 0 1
	need "plain pipe: no ESC"         eval '[ "$(escapes)" -eq 0 ]'
	sq_run mixed COLUMNS=120 LINES=50 --
	need "COLUMNS+LINES: rc 0"        rc_is 0
	need "COLUMNS+LINES: stubs called" calls_are 1 1 0 1
	need "COLUMNS+LINES: escapes"     eval '[ "$(escapes)" -gt 0 ]'
	need "COLUMNS+LINES: all SGR"     escapes_all_sgr
	need "COLUMNS+LINES: same footer once uncoloured" footer_is 6 3 2 1
	sq_run mixed COLUMNS=120 LINES=50 NO_COLOR=1 --
	need "NO_COLOR: rc 0"             rc_is 0
	need "NO_COLOR: stubs called"     calls_are 1 1 0 1
	need "NO_COLOR: no ESC"           eval '[ "$(escapes)" -eq 0 ]'
}
# Width: the "wide" fixture shrinks the table to exactly the width sq believes
# in (see section 12).  Height: with 34 finished jobs (30 single, and an older
# 4-task array that folds into one row) and no SQ_RECENT_MAX the finished block
# takes what the screen has left, so the output fills the height exactly; the
# array is the oldest, so it is never shown, and "+N more" must count its 4 tasks:
# the JOBS shown (a ×K row is K) plus "+N more" account for all 34.
jobs_shown() { rows recent | LC_ALL=$utf8 gawk '{ n += ($2 ~ /^×[0-9]+$/) ? substr($2, 2) : 1 } END { print n+0 }'; }
fills() {     # fills HEIGHT: the output is HEIGHT lines and accounts for all 34 jobs
	[ "$(plain | wc -l)" -eq "$1" ] && ! row_first_fields recent | grep -q "^5000_" &&
	[ $(( $(jobs_shown) + $(more_count) )) -eq 34 ]
}
c_layout_size() {
	T_TITLE="in a pipe: SQ_WIDTH, COLUMNS, SQ_HEIGHT and LINES set the layout"
	sq_run wide SQ_WIDTH=123 --
	need "SQ_WIDTH=123: widest line 123"  eval 'calls_are 1 1 0 1 && [ "$(width)" -eq 123 ]'
	sq_run wide SQ_WIDTH=123 COLUMNS=90 --
	need "SQ_WIDTH beats COLUMNS"         eval 'calls_are 1 1 0 1 && [ "$(width)" -eq 123 ]'
	sq_run wide -SQ_WIDTH COLUMNS=110 --
	need "COLUMNS=110: widest line 110"   eval 'calls_are 1 1 0 1 && [ "$(width)" -eq 110 ]'
	sq_run many-finished SQ_HEIGHT=20 --
	need "SQ_HEIGHT=20: 20 lines, 34 jobs accounted, the hidden array in +N more" eval 'calls_are 1 1 0 1 && fills 20'
	sq_run many-finished SQ_HEIGHT=30 --
	need "SQ_HEIGHT=30: 30 lines, 34 jobs accounted, the hidden array in +N more" eval 'calls_are 1 1 0 1 && fills 30'
	sq_run many-finished -SQ_HEIGHT LINES=20 --
	need "LINES=20: 20 lines, 34 jobs accounted, the hidden array in +N more" eval 'calls_are 1 1 0 1 && fills 20'
	sq_run many-finished SQ_HEIGHT=20 LINES=30 --
	need "SQ_HEIGHT beats LINES"        eval 'calls_are 1 1 0 1 && fills 20'
}

# ---- 11. array ids and their counts, and known defects -------------------------
# Array-count spec, acceptance 4b: the FORBIDDEN states are a FAIL at any commit,
# never an XFAIL: (i) a row dropped today shown but counted 1; (ii) a row
# showing ×N while the footer or "+N more" counts it as anything but N, or a
# ×K other than the right N.
bracket_guards() {   # bracket_guards SECTION BASE N: 4b(ii) for one array
	need "4b(ii): no ×K other than ×$3 on $2" only_xmark "$1" "$2" "$3"
	[ "$1" = queue ] && need "4b(ii): ×$3 shown means the footer counts $3" xmark_counted_in_footer "$2" "$3"
	return 0
}
# one pending array row beside the two idle nodes, written into the case's dir
pending_fixture() {  # pending_fixture NAME ID: prints the fixture's directory
	local d=$T_DIR/fx-$1; mkdir -p "$d"
	printf '@include %s\n' "$fixtures/_common/sinfo-two-idle" > "$d/sinfo"
	printf '@include %s\n' "$fixtures/_common/empty" > "$d/sacct"
	{ printf '@include %s\n' "$fixtures/_common/squeue-defaults"
	  printf 'i=%s; j=sweep; t=PD; T=PENDING; M=0:00; L=1:00:00; R=(Resources); S=N/A\n' "$2"; } > "$d/squeue"
	printf '%s' "$d"
}
c_pending_range() {
	T_TITLE="a pending _[1-20] row reads 7000_[1-20] ×20 and counts 20 jobs, -x or not"
	sq_run pending-range --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	bracket_guards queue 7000 20
	need "cell '7000_[1-20] ×20'"     row_cell queue "7000_[1-20] ×20"
	need "footer 20/0/20/0"           footer_is 20 0 20 0
	# -x expands sq's own fold, not a Slurm bracket, and sq -h promises the ×20
	sq_run pending-range -- -x
	need "-x: rc 0"                   rc_is 0
	bracket_guards queue 7000 20
	need "-x: cell '7000_[1-20] ×20'" row_cell queue "7000_[1-20] ×20"
	need "-x: footer 20/0/20/0"       footer_is 20 0 20 0
}
pending_bracket() {  # pending_bracket ID BASE N: a pending bracket shown as ID ×N and counted N
	sq_run "$(pending_fixture "$2" "$1")" --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	bracket_guards queue "$2" "$3"
	need "cell '$1 ×$3'"              row_cell queue "$1 ×$3"
	need "footer $3/0/$3/0"           footer_is "$3" 0 "$3" 0
}
c_pending_commas() {
	T_TITLE="a pending _[1-5,8,10-12] row reads ×9 and counts 9 jobs"
	pending_bracket "7003_[1-5,8,10-12]" 7003 9
}
c_pending_throttle() {
	T_TITLE="a pending _[1-20%4] row counts 20 jobs (the throttle limits concurrency, not membership)"
	pending_bracket "7004_[1-20%4]" 7004 20
}
c_pending_no_id_column() {
	T_TITLE="sq -o j,T with a pending _[1-20]: the footer counts 20 pending"
	sq_run pending-range -- -o j,T
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	need "one row: 'sweep PENDING'"   eval '[ "$(nrows queue)" -eq 1 ] && rows queue | grep -qE "^ +sweep +PENDING$"'
	need "footer 20/0/20/0"           footer_is 20 0 20 0
}
c_pending_strided() {
	T_TITLE="a pending strided _[0-12:2] row is shown as ×7 and counted 7, with no skip note"
	sq_run pending-strided --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	bracket_guards queue 7001 7
	need "cell '7001_[0-12:2] ×7'"    row_cell queue "7001_[0-12:2] ×7"
	need "footer 7/0/7/0"             footer_is 7 0 7 0
	need "no unreadable note"         no_skips
	need "4b(i): shown but counted 1" eval '
		! { rows queue | grep -q "^ *7001_" && section footer | grep -qE "^ *1 jobs "; }'
}
c_xf_pending_long() {
	T_TITLE=; xfail "a pending id over 31 characters is cut by squeue (no SLURM_BITSTR_LEN=0) and dropped; should be shown as 10 jobs"
	sq_run pending-long --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	bracket_guards queue 11137 10
	want "cell '11137_[1,3,5,7,9,11,13,15,17,20] ×10'" row_cell queue "11137_[1,3,5,7,9,11,13,15,17,20] ×10"
	want "footer 10/0/10/0"           footer_is 10 0 10 0
	want "no unreadable note"         no_skips
	# today's shape is the only accepted one: dropped, with the note, which is also
	# what a correct count without SLURM_BITSTR_LEN=0 still gives (squeue cuts the
	# id, so it fails the gate) - so this flips only once the whole id arrives
	need "4b(i): shown but counted 1" eval '
		! { rows queue | grep -q "^ *11137_" && section footer | grep -qE "^ *1 jobs "; }'
	today "dropped, with the skip note" eval '
		has "↳ 1 unreadable queue row skipped" && footer_is 0 0 0 0 && [ "$(nrows queue)" -eq 0 ]'
}
# Acceptance 6: a malformed bracket is skipped with the existing note, never
# counted 0, negative, NaN or 1.  The run inherits SLURM_BITSTR_LEN=0 (a user
# may have it set), so the stub hands sq the whole id and the case tests sq's
# own gate, not squeue's 31-character cut.
malformed() {        # malformed NAME ID BASE
	sq_run "$(pending_fixture "$1" "$2")" SLURM_BITSTR_LEN=0 --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	need "no ×K on it"                eval '[ -z "$(xmarks queue "'"$3"'")" ]'
	need "skipped with the note"      has "↳ 1 unreadable queue row skipped"
	need "not shown, footer 0/0/0/0"  eval '[ "$(nrows queue)" -eq 0 ] && footer_is 0 0 0 0'
}
c_malformed_step0() {
	T_TITLE="malformed _[0-4:0] (step 0) is skipped with the note"
	malformed step0 "7006_[0-4:0]" 7006
}
c_malformed_dots() {
	T_TITLE="malformed _[...] is skipped with the note"
	malformed dots "7008_[...]" 7008
}
c_malformed_reversed() {
	T_TITLE="malformed _[5-2] (empty range) is skipped with the note"
	malformed reversed "7005_[5-2]" 7005
}
c_malformed_multi() {
	T_TITLE="malformed _[1-10,5-2] (one empty term among good ones) is skipped with the note"
	malformed multi "7001_[1-10,5-2]" 7001
}
c_malformed_dash() {
	T_TITLE="malformed _[1--2] is skipped with the note"
	malformed dash "7007_[1--2]" 7007
}
c_malformed_huge() {
	T_TITLE="a 400-digit index is skipped with the note"
	local digits; digits=$(printf '%0400d' 7)
	malformed huge "7009_[$digits]" 7009
}
c_finished_throttled() {
	T_TITLE="a finished _[0-9%3] row from sacct reads 7002_[0-9%3] ×10"
	sq_run finished-throttled --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	bracket_guards recent 7002 10
	need "state CANCELLED, the canceller in EXIT" eval '
		rows recent | grep -qE "^ +7002_\[0-9%3\]( ×[0-9]+)? +sweep +CANCELLED +0 by [^ ]+ "'
	need "cell '7002_[0-9%3] ×10'"    row_cell recent "7002_[0-9%3] ×10"
}
c_fallback_throttled() {
	T_TITLE="a finished throttled array via the squeue fallback reads 7002_[0-9%3] ×10, as from sacct"
	sq_run fallback-throttled --
	need "rc 0"                       rc_is 0
	need "stubs: sacct failed, fallback used" calls_are 1 1 1 1
	bracket_guards recent 7002 10
	need "cell '7002_[0-9%3] ×10'"    row_cell recent "7002_[0-9%3] ×10"
}
# Acceptance 6 for the finished block: the record gate is the same for every
# source, so a bracket naming no task is skipped there too, never shown
finished_malformed() {   # finished_malformed FIXTURE CALLS SKIPPED ID-ERE
	local -a calls; read -ra calls <<< "$2"
	sq_run "$1" --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are "${calls[@]}"
	need "the good row 7100 is shown" row_cell recent 7100
	need "no row for $4"              eval '! row_first_fields recent | grep -qE "^('"$4"')"'
	need "'↳ $3 skipped'"             has "↳ $3 skipped"
	need "footer 0/0/0/0"             footer_is 0 0 0 0
}
c_finished_malformed() {
	T_TITLE="sacct: _[5-2] and _[0-4:0] are skipped with the note, never shown"
	finished_malformed finished-malformed "1 1 0 1" "2 unreadable finished rows" "8000|8001"
}
c_fallback_malformed() {
	T_TITLE="fallback: ArrayTaskID=5-2 is skipped with the note, never shown"
	finished_malformed fallback-malformed "1 1 1 1" "1 unreadable finished row" "8100"
}
# Acceptance 3/4: capped to one finished row, the newer single job is shown and
# the throttled array is behind "+N more", which counts JOBS.  The uncapped twin
# shows whether the array row already carries ×10, which "+N more" must match.
more_case() {        # more_case FIXTURE CALLS BASE CELL N
	local -a calls; read -ra calls <<< "$2"
	sq_run "$1" SQ_RECENT_MAX=5 --
	need "uncapped: rc 0"             rc_is 0
	need "uncapped: stubs called"     calls_are "${calls[@]}"
	bracket_guards recent "$3" "$5"
	local marks; marks=$(xmarks recent "$3")
	need "uncapped: cell '$4'"        row_cell recent "$4"
	sq_run "$1" SQ_RECENT_MAX=1 --
	need "capped: rc 0"               rc_is 0
	need "capped: stubs called"       calls_are "${calls[@]}"
	need "capped: the newer job 7100 is the one row" eval '[ "$(row_first_fields recent | paste -sd,)" = 7100 ]'
	need "4b(ii): ×$5 shown means '+$5 more'" eval '[ -z "$marks" ] || [ "$(more_count)" = '"$5"' ]'
	need "capped: '+$5 more'"         eval '[ "$(more_count)" = '"$5"' ]'
}
c_more_sacct() {
	T_TITLE="capped finished block (sacct): '+10 more' counts every task of the throttled array"
	more_case more-sacct "1 1 0 1" 7002 "7002_[0-9%3] ×10" 10
}
c_more_fallback() {
	T_TITLE="capped finished block (fallback): '+10 more' counts every task of the throttled array"
	more_case more-fallback "1 1 1 1" 7002 "7002_[0-9%3] ×10" 10
}
c_more_repeated() {
	T_TITLE="capped finished block (fallback): a task listed twice counts once, '8400_[1-2] ×2' and '+2 more'"
	more_case more-repeated "1 1 1 1" 8400 "8400_[1-2] ×2" 2
}
c_xf_bitstr() {
	T_TITLE=; xfail "squeue and sacct are called without SLURM_BITSTR_LEN=0"
	sq_run sacct-fails --
	need "rc 0"                       rc_is 0
	need "stubs: queue, sacct and fallback all called" calls_are 1 1 1 1
	want "every squeue and sacct call has SLURM_BITSTR_LEN=0" all_calls_env SLURM_BITSTR_LEN 0 squeue sacct
	today "no squeue or sacct call has it" no_call_env SLURM_BITSTR_LEN squeue sacct
}

# ---- 11b. an id cell too wide for the terminal (array-count spec R7) ---------
# It shrinks INSIDE its bracket, never its ×N: the base id, "_[", whole leading
# terms of the real set, "…]" and the exact ×N.  Every case is at a width where
# the id column must shrink, and its counts must not move with the cell.
elided_cell() {      # elided_cell SECTION FULL-ID N: a row reads FULL-ID cut inside, then ×N
	rows "$1" | ID=$2 N=$3 LC_ALL=$utf8 gawk '
		BEGIN { id = ENVIRON["ID"]; p = index(id, "_["); head = substr(id, 1, p + 1)
		        body = substr(id, p + 2, length(id) - p - 2) }
		index($1, head) == 1 && $1 ~ /…\]$/ && $2 == "×" ENVIRON["N"] && NF >= 2 {
			keep = substr($1, length(head) + 1, length($1) - length(head) - 2)
			if (keep == "" || (keep ~ /,$/ && index(body, keep) == 1)) f = 1 }
		END { exit !f }'
}
shrink_ids=$(seq -s, 1 3 199)        # 67 tasks, every third: a long irregular set
c_shrink_pending() {
	T_TITLE="at 80 columns a pending 600_[1,4,…] keeps its ×67, and still counts 67"
	sq_run shrink-pending SLURM_BITSTR_LEN=0 SQ_WIDTH=80 --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	bracket_guards queue 600 67
	need "cell 600_[1,4,…] ×67, cut inside" elided_cell queue "600_[$shrink_ids]" 67
	need "leading terms kept"         eval 'rows queue | grep -q "^ *600_\[1,4,7,"'
	need "footer 67/0/67/0"           footer_is 67 0 67 0
	need "no line past 80"            eval '[ "$(width)" -le 80 ]'
	need "no unreadable note"         no_skips
}
c_shrink_fold() {
	T_TITLE="at 80 columns sq's own fold 9008_[0,2,…] keeps its ×30, and still counts 30"
	sq_run shrink-fold SQ_WIDTH=80 --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	bracket_guards queue 9008 30
	need "cell 9008_[0,2,…] ×30, cut inside" elided_cell queue "9008_[$(seq -s, 0 2 58)]" 30
	need "leading terms kept"         eval 'rows queue | grep -q "^ *9008_\[0,2,4,"'
	need "footer 30/30/0/0"           footer_is 30 30 0 0
	need "no line past 80"            eval '[ "$(width)" -le 80 ]'
}
c_shrink_finished() {
	T_TITLE="at 80 columns the finished 600_[…] and sq's fold 5000_[…] keep ×67 and ×30; '+97 more' when capped"
	sq_run shrink-finished SLURM_BITSTR_LEN=0 SQ_WIDTH=80 SQ_RECENT_MAX=5 --
	need "uncapped: rc 0"             rc_is 0
	need "uncapped: stubs called"     calls_are 1 1 0 1
	bracket_guards recent 600 67
	bracket_guards recent 5000 30
	need "cell 600_[1,4,…] ×67, cut inside"  elided_cell recent "600_[$shrink_ids]" 67
	need "cell 5000_[0,2,…] ×30, cut inside" elided_cell recent "5000_[$(seq -s, 0 2 58)]" 30
	need "leading terms kept on both" eval 'rows recent | grep -q "^ *600_\[1,4,7," && rows recent | grep -q "^ *5000_\[0,2,4,"'
	need "no line past 80"            eval '[ "$(width)" -le 80 ]'
	need "no unreadable note"         no_skips
	# the brackets give way (rung 4) before STATE falls back to its code (rung 5)
	need "STATE keeps its words"      eval 'rows recent | grep -qE "^ *600_.* CANCELLED " && rows recent | grep -qE "^ *5000_.* FAILED "'
	sq_run shrink-finished SLURM_BITSTR_LEN=0 SQ_WIDTH=80 SQ_RECENT_MAX=1 --
	need "capped: rc 0"               rc_is 0
	need "capped: the newer job 7100 is the one row" eval '[ "$(row_first_fields recent | paste -sd,)" = 7100 ]'
	need "capped: '+97 more'"         eval '[ "$(more_count)" = 97 ]'
	need "footer 0/0/0/0"             footer_is 0 0 0 0
}
# Narrower than BASE_[…] ×N no cut keeps both, and the cell takes the plain
# right cut: -o i,T at 25 columns leaves JOBID exactly 15, at 24 one short
c_shrink_floor() {
	T_TITLE="JOBID exactly BASE_[…] ×N wide reads 6000000_[…] ×67; one narrower, the plain right cut"
	local fx; fx=$(pending_fixture floor "6000000_[$shrink_ids]")
	sq_run "$fx" SLURM_BITSTR_LEN=0 SQ_WIDTH=25 -- -o i,T
	need "25: rc 0"                   rc_is 0
	need "25: stubs called"           calls_are 1 1 0 1
	need "25: cell '6000000_[…] ×67'" row_cell queue "6000000_[…] ×67"
	need "25: footer 67/0/67/0"       footer_is 67 0 67 0
	sq_run "$fx" SLURM_BITSTR_LEN=0 SQ_WIDTH=24 -- -o i,T
	need "24: rc 0"                   rc_is 0
	need "24: cell '6000000_[1,4,…', the right cut" row_cell queue "6000000_[1,4,…"
	need "24: footer 67/0/67/0"       footer_is 67 0 67 0
}

# ---- 12. on a terminal --------------------------------------------------------
# The "wide" fixture's job name is wider than any terminal, so the queue table is
# shrunk to exactly the width sq believes in and its header line spans it: the
# widest line is the layout width.  37x123 is a size nothing defaults to.
# A TERM no terminfo has stands in for xterm-kitty and xterm-ghostty, which are
# unknown to some hosts and known to others: tput fails for it everywhere.
unknown_term=sq-test-unknown-term
tput_fails() { ! TERM=$unknown_term tput cols >/dev/null 2>&1; }
pty_case() {   # pty_case ROWS COLS TERM [VAR=value...]: sq on a pty of that size
	local rows=$1 cols=$2 term=$3; shift 3      # and TERM, no size in the env but VARs
	PTY=1 PTY_ROWS=$rows PTY_COLS=$cols sq_run wide TERM="$term" -SQ_WIDTH -SQ_HEIGHT "$@" --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	need "the job row is there"       row_cell queue 8001
	need "the shrunk NAME column keeps USER aligned" column_aligned USER
	need "coloured, as on a terminal" eval '[ "$(escapes)" -gt 0 ]'
}
c_pty_xterm() {
	T_TITLE="TERM=xterm-256color on a 123-column pty: laid out at 123 columns"
	pty_case 37 123 xterm-256color
	need "widest line is 123"         eval '[ "$(width)" -eq 123 ]'
	need "the size asked of stty once" eval '[ "$(stty_size_calls)" -eq 1 ]'
}
c_pty_unknown_term() {
	T_TITLE="a TERM unknown to terminfo (as kitty, ghostty can be) on a 123-column pty: laid out at 123 columns, via stty size"
	pty_case 37 123 "$unknown_term"
	need "tput really fails for $unknown_term" tput_fails
	need "widest line is 123"         eval '[ "$(width)" -eq 123 ]'
	need "the size asked of stty once" eval '[ "$(stty_size_calls)" -eq 1 ]'
}
c_pty_stdin_null() {
	T_TITLE="stdin </dev/null on a 123-column pty, TERM unknown to terminfo: still 123, the size comes from /dev/tty"
	PTY_STDIN=/dev/null pty_case 37 123 "$unknown_term"
	need "tput really fails for $unknown_term" tput_fails
	need "widest line is 123"         eval '[ "$(width)" -eq 123 ]'
}
c_pty_columns_wins() {
	T_TITLE="COLUMNS=90 on a 123-column pty, TERM unknown to terminfo: laid out at 90, the env wins over stty"
	pty_case 37 123 "$unknown_term" COLUMNS=90
	need "widest line is 90"          eval '[ "$(width)" -eq 90 ]'
	need "stty asked once, for the lines" eval '[ "$(stty_size_calls)" -eq 1 ]'
}
c_pty_env_both() {
	T_TITLE="COLUMNS=90 LINES=30 on a 123-column pty: laid out at 90, stty never asked"
	pty_case 37 123 "$unknown_term" COLUMNS=90 LINES=30
	need "widest line is 90"          eval '[ "$(width)" -eq 90 ]'
	need "stty not asked"             eval '[ "$(stty_size_calls)" -eq 0 ]'
}
c_pty_unsized() {
	T_TITLE="a pty not yet sized (stty says 0 0), TERM=xterm-256color: tput's terminfo default 80, never 0"
	pty_case 0 0 xterm-256color
	need "stty asked once"           eval '[ "$(stty_size_calls)" -eq 1 ]'
	need "widest line is 80"          eval '[ "$(width)" -eq 80 ]'
}
c_no_tty() {
	T_TITLE="no controlling terminal, no TERM, no size in the env: 100 columns, silently"
	NOTTY=1 sq_run wide -SQ_WIDTH -SQ_HEIGHT --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	need "stderr empty"               err_empty
	need "no terminal: stty never got to run" eval '[ "$(stty_size_calls)" -eq 0 ]'
	need "widest line is 100"         eval '[ "$(width)" -eq 100 ]'
}

# ============================================================================
cases=(
	empty mixed array_fold fold_split drain_reason hostile_names trailing_junk
	squeue_fails squeue_hangs squeue_garbage both_fail
	finished user_filter sacct_fallback
	refuse_t_empty refuse_states_eq accept_S_empty refuse_s refuse_json refuse_O
	colour layout_size
	pending_range pending_commas pending_throttle pending_no_id_column
	pending_strided xf_pending_long
	malformed_step0 malformed_dots malformed_reversed malformed_multi malformed_dash malformed_huge
	finished_throttled finished_malformed fallback_throttled fallback_malformed
	more_sacct more_fallback more_repeated xf_bitstr
	shrink_pending shrink_fold shrink_finished shrink_floor
	pty_xterm pty_unknown_term pty_stdin_null pty_columns_wins pty_env_both pty_unsized no_tty
)
start=$(date +%s%N)
for c in "${cases[@]}"; do
	if [ ${#only[@]} -gt 0 ]; then
		hit=0; for o in "${only[@]}"; do [ "$c" = "$o" ] && hit=1; done
		[ $hit = 1 ] || continue
	fi
	T_NAME=$c T_TITLE= T_XFAIL= T_CALLS=0 T_FAIL=() T_WANT=() T_TODAY=() run_n=0
	T_DIR=$work/$c; mkdir -p "$T_DIR"
	"c_$c"
	verdict
done
ms=$(( ($(date +%s%N) - start) / 1000000 ))
printf '\n%d passed, %d failed, %d xfail, %d xpass  (%d.%03ds)\n' \
	$n_pass $n_fail $n_xfail $n_xpass $((ms / 1000)) $((ms % 1000))
[ $n_fail -eq 0 ] && [ $n_xpass -eq 0 ]
