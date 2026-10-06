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
	  printf 'i=%s; j=sweep; t=PD; T=PENDING; M=0:00; L=1:00:00; R=(Resources); S=N/A; r=Resources\n' "$2"; } > "$d/squeue"
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
c_pending_long() {
	T_TITLE="a pending id over 31 characters arrives whole (SLURM_BITSTR_LEN=0) and is shown as 10 jobs"
	sq_run pending-long --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	bracket_guards queue 11137 10
	need "cell '11137_[1,3,5,7,9,11,13,15,17,20] ×10'" row_cell queue "11137_[1,3,5,7,9,11,13,15,17,20] ×10"
	need "footer 10/0/10/0"           footer_is 10 0 10 0
	need "no unreadable note"         no_skips
	need "4b(i): shown but counted 1" eval '
		! { rows queue | grep -q "^ *11137_" && section footer | grep -qE "^ *1 jobs "; }'
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
c_bitstr() {
	T_TITLE="every squeue and sacct call carries SLURM_BITSTR_LEN=0"
	sq_run sacct-fails --
	need "rc 0"                       rc_is 0
	need "stubs: queue, sacct and fallback all called" calls_are 1 1 1 1
	need "every squeue and sacct call has SLURM_BITSTR_LEN=0" all_calls_env SLURM_BITSTR_LEN 0 squeue sacct
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
# sq does not pin the locale: under LC_ALL=C length() counts bytes and "…" is
# 3, so the elision must measure it rather than assume 1.  Only ×N and valid
# UTF-8 are asserted here: the rest of the layout is byte-based under C anyway.
# Validity is checked byte by byte in gawk, needing no tool beyond the suite's.
utf8_valid() {
	LC_ALL=C gawk '{ s = $0
		gsub(/[\x01-\x7F]|[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF][\x80-\xBF]|\xED[\x80-\x9F][\x80-\xBF]|\xF0[\x90-\xBF][\x80-\xBF][\x80-\xBF]|[\xF1-\xF3][\x80-\xBF][\x80-\xBF][\x80-\xBF]|\xF4[\x80-\x8F][\x80-\xBF][\x80-\xBF]/, "", s)
		if (s != "") bad++ } END { exit bad > 0 }' "$OUT"
}
c_shrink_locale() {
	T_TITLE="under LC_ALL=C the elided 600_[…] still keeps its exact ×67, in valid UTF-8"
	local wd
	for wd in 80 79; do                 # 79: where a byte-counted cut split a character
		sq_run shrink-pending SLURM_BITSTR_LEN=0 LC_ALL=C SQ_WIDTH=$wd --
		need "$wd: rc 0"              rc_is 0
		need "$wd: stubs called"      calls_are 1 1 0 1
		need "$wd: the 600 row shows ×67" eval '[ "$(xmarks queue 600)" = 67 ]'
		need "$wd: valid UTF-8"       utf8_valid
	done
}
# A NAME is no id, even one that looks like a bracket: it keeps the plain cut
name_cut() {         # name_cut SECTION ID: the NAME of row ID is a right cut of the full name
	rows "$1" | ID=$2 LC_ALL=$utf8 gawk '
		BEGIN { full = "sweep_[1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46] ×16" }
		$1 == ENVIRON["ID"] && $2 ~ /…$/ && index(full, substr($2, 1, length($2) - 1)) == 1 { f = 1 }
		END { exit !f }'
}
c_shrink_name() {
	T_TITLE="a NAME that looks like a bracket keeps the plain right cut, in both tables"
	sq_run shrink-name SQ_WIDTH=80 --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	need "queue NAME right-cut"       name_cut queue 1101
	need "finished NAME right-cut"    name_cut recent 1001
	need "no cut inside a name's brackets" eval 'lacks "…]" && lacks "×16"'
}
# How far each rung goes: rung 4 shaves JOBID down to the widest BASE_[…] ×N
# and no further, and only as far as needed; idfit keeps every term that fits
c_shrink_extent() {
	T_TITLE="rung 4 stops at BASE_[…] ×N and only when needed; idfit keeps every whole term that fits"
	sq_run shrink-finished SLURM_BITSTR_LEN=0 SQ_WIDTH=50 SQ_RECENT_MAX=5 --
	need "50: rc 0"                   rc_is 0
	need "50: cell '600_[1,…] ×67'"   row_cell recent "600_[1,…] ×67"
	need "50: cell '5000_[…] ×30'"    row_cell recent "5000_[…] ×30"
	local wd
	for wd in 53 55; do
		sq_run shrink-finished SLURM_BITSTR_LEN=0 SQ_WIDTH=$wd SQ_RECENT_MAX=5 --
		need "$wd: rc 0"              rc_is 0
		need "$wd: ×67 and ×30 kept"  eval '[ "$(xmarks recent 600)" = 67 ] && [ "$(xmarks recent 5000)" = 30 ]'
		need "$wd: STATE keeps its words" eval 'rows recent | grep -qE "^ *600_.* CANCELLED " && rows recent | grep -qE "^ *5000_.* FAILED "'
	done
	sq_run shrink-pending SLURM_BITSTR_LEN=0 SQ_WIDTH=65 --
	need "65: rc 0"                   rc_is 0
	need "65: cell '600_[1,…] ×67'"   row_cell queue "600_[1,…] ×67"
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

# ---- 13. COMPACT: the target screens Franz accepted ---------------------------
# COMPACT fits the screen: sections collapse into "… n jobs <category>" lines by
# the priority Franz chose.  He chose it by picking among real screens a
# prototype rendered, then accepted the combined result; these cases hold what
# makes each accepted screen the accepted one (which rows survive, which
# ellipsis lines with which counts and where, the finished and node forms, how
# many lines and blanks), never a snapshot of it: column spacing, bars and the
# AGO column are free.  The fixtures' finished times are fixed, so AGO grows
# with the calendar and is asserted nowhere.
# COMPACT is asked for with --compact and sized by SQ_WIDTH/SQ_HEIGHT.  Every
# case first runs the same fixture with --full: that run pins the fixture's
# counts.

# The screen, one line per screen line: LABEL, a tab, the text without its
# margin.  TITLE BLANK NODE NREASON (a node's ↳ line) DIGEST (the one-line node
# summary) QHDR QROW QELL (a "… n jobs" line) QNOTE FINLINE (the one-line
# finished form) FINCAP FHDR FROW FMORE FOOTER, and OTHER for anything else.
# The queue table runs from its header to the next blank line, the finished
# block from its caption to the next blank line; worked out once per run.
screen() {
	[ -f "$RUN/screen" ] || plain | LC_ALL=$utf8 gawk '
		BEGIN { HDR = "^[A-Z][A-Z/_()]*( +[A-Z][A-Z/_()]*)*$" }
		{ t = $0; sub(/^ +/, "", t); sub(/ +$/, "", t) }
		NR == 1 && t ~ /^▌ SLURM /                    { print "TITLE\t" t; next }
		t == ""                                       { print "BLANK\t"; zone = ""; next }
		t ~ /^[0-9]+ jobs +[0-9]+ running /           { print "FOOTER\t" t; zone = ""; next }
		t ~ /^recently finished( \([^)]*\))?: /       { print "FINLINE\t" t; zone = ""; next }
		t ~ /^(recently finished|finished jobs unavailable)/ { print "FINCAP\t" t; zone = "f"; next }
		zone == "f" && t ~ HDR                        { print "FHDR\t" t; next }
		zone == "f" && t ~ /^\+[0-9]+ more$/          { print "FMORE\t" t; next }
		zone == "f"                                   { print "FROW\t" t; next }
		!seenq && t ~ HDR                             { print "QHDR\t" t; zone = "q"; seenq = 1; next }
		zone == "q" && t ~ /^… [0-9]+ jobs /          { print "QELL\t" t; next }
		zone == "q" && t ~ /^(↳|⚠)/                   { print "QNOTE\t" t; next }
		zone == "q"                                   { print "QROW\t" t; next }
		t ~ /^nodes: /                                { print "DIGEST\t" t; next }
		t ~ /^↳ /                                     { print "NREASON\t" t; next }
		t ~ /[0-9-]+\/[0-9]+ cpu/                     { print "NODE\t" t; next }
		{ print "OTHER\t" t }' > "$RUN/screen"
	cat "$RUN/screen"
}
labelled() { screen | gawk -F'\t' -v l="$1" '$1 == l { print $2 }'; }   # labelled LABEL: those lines' text
first_words() { gawk '{ print $1 }' | paste -sd' '; }                  # stdin's first fields, on one line
# the queue table in display order, "|" between entries: a row as its id, an
# ellipsis line as itself, e.g. "4201|4202|… 20 jobs pending|3990_[0-13]"
queue_seq() {
	screen | gawk -F'\t' '$1 == "QROW" { split($2, f, " "); printf "%s%s", s, f[1]; s = "|" }
		$1 == "QELL" { printf "%s%s", s, $2; s = "|" } END { print "" }'
}
lines_are()    { [ "$(plain | wc -l)" -eq "$1" ]; }
lines_within() { [ "$(plain | wc -l)" -le "$1" ]; }
blanks_are()   { [ "$(labelled BLANK | wc -l)" -eq "$1" ]; }
footer_last()  { # footer_last JOBS RUNNING PENDING OTHER: the one footer, on the last line
	[ "$(labelled FOOTER | wc -l)" -eq 1 ] &&
	plain | tail -n 1 | grep -qE "^ *$1 jobs +$2 running +$3 pending +$4 other\$"
}
# the title is "▌ SLURM <host>  HH:MM:SS", nothing more, whatever the host is called
# (CALL (made inside the target screens, listed to Franz, overrulable): no "· compact" mode marker)
title_first()  { screen | head -n 1 | grep -qE '^TITLE'$'\t''▌ SLURM [^ ]+  [0-9]{2}:[0-9]{2}:[0-9]{2}$'; }
nothing_unlabelled() { [ -z "$(labelled OTHER)$(labelled QNOTE)" ]; }
qrows_are()    { [ "$(labelled QROW | first_words)" = "$1" ]; }
ellipses_are() { [ "$(labelled QELL | paste -sd'|')" = "$1" ]; }
queue_seq_is() { [ "$(queue_seq)" = "$1" ]; }
running_rows_are() { [ "$(labelled QROW | grep -E ' RUNNING ' | first_words)" = "$1" ]; }
nodes_digest() { [ "$(labelled DIGEST)" = "$1" ] && [ -z "$(labelled NODE)$(labelled NREASON)" ]; }
nodes_full()   { # nodes_full "NODE..." "↳ LINE": those node lines and that reason line, no digest
	[ "$(labelled NODE | first_words)" = "$1" ] && [ "$(labelled NREASON)" = "$2" ] && [ -z "$(labelled DIGEST)" ]
}
fin_line_is()  { [ "$(labelled FINLINE)" = "$1" ] && [ -z "$(labelled FINCAP)$(labelled FHDR)$(labelled FROW)$(labelled FMORE)" ]; }
fin_block_is() { # fin_block_is CAPTION "ID..." "+N more"|"": the block form, exactly those rows
	[ "$(labelled FINCAP)" = "$1" ] && [ "$(labelled FROW | first_words)" = "$2" ] &&
	[ "$(labelled FMORE)" = "$3" ] && [ -z "$(labelled FINLINE)" ] &&
	[ "$(labelled FHDR | wc -l)" -eq "$([ -n "$2" ] && echo 1 || echo 0)" ]
}
# the JOBID column is as wide as the ids SHOWN, not those collapsed away: NAME
# starts at most GAP_MAX (4) after the widest shown id cell (an id and its ×N).
# CALL (made inside the target screens, listed to Franz, overrulable): column widths come from the shown rows only
jobid_fits_shown() {
	{ labelled QHDR; labelled QROW; } | LC_ALL=$utf8 gawk '
		NR == 1 { off = index($0, "NAME") - index($0, "JOBID"); next }
		{ c = $1; if ($2 ~ /^×[0-9]+$/) c = c " " $2; if (length(c) > m) m = length(c) }
		END { if (m < 5) m = 5; exit !(off > 0 && off - m <= 4) }'
}
# what two runs of the same screen may differ in: the title's clock, and AGO,
# which can tick over an hour between them (the fixtures' end times are fixed)
without_clock_ago() { sed -E '1s/[0-9]{2}:[0-9]{2}:[0-9]{2}$//; s/ +([0-9]+[smh]|-)$//' "$1"; }

# compact_case FIXTURE W H "SINFO QUEUE FALLBACK SACCT" "JOBS RUNNING PENDING OTHER" [VAR=value...]
# The FULL twin, then COMPACT at W x H with what every accepted screen has: it
# fits, the footer is last with the fixture's counts, the title first.  Leaves
# the COMPACT run for the case's own checks, and FULL_OUT for the twin's output.
# VARs go to both runs.
compact_case() {
	local fx=$1 w=$2 h=$3; local -a calls foot extra=("${@:6}")
	read -ra calls <<< "$4"; read -ra foot <<< "$5"
	sq_run "$fx" SQ_WIDTH="$w" SQ_HEIGHT="$h" "${extra[@]}" -- --full
	need "FULL: rc 0"                     rc_is 0
	need "FULL: stubs called"             calls_are "${calls[@]}"
	need "FULL: footer ${foot[*]}"        footer_is "${foot[@]}"
	FULL_OUT=$OUT
	sq_run "$fx" SQ_WIDTH="$w" SQ_HEIGHT="$h" "${extra[@]}" -- --compact
	need "rc 0"                           rc_is 0
	need "stderr empty"                   err_empty
	need "stubs called as for FULL"       calls_are "${calls[@]}"
	need "at most $h lines"               lines_within "$h"
	need "no line wider than $w"          eval '[ "$(width)" -le '"$w"' ]'
	need "footer ${foot[*]}, on the last line" footer_last "${foot[@]}"
	need "the title first, with no mode marker" title_first
	need "every line is a known part of the screen" nothing_unlabelled
}
# compact_queue "ENTRY|ENTRY|...": the queue table is exactly these rows (by id)
# and "… n jobs" lines, in this order; three checks, so a failure says which part
compact_queue() {
	local rows ells nrows
	rows=$(tr '|' '\n' <<< "$1" | grep -v '^… ' | paste -sd' ')
	ells=$(tr '|' '\n' <<< "$1" | grep '^… ' | paste -sd'|')
	nrows=$(wc -w <<< "$rows")
	need "the accepted $nrows queue rows, in squeue order" qrows_are "$rows"
	# CALL (made inside the target screens, listed to Franz, overrulable): one "… n jobs <category>" line per section, the category named
	# (stuck, blocked on nodes, held by admin, pending, running, other)
	need "ellipsis lines exactly: ${ells:-none}"           ellipses_are "$ells"
	# decision 24: the pending categories' lines sit together at the END of the
	# pending block (stuck, blocked on nodes, held by admin, pending); running's
	# and other's after their own rows
	need "each '… n jobs' line where decision 24 puts it" queue_seq_is "$1"
}
compact_lines() {   # compact_lines N BLANKS: the screen is N lines, BLANKS of them blank
	need "$1 lines"                       lines_are "$1"
	need "$2 blank lines"                 blanks_are "$2"
}
busy_nodes_full()   { need "both nodes in full, node02's reason below it" nodes_full "node01 node02" "↳ Not responding · since 2026-10-05"; }
busy_finished_line() { need "the finished block is one line: the newest failure" fin_line_is "recently finished: 4188 qc FAILED 1"; }
mix_nodes_full()    { need "both nodes in full, node02's reason below it" nodes_full "node01 node02" "↳ bad DIMM B2, replace · since 2026-10-04"; }
mix_finished_line() { need "the finished block is one line: the newest failure" fin_line_is "recently finished: 5097 fastp FAILED 2"; }
narrow_ids()        { need "the JOBID column only as wide as the shown ids" jobid_fits_shown; }
busy_pending_floor="4201|4202|4207|… 20 jobs pending"     # stuck, blocked, the pending floor
busy_running_all="3990_[0-13]|3990_[14-27]|3990_[28-41]|3990_[42-55]|3990_[56-69]|3990_[70-83]|3990_[84-97]|3990_[98-111]|4100|4101|4102|4103|4104|4105|4106|4107|4108|4109|4110|4111|4112|4113|4114|4115"
busy_finished_all="4195 4193 4188 4180_[0-7] 4176 4170 4165 4160 4150_[0-3] 4120"

c_compact_tiny_h10() {   # decision 1's own scenario, decision 9's screen
	T_TITLE="tiny at 10 lines: the stuck job and the one-line failure stay, every '… n jobs' goes, the 4 blanks stay"
	compact_case tiny 100 10 "1 1 0 1" "151 128 23 0"
	compact_lines 10 4
	need "the one node in full"           nodes_full node01 ""
	compact_queue "4201"
	need "the finished block is one line: the newest failure" fin_line_is "recently finished: 4188 qc FAILED 1"
	narrow_ids
}
c_compact_busy24_h8() {   # decisions 10 and 11
	T_TITLE="busy24 at 8 lines: the node summary line, all three stuck/blocked jobs AND the failure, no blank"
	compact_case busy24 100 8 "1 1 0 1" "151 128 23 0"
	compact_lines 8 0
	need "the nodes as one summary line"  nodes_digest "nodes: 1 allocated, 1 down* · 128/256 cpu"
	compact_queue "4201|4202|4207"
	busy_finished_line
	narrow_ids
}
c_compact_busy24_h12() {
	T_TITLE="busy24 at 12 lines: nodes in full, stuck and blocked rows, no '… n jobs' line yet"
	compact_case busy24 100 12 "1 1 0 1" "151 128 23 0"
	compact_lines 12 2
	busy_nodes_full
	compact_queue "4201|4202|4207"
	busy_finished_line
	narrow_ids
}
c_compact_busy24_h16() {   # decision 2's sketch: pending reduces to its ellipsis
	T_TITLE="busy24 at 16 lines: '… 20 jobs pending' and '… 128 jobs running' with no row of either"
	compact_case busy24 100 16 "1 1 0 1" "151 128 23 0"
	compact_lines 16 4
	busy_nodes_full
	compact_queue "$busy_pending_floor|… 128 jobs running"
	busy_finished_line
	narrow_ids
}
c_compact_busy24_h20() {
	T_TITLE="busy24 at 20 lines: the 4 longest-running array rows, '… 72 jobs running'"
	compact_case busy24 100 20 "1 1 0 1" "151 128 23 0"
	compact_lines 20 4
	busy_nodes_full
	compact_queue "$busy_pending_floor|3990_[0-13]|3990_[14-27]|3990_[28-41]|3990_[42-55]|… 72 jobs running"
	busy_finished_line
}
c_compact_busy24_h24() {   # decision 13: hidden rows between shown ones
	T_TITLE="busy24 at 24 lines: the 8 longest-running rows (3990_[84-111] and 4100-4111 hidden among them), '… 42 jobs running'"
	compact_case busy24 100 24 "1 1 0 1" "151 128 23 0"
	compact_lines 24 4
	busy_nodes_full
	compact_queue "$busy_pending_floor|3990_[0-13]|3990_[14-27]|3990_[28-41]|3990_[42-55]|3990_[56-69]|3990_[70-83]|4112|4113|… 42 jobs running"
	busy_finished_line
}
c_compact_busy24_h30() {
	T_TITLE="busy24 at 30 lines: every array row and 4108/4109/4112-4115, '… 10 jobs running'"
	compact_case busy24 100 30 "1 1 0 1" "151 128 23 0"
	compact_lines 30 4
	busy_nodes_full
	compact_queue "$busy_pending_floor|3990_[0-13]|3990_[14-27]|3990_[28-41]|3990_[42-55]|3990_[56-69]|3990_[70-83]|3990_[84-97]|3990_[98-111]|4108|4109|4112|4113|4114|4115|… 10 jobs running"
	busy_finished_line
}
busy_all_running() {   # busy_all_running H: every running job fits, the finished block stays one line, 39 lines
	compact_case busy24 100 "$1" "1 1 0 1" "151 128 23 0"
	compact_lines 39 4
	busy_nodes_full
	compact_queue "$busy_pending_floor|$busy_running_all"
	busy_finished_line
}
c_compact_busy24_h40() {   # decision 8
	T_TITLE="busy24 at 40 lines: all 128 running shown, the finished block still one line, 39 lines: the spare line stays blank"
	busy_all_running 40
}
c_compact_busy24_h43() {   # decision 8
	T_TITLE="busy24 at 43 lines: the same 39 lines as at 40, the 4 spare lines stay blank, no pending row flows in"
	busy_all_running 43
}
c_compact_busy24_h44() {   # decision 6
	T_TITLE="busy24 at 44 lines: once every running job fits, the finished block grows: down to the failure, '+17 more'"
	compact_case busy24 100 44 "1 1 0 1" "151 128 23 0"
	compact_lines 44 4
	busy_nodes_full
	compact_queue "$busy_pending_floor|$busy_running_all"
	need "the finished block: caption, header, 4195 4193 4188, '+17 more'" fin_block_is "recently finished · last 2h" "4195 4193 4188" "+17 more"
}
c_compact_busy24_h52() {
	T_TITLE="busy24 at 52 lines: the whole finished block, then pending gets rows: 4203 4204, and '… 18 jobs pending' after 4207, the pending block's end"
	compact_case busy24 100 52 "1 1 0 1" "151 128 23 0"
	compact_lines 52 4
	busy_nodes_full
	compact_queue "4201|4202|4203|4204|4207|… 18 jobs pending|$busy_running_all"
	need "the whole finished block, no '+N more'" fin_block_is "recently finished · last 2h" "$busy_finished_all" ""
}
c_compact_busy24_h60() {
	T_TITLE="busy24 at 60 lines: everything, no '… n jobs' line"
	compact_case busy24 100 60 "1 1 0 1" "151 128 23 0"
	compact_lines 60 4
	busy_nodes_full
	compact_queue "4201|4202|4203|4204|4205|4206|4207|4210|4211|4212|4213|4214|4215|4230_[0-9]|$busy_running_all"
	need "the whole finished block, no '+N more'" fin_block_is "recently finished · last 2h" "$busy_finished_all" ""
}
c_compact_elapsed24_h24() {   # decisions 12 and 13
	T_TITLE="elapsed24 at 24 lines: the 8 longest-running jobs survive, shown in squeue order; 3900 and the 3990 array, listed first, are hidden"
	compact_case elapsed24 100 24 "1 1 0 1" "151 128 23 0"
	compact_lines 24 4
	busy_nodes_full
	need "running survivors 4101 4103 4104 4106 4108 4110 4112 4114: the longest TIME, in squeue order" \
		running_rows_are "4101 4103 4104 4106 4108 4110 4112 4114"
	compact_queue "$busy_pending_floor|4101|4103|4104|4106|4108|4110|4112|4114|… 120 jobs running"
	busy_finished_line
	narrow_ids
}
c_compact_emptyfin_h24() {
	T_TITLE="emptyfin at 24 lines: nothing finished, the caption alone says so; the queue as busy24's"
	compact_case emptyfin 100 24 "1 1 0 1" "151 128 23 0"
	compact_lines 24 4
	busy_nodes_full
	compact_queue "$busy_pending_floor|3990_[0-13]|3990_[14-27]|3990_[28-41]|3990_[42-55]|3990_[56-69]|3990_[70-83]|4112|4113|… 42 jobs running"
	need "the finished block is its caption alone" fin_block_is "recently finished · last 2h · nothing in this window" "" ""
}
c_compact_noacct_h24() {
	T_TITLE="noacct at 24 lines: sacct down, the one-line form says '(no accounting)' and still shows the failure"
	compact_case noacct 100 24 "1 1 1 1" "151 128 23 0"
	compact_lines 24 4
	busy_nodes_full
	compact_queue "$busy_pending_floor|3990_[0-13]|3990_[14-27]|3990_[28-41]|3990_[42-55]|3990_[56-69]|3990_[70-83]|4112|4113|… 42 jobs running"
	need "the finished block is one line: the newest failure, from the fallback" \
		fin_line_is "recently finished (no accounting): 4188 qc FAILED 1"
}
c_compact_quiet40_h40() {
	T_TITLE="quiet40 at 40 lines: everything fits, so COMPACT is FULL byte for byte, the title's clock aside"
	compact_case quiet40 100 40 "1 1 0 1" "7 5 2 0"
	compact_lines 24 4
	need "the same bytes as FULL, the clock and AGO aside" eval 'cmp -s <(without_clock_ago "$FULL_OUT") <(without_clock_ago "$OUT")'
}
mix_case() {   # mix_case H: mix30 at 110 x H
	compact_case mix30 110 "$1" "1 1 0 1" "75 43 30 2"
	mix_nodes_full
}
c_compact_mix30_h16() {
	T_TITLE="mix30 at 16 lines: held-by-admin, stuck and blocked rows, '… 26 jobs pending'; running and other only in the footer"
	mix_case 16
	compact_lines 16 4
	compact_queue "5110|5112|5113|5118|… 26 jobs pending"
	mix_finished_line
	narrow_ids
}
c_compact_mix30_h18() {   # decision 7
	T_TITLE="mix30 at 18 lines: COMPLETING and SUSPENDED in their own '… 2 jobs other', after '… 43 jobs running', below the pending block"
	mix_case 18
	compact_lines 18 4
	compact_queue "5110|5112|5113|5118|… 26 jobs pending|… 43 jobs running|… 2 jobs other"
	mix_finished_line
	narrow_ids
}
c_compact_mix30_h30() {
	T_TITLE="mix30 at 30 lines: 12 longest-running rows, '… 3 jobs running' hides 5060-5062, then '… 2 jobs other'"
	mix_case 30
	compact_lines 30 4
	compact_queue "5110|5112|5113|5118|… 26 jobs pending|5050_[0-7]|5050_[8-15]|5050_[16-23]|5050_[24-31]|5063|5064|5065|5066|5067|5068|5069|5070|… 3 jobs running|… 2 jobs other"
	mix_finished_line
}
c_compact_mix30_h45() {
	T_TITLE="mix30 at 45 lines: all running and other rows, the whole finished block, then 3 pending rows, and '… 23 jobs pending' after 5118, the pending block's end"
	mix_case 45
	compact_lines 45 4
	compact_queue "5101|5110|5111|5112|5113|5114|5115|5118|… 23 jobs pending|5050_[0-7]|5050_[8-15]|5050_[16-23]|5050_[24-31]|5060|5061|5062|5063|5064|5065|5066|5067|5068|5069|5070|5045"
	need "the whole finished block, no '+N more'" fin_block_is "recently finished · last 2h" "5098 5097 5095 5090_[0-9] 5088 5085 5080 5075" ""
}

# manystuck: busy24 with 30 stuck jobs, under the cap of decision 18
census_says() {      # census_says TOTALS H KEY VALUE: the census of this screen at height H
	[ "$(census "$1" "$2" | gawk -v k="$3" '$1 == k { sub(/^[^ ]+ ?/, ""); print }')" = "$4" ]
}
manystuck_totals="stuck=30 blocked=1 held=0 pending=20 running=128 other=0"
manystuck_case() {   # manystuck_case H
	compact_case manystuck 100 "$1" "1 1 0 1" "179 128 51 0"
	compact_lines "$1" 4
	busy_nodes_full
	busy_finished_line
}
c_compact_manystuck_h16() {   # decision 19: running may show only its count line
	T_TITLE="manystuck at 16 lines: the stuck and blocked floors, running only '… 128 jobs running', the 4 blanks kept"
	manystuck_case 16
	compact_queue "4201|4207|… 29 jobs stuck|… 20 jobs pending|… 128 jobs running"
	need "no running row, only its count line, and still 4 blanks (decision 19)" eval '[ -z "$(labelled QROW | grep " RUNNING ")" ] && blanks_are 4'
}
c_compact_manystuck_h24() {   # decision 18
	T_TITLE="manystuck at 24 lines: stuck+blocked take 6 of the 13 queue lines (4 stuck + 4207 + '… 26 jobs stuck'), running keeps 5 rows"
	manystuck_case 24
	compact_queue "4201|4202|4207|4240|4241|… 26 jobs stuck|… 20 jobs pending|3990_[0-13]|3990_[14-27]|3990_[28-41]|3990_[42-55]|3990_[56-69]|… 58 jobs running"
	need "stuck+blocked+held: 6 lines of the queue table's 13" eval 'census_says "$manystuck_totals" 24 small 6 && census_says "$manystuck_totals" 24 room 13'
}
c_compact_manystuck_h40() {   # decision 18
	T_TITLE="manystuck at 40 lines: stuck+blocked take 14 of the 29 queue lines (12 stuck + 4207 + '… 18 jobs stuck'), running keeps 13 rows"
	manystuck_case 40
	compact_queue "4201|4202|4207|4240|4241|4242|4243|4244|4245|4246|4247|4248|4249|… 18 jobs stuck|… 20 jobs pending|3990_[0-13]|3990_[14-27]|3990_[28-41]|3990_[42-55]|3990_[56-69]|3990_[70-83]|3990_[84-97]|3990_[98-111]|4109|4112|4113|4114|4115|… 11 jobs running"
	need "stuck+blocked+held: 14 lines of the queue table's 29" eval 'census_says "$manystuck_totals" 40 small 14 && census_says "$manystuck_totals" 40 room 29'
}

# manysmall: 12 stuck, 11 blocked, 10 held, interleaved in squeue order, under
# the cap: inside it stuck fills before node-blocked before held (decision 18).
# Reference render: screens/cap/manysmall-h40__half.txt (the prototype, half).
manysmall_totals="stuck=12 blocked=11 held=10 pending=20 running=128 other=0"
c_compact_manysmall_h40() {   # decision 18; the wording "… n jobs blocked on nodes / held by admin" is a CALL (made inside the target screens, listed to Franz, overrulable), on no screen he has seen
	T_TITLE="manysmall at 40 lines: inside the cap stuck fills first (9 rows), blocked and held keep their floors; 14 of the 29 queue lines"
	compact_case manysmall 100 40 "1 1 0 1" "181 128 53 0"
	compact_lines 40 4
	busy_nodes_full
	busy_finished_line
	compact_queue "4201|4202|4207|4240|4242|4243|4246|4249|4252|4255|4258|… 3 jobs stuck|… 10 jobs blocked on nodes|… 9 jobs held by admin|… 20 jobs pending|3990_[0-13]|3990_[14-27]|3990_[28-41]|3990_[42-55]|3990_[56-69]|3990_[70-83]|3990_[84-97]|3990_[98-111]|4109|4112|4113|4114|4115|… 11 jobs running"
	need "stuck+blocked+held: 14 lines of the queue table's 29" eval 'census_says "$manysmall_totals" 40 small 14 && census_says "$manysmall_totals" 40 room 29'
}
# Source: the settled classifier (stuck-classifier notes, 2026-10-06): only a
# closed allow-list of reasons collapses; any other pending reason keeps its row
# as stuck, so an unknown one fails loud instead of vanishing into "… n jobs
# pending".  QOSGrpCpuLimit is on neither list.
c_compact_unlisted_h24() {
	T_TITLE="unlisted at 24 lines: a pending reason on neither list (QOSGrpCpuLimit) keeps its row as stuck, not counted in '… 20 jobs pending'"
	compact_case unlisted 100 24 "1 1 0 1" "152 128 24 0"
	need "4231 (QOSGrpCpuLimit) has a row" eval 'labelled QROW | grep -qE "^4231 .*\(QOSGrpCpuLimit\)$"'
	need "the ordinary pending are still 20 ('… 20 jobs pending') and no stuck/blocked/held line hides it" eval 'labelled QELL | grep -qx "… 20 jobs pending" && ! labelled QELL | grep -qE "jobs (stuck|blocked on nodes|held by admin)$"'
	need "it is counted as stuck: 3 stuck rows" eval 'census "stuck=3 blocked=1 held=0 pending=20 running=128 other=0" 24 | grep -q "^rows stuck=3 "'
}
# quiet40 at 10 lines: no queue block fits, so the blank after the nodes and the
# one before the finished line meet; one of them goes (CALL (made inside the
# target screens, listed to Franz, overrulable): a blank with nothing to
# separate is dropped), the other stays (decision 9: keep the blanks)
labels_are() { [ "$(screen | cut -f1 | paste -sd' ')" = "$1" ]; }
c_compact_quiet40_h10() {
	T_TITLE="quiet40 at 10 lines: of the two blanks that meet, exactly one stays"
	compact_case quiet40 100 10 "1 1 0 1" "7 5 2 0"
	need "title, blank, 2 nodes, ONE blank, the finished line, blank, footer" labels_are "TITLE BLANK NODE NODE BLANK FINLINE BLANK FOOTER"
	need "the finished line is the newest failure" fin_line_is "recently finished: 4098 qc FAILED 1"
}
c_compact_sweep_manysmall() {   # decision 18: the order inside the cap
	T_TITLE="manysmall at every height 6..70: stuck fills before blocked before held, the cap holds and lifts, and every sweep invariant"
	sweep_case manysmall 100 70 "1 1 0 1" "181 128 53 0" "$manysmall_totals" "recently finished: 4188 qc FAILED 1"
}

# What the screen at one height shows, for the sweep: one "KEY VALUE" line each.
#   rows S=N ...   rows shown per section (stuck blocked held pending running
#                  other: from STATE and the reason; finished: the one line counts
#                  1; nodes: node, ↳ and summary lines)
#   acct S ...     sections whose rows and "… n jobs" line do not add up to their
#                  total (TOTALS="S=N ..."), or that have two such lines
#   pair N         1 if two blank lines meet
#   finline TEXT   the one-line finished form, if shown
#   mixedfin N     1 if the one line and the block are both there
#   finoverstuck N 1 if a finished line is shown while the stuck section is not
#   small N        the lines of stuck + blocked + held: their rows and their own
#                  "… n jobs stuck/blocked on nodes/held by admin" lines
#   room N         the queue table's lines: H minus every line outside the table
#                  body (title, blanks, nodes, the table header, finished, footer)
#   cap TEXT       decision 18 broken: running hides jobs, a small section is
#                  past its floor, and small > room/2 rounded down
#   order S        a small section past its floor while one before it (stuck,
#                  then blocked, then held) hides jobs
#   lift N         1 if every running job is shown, a small section hides jobs,
#                  and the screen still has a spare line (the cap did not lift)
#   ellpos N       1 if decision 24 is broken: the stuck / blocked on nodes /
#                  held by admin / pending lines are not together, in that order,
#                  after the last pending row and before running's rows and lines
# A section's floor is 1 row and its "… n jobs" line, or all of it if 2 rows or
# fewer (CALL (made inside the target screens, listed to Franz, overrulable): a small section with
# 2 or more rows has a 2-line floor, never a bare ellipsis); "past its floor":
# more than 2 rows, or 2 rows with jobs still hidden.
census() {   # census TOTALS H
	screen | TOTALS=$1 H=$2 LC_ALL=$utf8 gawk -F'\t' '
		BEGIN { n = split(ENVIRON["TOTALS"], kv, " ")
		        for (i = 1; i <= n; i++) { split(kv[i], p, "="); tot[p[1]] = p[2] }
		        nsec = split("stuck blocked held pending running other", S, " ")
		        # CALL (made inside the target screens, listed to Franz, overrulable): the ellipsis wording names the category
		        L["stuck"] = "stuck"; L["blocked on nodes"] = "blocked"; L["held by admin"] = "held"
		        L["pending"] = "pending"; L["running"] = "running"; L["other"] = "other"
		        RANK["stuck"] = 1; RANK["blocked on nodes"] = 2; RANK["held by admin"] = 3; RANK["pending"] = 4 }
		# the settled classifier (stuck-classifier notes, 2026-10-06): a CLOSED
		# allow-list of collapsible reasons (plus JobHeldUser, which Franz
		# collapses) is ordinary pending; node reasons and the other cluster
		# faults are blocked; JobHeldAdmin and a launch failure Slurm requeued
		# held are held; EVERY OTHER reason is stuck, visible by default, so a
		# misread or unknown reason fails loud (NodeDrain, which 23.11 does not
		# have, among them).  The reason is what the NODE/REASON cell
		# shows inside its parentheses (to the cell'"'"'s end, if the cell was cut).
		function sec(t,   m, r) {
			if (t ~ / RUNNING /) return "running"
			if (t !~ / PENDING /) return "other"
			r = match(t, /\(([^)]*)/, m) ? m[1] : ""
			if (r ~ /^(None|Priority|Resources|Dependency|BeginTime|Prolog|Cleaning|SchedDefer|Reservation|Licenses|JobHeldUser)$/) return "pending"
			if (r ~ /^ReqNodeNotAvail/ || r ~ /^Nodes required for job are / ||
			    r ~ /^(NodeDown|PartitionDown|PartitionInactive|FrontEndDown|PowerNotAvail|PowerReserved)$/) return "blocked"
			if (r == "JobHeldAdmin" || r ~ /requeued held$/) return "held"
			return "stuck"
		}
		{ nl++ }
		$1 == "QROW" || $1 == "QELL" || $1 == "QNOTE" { qbody++ }
		$1 == "BLANK" { if (blank) pair = 1; blank = 1; next }
		{ blank = 0 }
		$1 == "QROW" || $1 == "QELL" { qi++ }
		$1 == "QROW" && $2 ~ / PENDING / { lastpd = qi }
		$1 == "QROW" && $2 ~ / RUNNING / && !firstrun { firstrun = qi }
		$1 == "QELL" && match($2, /^… [0-9]+ jobs (.+)$/, em) && (em[1] in RANK) {
			if (pqi && (qi != pqi + 1 || RANK[em[1]] <= prank)) ellbad = 1
			if (!fpqi) fpqi = qi; pqi = qi; prank = RANK[em[1]] }
		$1 == "QELL" && $2 ~ / jobs (running|other)$/ && !firstrun { firstrun = qi }
		$1 == "QROW" { s = sec($2); rows[s]++; jobs[s] += match($2, /^[^ ]+ ×([0-9]+)( |$)/, m) ? m[1] : 1 }
		$1 == "QELL" { if (match($2, /^… ([0-9]+) jobs (.+)$/, m) && (m[2] in L)) { s = L[m[2]]; nell[s]++; ell[s] = m[1] }
		               else bad = bad " ellipsis?" }
		$1 == "FINLINE" { fin++; finline = $2 }
		$1 == "FROW"    { fin++; block = 1 }
		$1 == "NODE" || $1 == "NREASON" || $1 == "DIGEST" { nodes++ }
		END {
			out = ""
			for (i = 1; i <= nsec; i++) out = out " " S[i] "=" rows[S[i]] + 0
			print "rows" out " finished=" fin + 0 " nodes=" nodes + 0
			for (i = 1; i <= nsec; i++) { s = S[i]
				if (nell[s] > 1) bad = bad " " s
				else if (nell[s] == 1 && (jobs[s] + ell[s] != tot[s] || ell[s] < 2)) bad = bad " " s
				else if (!nell[s] && jobs[s] && jobs[s] != tot[s]) bad = bad " " s }
			print "acct" bad
			print "pair " pair + 0
			print "finline " finline
			print "mixedfin " (finline != "" && block)
			print "finoverstuck " (fin && tot["stuck"] && !rows["stuck"])
			split("stuck blocked held", SM, " ")
			for (i = 1; i <= 3; i++) { s = SM[i]; small += rows[s] + nell[s]
				past[s] = rows[s] > 2 || (rows[s] == 2 && jobs[s] < tot[s]); anypast += past[s]
				if (past[s] && hiding) order = order " " s
				if (jobs[s] < tot[s]) hiding = 1 }
			room = ENVIRON["H"] - nl + qbody
			print "small " small + 0
			print "room " room
			print "cap " ((jobs["running"] < tot["running"] && anypast && small > int(room / 2)) ? small ">" int(room / 2) : "")
			print "order" order
			print "lift " (jobs["running"] == tot["running"] && hiding && nl < ENVIRON["H"])
			print "ellpos " ((ellbad || (fpqi && fpqi < lastpd) || (pqi && firstrun && pqi > firstrun)) ? 1 : 0)
		}'
}
# sweep_case FIXTURE W HMAX "CALLS" "J R P O" "TOTALS" "FINLINE": COMPACT at
# every height from 6 to HMAX, and at each what must hold at ANY height: at most H
# lines, the footer last with the fixture's counts, no line wider than W, no two
# blanks together (a blank with nothing to separate is dropped); every section
# shows all its jobs, none (the footer carries them), or some and one "… n jobs"
# line hiding the rest, at least 2 (decision 3); the one-line finished form,
# wherever it is, names the newest failure; a finished line never outlasts a
# stuck job (decision 10); the cap of decision 18 (see census: small, room, cap,
# order, lift); and no section shows fewer rows on a taller screen than on a
# shorter one (decision 8).  Each failure lists the heights, so one check stands
# for every height.
sweep_case() {
	local fx=$1 w=$2 hmax=$3 totals=$6 finline=$7 h k v; local -a calls foot
	read -ra calls <<< "$4"; read -ra foot <<< "$5"
	sq_run "$fx" SQ_WIDTH="$w" SQ_HEIGHT=50 -- --full
	need "FULL: rc 0"                     rc_is 0
	need "FULL: stubs called"             calls_are "${calls[@]}"
	need "FULL: footer ${foot[*]}"        footer_is "${foot[@]}"
	local -A prev=()
	local ran= fits= footer= narrow= pairs= acct= fin= mixed= overstuck= capped= order= lift= ellpos= shrinks=
	for h in $(seq 6 "$hmax"); do
		sq_run "$fx" SQ_WIDTH="$w" SQ_HEIGHT="$h" -- --compact
		{ rc_is 0 && err_empty && calls_are "${calls[@]}"; } || ran="$ran $h"
		lines_within "$h"                 || fits="$fits $h"
		footer_last "${foot[@]}"          || footer="$footer $h"
		[ "$(width)" -le "$w" ]           || narrow="$narrow $h"
		while read -r k v; do
			case $k in
				rows) local -a now; read -ra now <<< "$v"
				      local kv; for kv in "${now[@]}"; do
				          [ -n "${prev[${kv%=*}]:-}" ] && [ "${kv#*=}" -lt "${prev[${kv%=*}]}" ] &&
				              shrinks="$shrinks $h:${kv%=*}"
				          prev[${kv%=*}]=${kv#*=}
				      done ;;
				acct) [ -z "$v" ] || acct="$acct $h:${v// /,}" ;;
				pair) [ "$v" = 0 ] || pairs="$pairs $h" ;;
				finline) [ -z "$v" ] || [ "$v" = "$finline" ] || fin="$fin $h" ;;
				mixedfin) [ "$v" = 0 ] || mixed="$mixed $h" ;;
				finoverstuck) [ "$v" = 0 ] || overstuck="$overstuck $h" ;;
				cap)   [ -z "$v" ] || capped="$capped $h:$v" ;;
				order) [ -z "$v" ] || order="$order $h:${v// /,}" ;;
				lift)  [ "$v" = 0 ] || lift="$lift $h" ;;
				ellpos) [ "$v" = 0 ] || ellpos="$ellpos $h" ;;
			esac
		done < <(census "$totals" "$h")
	done
	need "rc 0, stderr empty, stubs called at every height (not at:${ran:- none})" test -z "$ran"
	need "at most H lines (more at H =${fits:- none})" test -z "$fits"
	need "footer ${foot[*]} last (not at H =${footer:- none})" test -z "$footer"
	need "no line wider than $w (wider at H =${narrow:- none})" test -z "$narrow"
	# CALL (made inside the target screens, listed to Franz, overrulable): a blank with nothing to separate is dropped
	need "no two blank lines together (at H =${pairs:- none})" test -z "$pairs"
	need "every section: all, none, or rows + one '… n jobs' (n >= 2) adding up to its total (not at H:section${acct:- none})" test -z "$acct"
	need "the one-line finished form is '$finline' (not at H =${fin:- none})" test -z "$fin"
	need "never the one line and the block together (at H =${mixed:- none})" test -z "$mixed"
	need "the stuck jobs outlast the finished block: no finished line while no stuck row is shown (at H =${overstuck:- none})" test -z "$overstuck"
	need "while running hides jobs, stuck+blocked+held past their floors take at most half the queue table's lines (over at H:lines>half${capped:- none})" test -z "$capped"
	need "stuck fills before blocked, blocked before held (not at H:section${order:- none})" test -z "$order"
	need "once every running job is shown the cap lifts: stuck/blocked/held take every spare line (spare at H =${lift:- none})" test -z "$lift"
	need "the pending categories' '… n jobs' lines together at the pending block's end, stuck, blocked, held, pending (decision 24; not at H =${ellpos:- none})" test -z "$ellpos"
	need "a taller screen never shows fewer rows of a section (fewer at H:section${shrinks:- none})" test -z "$shrinks"
}
c_compact_sweep_busy24() {
	T_TITLE="busy24 at every height 6..70: fits, footer last, accounts for every job, never fewer rows on a taller screen"
	sweep_case busy24 100 70 "1 1 0 1" "151 128 23 0" \
		"stuck=2 blocked=1 held=0 pending=20 running=128 other=0" "recently finished: 4188 qc FAILED 1"
}
c_compact_sweep_mix30() {
	T_TITLE="mix30 at every height 6..70: fits, footer last, accounts for every job, never fewer rows on a taller screen"
	sweep_case mix30 110 70 "1 1 0 1" "75 43 30 2" \
		"stuck=1 blocked=2 held=1 pending=26 running=43 other=2" "recently finished: 5097 fastp FAILED 2"
}
c_compact_sweep_manystuck() {   # decision 18: the cap
	T_TITLE="manystuck at every height 6..70: the cap holds while running hides jobs and lifts once it does not, and every sweep invariant"
	sweep_case manystuck 100 70 "1 1 0 1" "179 128 51 0" \
		"stuck=30 blocked=1 held=0 pending=20 running=128 other=0" "recently finished: 4188 qc FAILED 1"
}

