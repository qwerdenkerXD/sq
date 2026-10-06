#!/usr/bin/env bash
# sq's regression suite: sq against stubbed Slurm clients, asserting properties
# of its output (counts, rows, captions, escapes, widths, exit codes), never a
# snapshot of it.
#
#   tests/run.sh [-k|--keep] [NAME...]     NAME: run only cases containing it
#
# Needs bash, gawk, coreutils, and util-linux `script` for the pty cases.  The
# stubs in tests/bin stand in for squeue/sinfo/sacct (tests/lib/stub.sh says how,
# tests/FAITHFULNESS.md how they were checked against the real ones).  Every case
# must see a stub answer, so the suite cannot pass against a real Slurm by
# accident.
#
# Results: PASS, FAIL, XFAIL (a known defect, still there, in the documented
# way) and XPASS (a known defect no longer reproduces: remove its xfail marker).
# The run fails on any FAIL or XPASS.

set -u
here=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
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

work=$(mktemp -d) || exit 2
if [ $keep = 1 ]; then echo "evidence kept in $work"; else trap 'rm -rf "$work"' EXIT; fi

ESC=$'\033'

# ============================================================================
# running sq
# ============================================================================
# sq_run FIXTURE [VAR=value | -VAR]... -- [sq args...]
# Runs sq in a clean environment: the stubs first on PATH, a fresh HOME (the
# bell's state file lives under it), a small timeout and a fixed size; VAR=value
# adds or overrides a variable, -VAR removes one.  --no-bell is always passed.
# Leaves OUT, ERR, LOG (the stub log) and RC for the assertions below.
sq_run() {
	local fixture=$1; shift
	local -A env=([PATH]="$here/bin:$PATH" [LC_ALL]=$utf8
	              [SQSTUB_FIXTURE]=$fixtures/$fixture
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
	for k in "${!env[@]}"; do envlist+=("$k=${env[$k]}"); done
	if [ -n "${PTY:-}" ]; then pty_exec "${envlist[@]}" -- "$@"
	else env -i "${envlist[@]}" "$sq" --no-bell "$@" > "$OUT" 2> "$ERR" < /dev/null; RC=$?
	fi
	note_run
}

# The pty variant: sq on a pseudo-terminal of PTY_ROWS x PTY_COLS made by
# util-linux script, so [ -t 1 ] and tput see a terminal.  stdout of script is
# the terminal's output, so OUT gets CRs and colour; plain() takes them out.
pty_exec() {
	local -a envlist=()
	while [ "$1" != -- ]; do envlist+=("$1"); shift; done; shift
	if ! command -v script > /dev/null; then
		T_FAIL+=("util-linux script is not installed (needed for the pty cases)"); RC=127; : > "$OUT"; return
	fi
	local inner
	inner="stty rows $PTY_ROWS cols $PTY_COLS; exec $(printf '%q ' "$sq" --no-bell "$@")"
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
		BEGIN { RS = "" }
		{ split($0, L, "\n"); first = L[1] }
		want == "queue"  && first ~ /^ *(JOBID |queue is empty|job list unavailable|no readable rows|⚠ queue output)/ { print; exit }
		want == "recent" && first ~ /^ *(recently finished|finished jobs unavailable)/ { print; exit }
		want == "footer" && first ~ /^ *[0-9]+ jobs / { print; exit }'
}
rows() {      # rows queue|recent: the data rows of a table, header and notes left out
	section "$1" | LC_ALL=$utf8 gawk 'NR == 1 && /^ *JOBID /       { next }
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
	need "pending reason shown"       eval 'rows queue | grep -E "^ +1103 .*PENDING .*\(Resources\)$" -q'
	need "finished row 1001 COMPLETED" eval 'rows recent | grep -qE "^ +1001 +done +COMPLETED "'
	need "finished block has 1 row (steps folded)" eval '[ "$(nrows recent)" -eq 1 ]'
	need "no unreadable/incomplete note" no_skips
	need "queue call: squeue -h -S t,i" argv_has squeue -h -S t,i
	need "queue call has SLURM_TIME_FORMAT=standard" eval '[ "$(env_of squeue 1 SLURM_TIME_FORMAT)" = standard ]'
	need "queue format framed by SQ_NONCE, ends in hidden %t %l %S" eval '
		f=$(env_of squeue 1 SQUEUE_FORMAT); n=$(env_of squeue 1 SQ_NONCE)
		[ "$f" = "%i$n%i$n%j$n%u$n%T$n%M$n%L$n%C$n%m$n%R$n%t$n%l$n%S$n" ]'
	need "sacct: -p --delimiter=SQ_NONCE2 -n -S now-2hours -E now -a -o <8 fields>" eval '
		argv_has sacct -p "--delimiter=$(env_of sacct 1 SQ_NONCE2)" -n -S now-2hours -E now -a -o JobID,User,State,ExitCode,Elapsed,End,NodeList,JobName'
	need "sacct's delimiter is not the queue nonce" eval '[ "$(env_of sacct 1 SQ_NONCE2)" != "$(env_of sacct 1 SQ_NONCE)" ]'
	need "sinfo: -hN -o framed by SQ_NONCE3" eval '
		n=$(env_of sinfo 1 SQ_NONCE3); argv_has sinfo -hN -o "%C$n%N$n%e$n%m$n%T$n%E$n%H$n"'
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

# ---- 5. hostile job names ----------------------------------------------------
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

# ---- 6. squeue failing, hanging, or answering garbage -------------------------
c_squeue_fails() {
	T_TITLE="squeue rc 1: unreachable banner with its stderr, 'job list unavailable', rc 0"
	sq_run squeue-fails --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: queue once, no fallback, sacct still asked" calls_are 1 1 0 1
	need "banner carries squeue's first stderr line" matches "^  ⚠ slurm unreachable · squeue: error: Unable to contact"
	need "'job list unavailable'"     has "job list unavailable"
	need "finished block still from sacct" eval 'rows recent | grep -qE "^ +1001 +done +COMPLETED "'
	need "footer as today: 0/0/0/0"   footer_is 0 0 0 0
}
c_squeue_hangs() {
	T_TITLE="squeue hangs: cut at SQ_TIMEOUT=1, banner 'no response after 1s', rc 0"
	local t0=$SECONDS
	sq_run squeue-hangs SQ_TIMEOUT=1 --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: queue once, no fallback" calls_are 1 1 0 1
	need "finished within 10s"        eval '[ $((SECONDS - t0)) -lt 10 ]'
	need "banner 'no response after 1s'" matches "^  ⚠ slurm unreachable · no response after 1s$"
	need "'job list unavailable'"     has "job list unavailable"
	need "footer as today: 0/0/0/0"   footer_is 0 0 0 0
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

# ---- 7. the finished block from sacct ----------------------------------------
c_finished() {
	T_TITLE="sacct: COMPLETED and FAILED tasks of one array fold apart; a timeout shows its signal"
	sq_run finished --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "'5000_[0-3] ×4' COMPLETED"  eval 'row_cell recent "5000_[0-3] ×4" && rows recent | grep -qE "^ +5000_\[0-3\] ×4 +sweep +COMPLETED "'
	need "'5000_[4-5] ×2' FAILED exit 1" eval 'row_cell recent "5000_[4-5] ×2" && rows recent | grep -qE "^ +5000_\[4-5\] ×2 +sweep +FAILED +1 "'
	need "5100 TIMEOUT shows 0/sig15 from its step" eval 'rows recent | grep -qE "^ +5100 +longrun +TIMEOUT +0/sig15 "'
	need "3 finished rows, no step row" eval '[ "$(nrows recent)" -eq 3 ] && ! rows recent | grep -q "batch"'
	need "caption from sacct"         eval 'section recent | head -1 | grep -qE "^ +recently finished · last 2h$"'
	need "no unreadable note"         no_skips
}

# ---- 8. sacct fails: the squeue -t all fallback -----------------------------
c_sacct_fallback() {
	T_TITLE="sacct rc 1: finished block falls back to squeue -t all, caption says so"
	sq_run sacct-fails --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: sacct, then the fallback" calls_are 1 1 1 1
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

# ---- 10. colour -------------------------------------------------------------
c_colour() {
	T_TITLE="colour: plain pipe 0 escapes, COLUMNS+LINES >0, NO_COLOR=1 0"
	sq_run mixed --
	need "plain pipe: rc 0"           rc_is 0
	need "plain pipe: no ESC"         eval '[ "$(escapes)" -eq 0 ]'
	sq_run mixed COLUMNS=120 LINES=50 --
	need "COLUMNS+LINES: rc 0"        rc_is 0
	need "COLUMNS+LINES: escapes"     eval '[ "$(escapes)" -gt 0 ]'
	need "COLUMNS+LINES: all SGR"     escapes_all_sgr
	need "COLUMNS+LINES: same footer once uncoloured" footer_is 6 3 2 1
	sq_run mixed COLUMNS=120 LINES=50 NO_COLOR=1 --
	need "NO_COLOR: rc 0"             rc_is 0
	need "NO_COLOR: no ESC"           eval '[ "$(escapes)" -eq 0 ]'
}

# ---- 11. known defects --------------------------------------------------------
c_xf_pending_range() {
	T_TITLE=; xfail "a pending _[1-20] row counts 1 job, not 20, and has no ×20"
	sq_run pending-range --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	want "cell '7000_[1-20] ×20'"     row_cell queue "7000_[1-20] ×20"
	want "footer 20/0/20/0"           footer_is 20 0 20 0
	today "footer 1/0/1/0"            footer_is 1 0 1 0
	today "cell '7000_[1-20]' alone"  row_cell queue "7000_[1-20]"
}
c_xf_pending_strided() {
	T_TITLE=; xfail "a pending strided _[0-12:2] row is dropped as unreadable (and once shown, still counted 1)"
	sq_run pending-strided --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	want "cell '7001_[0-12:2] ×7'"    row_cell queue "7001_[0-12:2] ×7"
	want "footer 7/0/7/0"             footer_is 7 0 7 0
	want "no unreadable note"         no_skips
	# the defect has two known stages: dropped (today), then shown but counted 1
	# (once the id anchor accepts it), so either one is still this XFAIL
	today "dropped as unreadable, or shown but counted 1" eval '
		{ has "↳ 1 unreadable queue row skipped" && footer_is 0 0 0 0; } ||
		{ row_cell queue "7001_[0-12:2]" && footer_is 1 0 1 0; }'
}
c_xf_pending_long() {
	T_TITLE=; xfail "a pending id over 31 characters is cut by squeue (no SLURM_BITSTR_LEN=0) and dropped (and once shown, counted 1)"
	sq_run pending-long --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	want "cell '11137_[1,3,5,7,9,11,13,15,17,20] ×10'" row_cell queue "11137_[1,3,5,7,9,11,13,15,17,20] ×10"
	want "footer 10/0/10/0"           footer_is 10 0 10 0
	want "no unreadable note"         no_skips
	# two known stages: dropped (today), then shown whole but counted 1 (once
	# SLURM_BITSTR_LEN=0 is set), so either one is still this XFAIL
	today "dropped as unreadable, or shown but counted 1" eval '
		{ has "↳ 1 unreadable queue row skipped" && footer_is 0 0 0 0; } ||
		{ row_cell queue "11137_[1,3,5,7,9,11,13,15,17,20]" && footer_is 1 0 1 0; }'
}
c_xf_finished_throttled() {
	T_TITLE=; xfail "a finished _[0-9%3] row from sacct counts 1, shows no ×10"
	sq_run finished-throttled --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	want "cell '7002_[0-9%3] ×10'"    row_cell recent "7002_[0-9%3] ×10"
	today "cell '7002_[0-9%3]' alone" row_cell recent "7002_[0-9%3]"
}
c_xf_fallback_throttled() {
	T_TITLE=; xfail "a finished throttled array via the squeue fallback counts 1, shows the bare id"
	sq_run fallback-throttled --
	need "rc 0"                       rc_is 0
	need "stubs: sacct failed, fallback used" calls_are 1 1 1 1
	want "cell '7002_[0-9%3] ×10'"    row_cell recent "7002_[0-9%3] ×10"
	today "cell '7002' alone"         row_cell recent "7002"
}
c_xf_bitstr() {
	T_TITLE=; xfail "squeue and sacct are called without SLURM_BITSTR_LEN=0"
	sq_run sacct-fails --
	need "rc 0"                       rc_is 0
	need "stubs: queue, sacct and fallback all called" calls_are 1 1 1 1
	want "every squeue and sacct call has SLURM_BITSTR_LEN=0" all_calls_env SLURM_BITSTR_LEN 0 squeue sacct
	today "no squeue or sacct call has it" no_call_env SLURM_BITSTR_LEN squeue sacct
}

# ---- 12. on a terminal --------------------------------------------------------
# The "wide" fixture's job name is wider than any terminal, so the queue table is
# shrunk to exactly the width sq believes in and its header line spans it: the
# widest line is the layout width.  37x123 is a size nothing defaults to.
pty_case() {   # pty_case TERM: sq on a 37x123 pty with that TERM, no size in the env
	PTY=1 PTY_ROWS=37 PTY_COLS=123 sq_run wide TERM="$1" -SQ_WIDTH -SQ_HEIGHT --
	need "rc 0"                       rc_is 0
	need "stubs called"               calls_are 1 1 0 1
	need "the job row is there"       row_cell queue 8001
	need "the shrunk NAME column keeps USER aligned" column_aligned USER
	need "coloured, as on a terminal" eval '[ "$(escapes)" -gt 0 ]'
}
c_pty_xterm() {
	T_TITLE="TERM=xterm-256color on a 123-column pty: laid out at 123 columns"
	pty_case xterm-256color
	need "widest line is 123"         eval '[ "$(width)" -eq 123 ]'
}
c_xf_pty_kitty() {
	T_TITLE=; xfail "TERM=xterm-kitty (unknown to terminfo here): tput fails and sq assumes 100 columns; should be 123 via stty size"
	pty_case xterm-kitty
	need "xterm-kitty really is unknown to terminfo here" eval '! TERM=xterm-kitty tput cols >/dev/null 2>&1'
	want "widest line is 123"         eval '[ "$(width)" -eq 123 ]'
	today "widest line is 100"        eval '[ "$(width)" -eq 100 ]'
}

# ============================================================================
cases=(
	empty mixed array_fold drain_reason hostile_names
	squeue_fails squeue_hangs squeue_garbage finished sacct_fallback
	refuse_t_empty refuse_states_eq accept_S_empty refuse_s refuse_json refuse_O
	colour
	xf_pending_range xf_pending_strided xf_pending_long
	xf_finished_throttled xf_fallback_throttled xf_bitstr
	pty_xterm xf_pty_kitty
)
start=$(date +%s%N)
for c in "${cases[@]}"; do
	if [ ${#only[@]} -gt 0 ]; then
		hit=0; for o in "${only[@]}"; do [[ $c == *"$o"* ]] && hit=1; done
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