c_compact_sweep_quiet40() {   # CALL (made inside the target screens, listed to Franz, overrulable): a blank with nothing to separate is dropped
	T_TITLE="quiet40 at every height 6..30: fits, footer last, no two blank lines together where the queue block vanishes, never fewer rows on a taller screen"
	sweep_case quiet40 100 30 "1 1 0 1" "7 5 2 0" \
		"stuck=0 blocked=0 held=0 pending=2 running=5 other=0" "recently finished: 4098 qc FAILED 1"
}

# faults: the categories of the VISIBLE reasons (a CALL, listed to Franz,
# overrulable; the collapse rule is unchanged): a fault of the cluster is
# blocked on nodes, a launch failure requeued held is held by admin, and
# NodeDrain, no reason 23.11 has, is unknown and so stuck
c_compact_sweep_faults() {
	T_TITLE="faults at every height 6..50: partition, front-end and power faults count as blocked on nodes, 'launch failed requeued held' as held, NodeDrain as stuck; every sweep invariant"
	sweep_case faults 100 50 "1 1 0 1" "21 8 13 0" \
		"stuck=1 blocked=6 held=2 pending=4 running=8 other=0" "recently finished: 600 qc FAILED 1"
	sq_run faults SQ_WIDTH=100 SQ_HEIGHT=17 -- --compact
	need "17 lines: PartitionDown blocked, both requeued-held jobs held, NodeDrain stuck" \
		queue_seq_is "601|604|608|610|… 5 jobs blocked on nodes|… 4 jobs pending|… 8 jobs running"
}

# ---- 14. COMPACT: the behaviour rules no screen shows --------------------------
# Decision 4 (SQ_RECENT_MAX), 20 (no folding), 21 (no measurable size), 22
# (--compact --full), 23 (--reserve), the calls listed with them (SQ_COMPACT),
# and the mode detection settled by measurement: COMPACT on a terminal, or with
# COLUMNS and LINES both in the environment (what watch sets), FULL otherwise.
# Only what the decisions say is asserted; e.g. the wording of a refusal is not
# decided, only that it names what it refuses.
# busy24 tells the modes apart: FULL is all 38 queue rows and no "… n jobs"
# line; COMPACT fits the height, collapses, and keeps the footer last.
busy_full()    { [ -z "$(labelled QELL)" ] && [ "$(labelled QROW | wc -l)" -eq 38 ] && footer_last 151 128 23 0; }
busy_compact() { lines_within "$1" && [ -n "$(labelled QELL)" ] && footer_last 151 128 23 0; }   # busy_compact H
unknown_option() { grep -qxF "sq: $1 is not one of the long options sq forwards; sq -h lists them" "$ERR"; }
no_slurm_call()  { [ "$(grep -c "^CALL" "$LOG")" -eq 0 ]; }
need_refused() {     # need_refused WHAT: this run is a usage error, refused before any Slurm call
	need "$1: rc 2"                   rc_is 2
	need "$1: zero bytes on stdout"   out_empty
	need "$1: no Slurm call"          no_slurm_call
}
stubs_answer() {     # a plain FULL run, so a case made of refusals still proves the stubs answer
	sq_run busy24 --
	need "plain run: rc 0, stubs called" eval 'rc_is 0 && calls_are 1 1 0 1'
}

c_recent_max_full() {   # decision 4, FULL half: true today already
	T_TITLE="FULL uses SQ_RECENT_MAX as given: 6 is 6 rows and '+N more', 100 is every row (not clamped to 25)"
	sq_run many-finished SQ_HEIGHT=20 SQ_RECENT_MAX=6 --
	need "6: rc 0, stubs called"          eval 'rc_is 0 && calls_are 1 1 0 1'
	need "6: exactly 6 finished rows"     eval '[ "$(nrows recent)" -eq 6 ]'
	need "6: '+N more' counts the rest of the 34 jobs" eval '[ $(( $(jobs_shown) + $(more_count) )) -eq 34 ]'
	sq_run many-finished SQ_HEIGHT=20 SQ_RECENT_MAX=100 --
	need "100: rc 0, stubs called"        eval 'rc_is 0 && calls_are 1 1 0 1'
	need "100: all 31 rows, 34 jobs, no '+N more'" eval '[ "$(nrows recent)" -eq 31 ] && [ "$(jobs_shown)" -eq 34 ] && [ -z "$(more_count)" ]'
}
c_compact_recent_max() {   # decision 4, COMPACT half
	T_TITLE="COMPACT takes SQ_RECENT_MAX as a cap: 3 at 60 lines is 4195 4193 4188 and '+17 more'; 100 at 24 lines changes nothing"
	compact_case busy24 100 60 "1 1 0 1" "151 128 23 0" SQ_RECENT_MAX=3
	need "3: the block is 4195 4193 4188 and '+17 more'" fin_block_is "recently finished · last 2h" "4195 4193 4188" "+17 more"
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact
	local plain24=$OUT
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 SQ_RECENT_MAX=100 -- --compact
	need "100 at 24 lines: rc 0, footer last" eval 'rc_is 0 && footer_last 151 128 23 0'
	need "100 at 24 lines: the same screen as without it, clock and AGO aside" eval 'cmp -s <(without_clock_ago "$plain24") <(without_clock_ago "$OUT")'
}
c_compact_no_folding() {   # decision 20
	T_TITLE="samecause at 40 lines: 4 stuck jobs with ONE cause (afterok:3999) keep a row each, as do 4201 4202"
	compact_case samecause 100 40 "1 1 0 1" "155 128 27 0"
	need "6 stuck rows, one per job, no ×N among them" eval '[ "$(labelled QROW | gawk '"'"'$1 ~ /^42(01|02|4[0-3])$/ && $2 !~ /^×/ { print $1 }'"'"' | paste -sd" ")" = "4201 4202 4240 4241 4242 4243" ]'
	need "no '… n jobs stuck' line"       eval '! labelled QELL | grep -q "jobs stuck$"'
}
c_full_flag() {
	T_TITLE="--full with COLUMNS and LINES set (which would mean COMPACT) prints everything"
	sq_run busy24 -SQ_WIDTH -SQ_HEIGHT COLUMNS=100 LINES=24 -- --full
	need "rc 0, stubs called"             eval 'rc_is 0 && calls_are 1 1 0 1'
	need "FULL: all 38 queue rows, no '… n jobs' line, footer last" busy_full
	stubs_answer
}
c_compact_full_both() {   # decision 22
	T_TITLE="--compact --full, in either order, is refused (rc 2) with a message naming both"
	local pair; local -a order
	for pair in "--compact --full" "--full --compact"; do
		read -ra order <<< "$pair"
		sq_run busy24 -- "${order[@]}"
		need_refused "${order[*]}"
		need "${order[*]}: the message names both" eval 'grep -q -- --compact "$ERR" && grep -q -- --full "$ERR" && ! unknown_option "${order[0]}"'
	done
	stubs_answer
}
c_reserve_refused() {   # decision 23: sq only parses --reserve
	T_TITLE="--reserve -1 / x / '' / 1.5 / no value: refused (rc 2) for the value, before any Slurm call"
	local v
	for v in -1 x "" 1.5; do
		sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact --reserve "$v"
		need_refused "--reserve '$v'"
		need "--reserve '$v': refused for its value, naming --reserve" eval 'grep -q -- --reserve "$ERR" && ! unknown_option --compact && ! unknown_option --reserve'
	done
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact --reserve
	need_refused "--reserve with no value"
	need "--reserve with no value: names --reserve" eval 'grep -q -- --reserve "$ERR" && ! unknown_option --compact'
	stubs_answer
}
c_compact_reserve() {   # decision 23
	T_TITLE="--reserve: 0 is no reserve, 2 at 26 lines is the screen of 24, and a reserve leaving one line draws the footer alone"
	compact_case busy24 100 24 "1 1 0 1" "151 128 23 0"
	local seq24 lines24 out24=$OUT
	seq24=$(queue_seq); lines24=$(plain | wc -l)
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact --reserve 0
	need "0: the same screen as no --reserve, clock and AGO aside" eval 'rc_is 0 && cmp -s <(without_clock_ago "$out24") <(without_clock_ago "$OUT")'
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=26 -- --compact --reserve 2
	need "2 at 26 lines: rc 0, footer last" eval 'rc_is 0 && footer_last 151 128 23 0'
	need "2 at 26 lines: the queue and line count of 24 lines" eval '[ "$(queue_seq)" = "$seq24" ] && [ "$(plain | wc -l)" -eq "$lines24" ]'
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact --reserve 23
	need "23 at 24 lines: rc 0, stubs called" eval 'rc_is 0 && calls_are 1 1 0 1'
	need "23 at 24 lines: the footer line alone" eval '[ "$(plain | wc -l)" -eq 1 ] && footer_last 151 128 23 0'
}
c_reservation_forwarded() {   # decision 23's caveat: no prefix clash with --reserve
	T_TITLE="--reservation=x and --reservation x still reach squeue"
	sq_run empty -- --reservation=x
	need "=x: rc 0, sacct skipped for the fallback" eval 'rc_is 0 && calls_are 1 1 1 0'
	need "=x: forwarded"                  argv_has squeue -h -S t,i --reservation=x
	sq_run empty -- --reservation x
	need "x: rc 0, sacct skipped for the fallback" eval 'rc_is 0 && calls_are 1 1 1 0'
	need "x: forwarded"                   argv_has squeue -h -S t,i --reservation x
}
# SQ_COMPACT: a CALL (made with decisions 20-23, listed to Franz, overrulable):
# 0 = always FULL, 1 = always COMPACT, unset = detect; the flags beat it.
# Decision 25: any other value, empty included, means unset, silently
c_sq_compact_env() {
	T_TITLE="SQ_COMPACT=1 is COMPACT into a file; SQ_COMPACT=0 --compact is COMPACT; SQ_COMPACT=1 --full is FULL"
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 SQ_COMPACT=1 --
	need "=1: COMPACT fitted to 24 lines" busy_compact 24
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 SQ_COMPACT=0 -- --compact
	need "=0 --compact: the flag wins, COMPACT" busy_compact 24
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 SQ_COMPACT=1 -- --full
	need "=1 --full: the flag wins, FULL" busy_full
}
c_sq_compact_bad() {   # decision 25
	T_TITLE="SQ_COMPACT=yes, 2 or empty falls back silently to detection: COMPACT on a terminal, FULL into a file"
	local v
	for v in yes 2 ""; do
		PTY=1 PTY_ROWS=24 PTY_COLS=100 sq_run busy24 TERM=xterm-256color -SQ_WIDTH -SQ_HEIGHT SQ_COMPACT="$v" --
		need "'$v' on a terminal: rc 0, stubs called, no message" eval 'rc_is 0 && calls_are 1 1 0 1 && ! plain | grep -q "^sq: "'
		need "'$v' on a terminal: COMPACT fitted to 24 rows" busy_compact 24
		sq_run busy24 -SQ_WIDTH -SQ_HEIGHT SQ_COMPACT="$v" --
		need "'$v' into a file: rc 0, stderr empty, stubs called" eval 'rc_is 0 && err_empty && calls_are 1 1 0 1'
		need "'$v' into a file: FULL" busy_full
	done
}
c_sq_compact_zero_pty() {   # true today already: sq has only FULL
	T_TITLE="SQ_COMPACT=0 on a 24-row terminal is FULL"
	PTY=1 PTY_ROWS=24 PTY_COLS=100 sq_run busy24 TERM=xterm-256color -SQ_WIDTH -SQ_HEIGHT SQ_COMPACT=0 --
	need "rc 0, stubs called"             eval 'rc_is 0 && calls_are 1 1 0 1'
	need "FULL: all 38 queue rows, no '… n jobs' line" busy_full
}
c_auto_compact() {   # detection settled by measurement
	T_TITLE="no flag: a 24-row terminal, or COLUMNS and LINES both set, means COMPACT fitted to 24 lines"
	PTY=1 PTY_ROWS=24 PTY_COLS=100 sq_run busy24 TERM=xterm-256color -SQ_WIDTH -SQ_HEIGHT --
	need "pty: COMPACT fitted to its 24 rows, footer last" busy_compact 24
	sq_run busy24 -SQ_WIDTH -SQ_HEIGHT COLUMNS=100 LINES=24 --
	need "COLUMNS+LINES into a file: COMPACT within LINES" busy_compact 24
}
c_auto_full() {   # detection settled by measurement; true today already
	T_TITLE="no flag, no terminal: COLUMNS alone, LINES alone, neither, or SQ_HEIGHT alone all mean FULL"
	local e; local -a env
	for e in "COLUMNS=100" "LINES=24" "" "SQ_HEIGHT=24"; do
		read -ra env <<< "$e"
		sq_run busy24 -SQ_WIDTH -SQ_HEIGHT "${env[@]}" --
		need "${env[*]:-nothing}: rc 0, stubs called" eval 'rc_is 0 && calls_are 1 1 0 1'
		need "${env[*]:-nothing}: FULL" busy_full
	done
}
c_compact_no_size() {   # decision 21
	T_TITLE="--compact with no measurable size (no terminal, no COLUMNS/LINES/SQ_*) compacts to 24 lines"
	NOTTY=1 sq_run busy24 -SQ_WIDTH -SQ_HEIGHT -- --compact
	need "rc 0, stderr empty, stubs called" eval 'rc_is 0 && err_empty && calls_are 1 1 0 1'
	need "COMPACT fitted to 24 lines, footer last" busy_compact 24
	stubs_answer
}
# oldfail: the newest failure (100) is older than 30 COMPLETED jobs, so it lies
# beyond the 25 rows COMPACT gives the finished block.  The one line names it;
# from 38 lines on the block opens on the 25 newest and "+6 more", and the
# failure is gone from the screen.  Two fixes are rendered for Franz
# (screens/fincap: keepline keeps the one line, pullin makes the failure the
# block's last row); both name it at every height, as this case asks.
c_compact_oldfail() {
	T_TITLE="oldfail at every height 6..60: the newest failure, older than the finished block's cap, is named on screen"
	xfail "$T_TITLE; from 38 lines the block shows the 25 newest and '+6 more' without it, until Franz picks a fix"
	local h ran= lost= shape=
	sq_run oldfail SQ_WIDTH=100 SQ_HEIGHT=50 -- --full
	need "FULL: rc 0, stubs called, footer 1/1/0/0" eval 'rc_is 0 && calls_are 1 1 0 1 && footer_is 1 1 0 0'
	for h in $(seq 6 60); do
		sq_run oldfail SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
		{ rc_is 0 && err_empty && calls_are 1 1 0 1 && lines_within "$h"; } || ran="$ran $h"
		matches '(^ *|: )100 +bad +FAILED +1( |$)' && continue
		lost="$lost $h"
		{ [ "$(labelled FROW | wc -l)" -eq 25 ] && [ "$(labelled FMORE)" = "+6 more" ]; } || shape="$shape $h"
	done
	need "rc 0, stderr empty, stubs called, at most H lines (not at H =${ran:- none})" test -z "$ran"
	want "the failure named at every height (not at H =${lost:- none})" test -z "$lost"
	today "where it is not named: the 25 newest rows and '+6 more' (not so at H =${shape:- none})" test -z "$shape"
}
# foldelapsed: with TIME hidden, array 7000 folds four tasks whose elapsed
# times differ (1 minute, 9 hours); the row survives as long as its
# longest-running task, ahead of the single jobs 7100-7103 (5h-2h)
c_compact_fold_elapsed() {   # decisions 12 and 13
	T_TITLE="foldelapsed, TIME hidden: a folded row survives by its longest-running task (7000_1, 9h), ahead of 7100 (5h)"
	sq_run foldelapsed SQ_WIDTH=100 SQ_HEIGHT=50 SQ_FMT=i,j,u,T -- --full
	need "FULL: rc 0, the array folded into one row" eval 'rc_is 0 && calls_are 1 1 0 1 && row_cell queue "7000_[0-3] ×4"'
	sq_run foldelapsed SQ_WIDTH=100 SQ_HEIGHT=12 SQ_FMT=i,j,u,T -- --compact
	need "12 lines: rc 0, footer last"   eval 'rc_is 0 && footer_last 8 8 0 0'
	need "12 lines: the array row alone survives" queue_seq_is "7000_[0-3]|… 4 jobs running"
	sq_run foldelapsed SQ_WIDTH=100 SQ_HEIGHT=13 SQ_FMT=i,j,u,T -- --compact
	need "13 lines: then 7100, the longest of the single jobs" queue_seq_is "7000_[0-3]|7100|… 3 jobs running"
}
# The colours of finished rows: one table (fcol) decides them in both modes, so
# CANCELLED, PREEMPTED and REVOKED read yellow, never red like a failure.  In
# endstates they are newer than the one FAILED job, so COMPACT looks past them
# for the newest failure.  Everything fits, so COMPACT is FULL byte for byte.
sgr_of() { plain_rows_with "$1" | LC_ALL=C grep -o "$ESC\[[0-9;]*m" | paste -sd' '; }   # sgr_of TEXT: the escapes of the row holding TEXT
plain_rows_with() { LC_ALL=C grep -aF -- "$1" "$OUT"; }
# the clock and AGO, with the escapes around them, are what two runs may differ in
without_clock_ago_sgr() { sed -E "/SLURM/s/[0-9]{2}:[0-9]{2}:[0-9]{2}//; s/ +([0-9]+[smh]|-)($ESC\[[0-9;]*m)?\$//" "$1"; }
c_compact_colour() {
	T_TITLE="--color: CANCELLED, PREEMPTED and REVOKED rows are coloured alike in COMPACT and FULL, and COMPACT is FULL when everything fits"
	local st full=() fullout names=(stopped bumped fed)     # their job names
	sq_run endstates -- --color --full
	need "FULL: rc 0, stubs called"       eval 'rc_is 0 && calls_are 1 1 0 1'
	for st in "${names[@]}"; do full+=("$(sgr_of "$st")"); done
	fullout=$OUT
	sq_run endstates -- --color --compact
	need "COMPACT: rc 0, stubs called"    eval 'rc_is 0 && calls_are 1 1 0 1'
	local i=0
	for st in CANCELLED PREEMPTED REVOKED; do
		need "$st: the same colours as in FULL, yellow (33)" eval '[ "$(sgr_of "${names['"$i"']}")" = "${full['"$i"']}" ] && grep -q "\[33m" <<< "${full['"$i"']}"'
		i=$((i+1))
	done
	need "the same bytes as FULL, the clock and AGO aside" eval 'cmp -s <(without_clock_ago_sgr "$fullout") <(without_clock_ago_sgr "$OUT")'
}
# Below 5 lines a height is still a height in COMPACT, down to the footer
# alone (a CALL, listed to Franz, overrulable); FULL keeps reading such a
# height as no usable size, as today
c_compact_low_heights() {
	T_TITLE="COMPACT at 1-4 lines fits them, the footer alone at 1; FULL still reads them as 24"
	local h
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --full
	need "FULL at 24: rc 0" rc_is 0
	local full24=$OUT
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=3 -- --full
	need "FULL at 3: the screen of 24, clock and AGO aside" eval 'rc_is 0 && cmp -s <(without_clock_ago "$full24") <(without_clock_ago "$OUT")'
	for h in 1 2 3 4; do
		sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
		need "$h: rc 0, stubs called, at most $h lines, footer last" eval 'rc_is 0 && calls_are 1 1 0 1 && lines_within '"$h"' && footer_last 151 128 23 0'
	done
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=1 -- --compact
	need "1: the footer alone" lines_are 1
}
# error screens: sinfo failing (the unreachable banner), squeue failing, a cut
# queue stream (qtrunc) and an unreadable one (qbad, no footer): at every
# height the screen fits and a footer, if any, is the last line
error_sweep() {   # error_sweep FIXTURE "CALLS"
	local fx=$1 h fits= foot= wide=
	sq_run "$fx" --
	need "$fx FULL: rc 0, stubs called" eval 'rc_is 0 && calls_are '"$2"
	for h in $(seq 6 30); do
		sq_run "$fx" SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
		{ rc_is 0 && lines_within "$h"; } || fits="$fits $h"
		[ -z "$(labelled FOOTER)" ] || { [ "$(labelled FOOTER | wc -l)" -eq 1 ] && screen | tail -n 1 | grep -q '^FOOTER'; } || foot="$foot $h"
		[ "$(width)" -le 100 ] || wide="$wide $h"
	done
	need "$fx: rc 0 and at most H lines (not at H =${fits:- none})" test -z "$fits"
	need "$fx: a footer is the last line (not at H =${foot:- none})" test -z "$foot"
	need "$fx: no line wider than 100 (wider at H =${wide:- none})" test -z "$wide"
}
c_compact_error_screens() {
	T_TITLE="COMPACT error screens at every height 6..30: sinfo failing, squeue failing, a cut and an unreadable queue stream fit, footer last when there is one"
	error_sweep sinfo-fails "1 1 0 1"
	error_sweep squeue-fails "1 1 0 1"
	error_sweep queue-cut "1 1 0 1"
	error_sweep squeue-garbage "1 1 0 1"
}

# ============================================================================
cases=(
	empty mixed array_fold fold_split drain_reason hostile_names trailing_junk
	squeue_fails squeue_hangs squeue_garbage both_fail
	finished user_filter sacct_fallback
	refuse_t_empty refuse_states_eq accept_S_empty refuse_s refuse_json refuse_O
	colour layout_size
	pending_range pending_commas pending_throttle pending_no_id_column
	pending_strided pending_long
	malformed_step0 malformed_dots malformed_reversed malformed_multi malformed_dash malformed_huge
	finished_throttled finished_malformed fallback_throttled fallback_malformed
	more_sacct more_fallback more_repeated bitstr
	shrink_pending shrink_fold shrink_finished shrink_floor
	shrink_locale shrink_name shrink_extent
	pty_xterm pty_unknown_term pty_stdin_null pty_columns_wins pty_env_both pty_unsized no_tty
	compact_tiny_h10 compact_busy24_h8 compact_busy24_h12 compact_busy24_h16
	compact_busy24_h20 compact_busy24_h24 compact_busy24_h30 compact_busy24_h40
	compact_busy24_h43 compact_busy24_h44 compact_busy24_h52 compact_busy24_h60
	compact_elapsed24_h24 compact_emptyfin_h24 compact_noacct_h24 compact_quiet40_h40
	compact_mix30_h16 compact_mix30_h18 compact_mix30_h30 compact_mix30_h45
	compact_manystuck_h16 compact_manystuck_h24 compact_manystuck_h40
	compact_manysmall_h40 compact_unlisted_h24 compact_quiet40_h10
	compact_sweep_busy24 compact_sweep_mix30 compact_sweep_manystuck compact_sweep_manysmall
	compact_sweep_quiet40 compact_sweep_faults
	recent_max_full compact_recent_max compact_no_folding compact_colour compact_oldfail compact_fold_elapsed compact_low_heights full_flag compact_full_both
	reserve_refused compact_reserve reservation_forwarded
	sq_compact_env sq_compact_bad sq_compact_zero_pty auto_compact auto_full
	compact_no_size compact_error_screens
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
