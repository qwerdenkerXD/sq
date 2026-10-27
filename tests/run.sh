#!/usr/bin/env bash
# sq's regression suite: sq against stubbed Slurm clients, asserting properties
# of its output (counts, rows, captions, escapes, widths, exit codes), never a
# snapshot of it.
#
#   tests/run.sh [-k|--keep] [--pin] [-j N] [NAME...]   NAME: run only the case of that name
#
# -j N runs N cases at once (default 1, one after the other), each case whole
# and its lines printed in the order of the cases as always; the cases that
# measure time or load (timed_cases) run one after the other after the rest.
#
# --pin writes what sq prints into the pinned screens of sq job and its why
# section (tests/fixtures/sqjob/screens) instead of comparing with them, for
# a change that is meant to change them; git diff then shows what changed.
#
# A failed case's run directories stay without -k too, as a flake may not
# come back for a rerun: under ${TMPDIR:-/tmp}/sq-failed/<UTC start>.<pid>/,
# one directory per run, made at its first FAIL; the newest SQ_KEEP_FAILED
# (5) runs' stay, older ones go as a run starts and as one makes its own.
#
# Needs bash, gawk, coreutils (8.31 or later: env --default-signal), util-linux
# `script` and `setsid` for the terminal cases, and glibc's localedef with its
# locale sources for one case;
# util-linux `flock` (the stub's call counter, the failed cases' evidence) and
# procps `ps` (sq log's leftover processes, found by session id) for the sq
# log cases.
# The stubs in tests/bin stand in for squeue/sinfo/sacct/sstat/scontrol
# (tests/lib/stub.sh says how, tests/FAITHFULNESS.md how they were checked
# against the real ones) and for getent; tests/bin/stty only logs and runs the
# real stty, tests/bin/id and hostname answer what a case sets.
# Every case must see a stub answer, so the suite cannot pass against a real
# Slurm by accident.
#
# Results: PASS, FAIL, XFAIL (a known defect, still there, in the documented
# way) and XPASS (a known defect no longer reproduces: remove its xfail marker).
# The run fails on any FAIL or XPASS.
#
# Known gaps, left out on purpose because they are cosmetic: right alignment
# of numeric columns, the truncation of a long drain reason.  The bar glyphs
# are checked only on the node screens of the bars_* and membar_* cases.

set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sq=${SQ_UNDER_TEST:-${here%/*}/sq}    # SQ_UNDER_TEST: another build of sq, e.g. an installed one
fixtures=$here/fixtures
keep=0; pin=0; jobs=1; only=()
while [ $# -gt 0 ]; do
	case $1 in
		-k|--keep) keep=1 ;;
		--pin) pin=1 ;;
		-j) jobs=${2-}; [ $# -lt 2 ] || shift ;;
		-j*) jobs=${1#-j} ;;
		-h|--help) sed -n '2,/^# Results:/{/^# Results:/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
		-*) printf 'run.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
		*) only+=("$1") ;;
	esac
	shift
done
case $jobs in
	''|*[!0-9]*) printf "run.sh: -j takes how many cases run at once, not '%s'\n" "$jobs" >&2; exit 2 ;;
esac
jobs=$((10#$jobs)); [ "$jobs" -ge 1 ] || { echo "run.sh: -j takes 1 or more" >&2; exit 2; }

# sq measures widths with gawk's length(), which counts characters only in a
# UTF-8 locale; pick one that exists, rather than inherit whatever the caller has
utf8=
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
	LC_ALL=$l gawk 'BEGIN { exit length("…") != 1 }' 2>/dev/null && { utf8=$l; break; }
done
[ -n "$utf8" ] || { echo "run.sh: no UTF-8 locale available (tried C.UTF-8, en_US.UTF-8)" >&2; exit 2; }

# TMPDIR is honoured; with -k the evidence stays there, under a recognisable
# name, and a failed case's stays without -k too (failrun_make, verdict)
keep_failed=${SQ_KEEP_FAILED:-5}
case $keep_failed in
	*[!0-9]*|'') printf "run.sh: SQ_KEEP_FAILED is a number of runs, not '%s'\n" "$keep_failed" >&2; exit 2 ;;
esac
keep_failed=$((10#$keep_failed))   # base 10: 08 and 09 are numbers too, 010 is ten
failroot=${TMPDIR:-/tmp}/sq-failed failrun= failstamp=$(date -u +%Y%m%dT%H%M%SZ)
# prune_failed N: every run's evidence but the newest N goes, by the time it
# was last written, unless a running suite holds its lock (flock -n); the
# sq-failed-NAME.* directories of the suite before count as runs too
prune_failed() {
	local d n=0
	{ find "$failroot" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*Z.[0-9]*' -printf '%T@ %p\n'
	  find "${TMPDIR:-/tmp}" -mindepth 1 -maxdepth 1 -type d -name 'sq-failed-*.??????' -printf '%T@ %p\n'
	} 2>/dev/null | sort -rn | while read -r _ d; do
		n=$((n + 1)); [ "$n" -le "$1" ] || flock -n "$d/.lock" rm -rf "$d" 2>/dev/null
	done
}
# failrun_make: this run's evidence directory, made at its first FAIL with
# room for it among the newest SQ_KEEP_FAILED, and locked while the run
# lasts; made under a dot name and renamed once locked, so no pruning run
# takes it in between
failrun_make() {
	[ -z "$failrun" ] || return 0
	local new=$failroot/.new.$$
	prune_failed $((keep_failed - 1))
	mkdir -p "$failroot" && rm -rf "$new" && mkdir "$new" &&
		exec {faillock}> "$new/.lock" && flock -n "$faillock" &&
		mv "$new" "$failroot/$failstamp.$$" && failrun=$failroot/$failstamp.$$
}
prune_failed "$keep_failed"
work=$(mktemp -d "${TMPDIR:-/tmp}/sq-tests.XXXXXX") || exit 2
[ $keep = 0 ] || echo "evidence kept in $work"
# every session a background sq ran in (sq_start) is emptied on the way out
# too, those of the cases -j runs at once as well (each its own process
# group, in case_pgids, their sessions listed in $work/sids)
all_sids= case_pgids= stopped_by= selected=()
n_pass=0 n_fail=0 n_xfail=0 n_xpass=0
suite_exit() {
	local sid pgid finished shown
	# a run stopped by a signal says so in one line, with how far it got: the
	# cases finished, and under -j how many of them were shown (in case order)
	if [ -n "$stopped_by" ]; then
		finished=$((n_pass + n_fail + n_xfail + n_xpass)) shown=
		if [ -d "${results-}" ]; then
			shown=", $finished shown"; finished=$(find "$results" -name '*.status' | wc -l)
		fi
		printf '\nrun.sh: interrupted by %s, %d of %d cases done%s\n' "$stopped_by" "$finished" ${#selected[@]} "$shown" >&2
	fi
	# the cases -j runs, and a case's own background work in a serial run
	# (bars_width_sweep's series), with every process under them, by pid; all
	# reaped here, so none still writes into the work dir as it goes, and
	# bash's "Killed" notice of each goes nowhere (wait passes over a case
	# stopped as it died, so bash may tell of it a command later)
	{	local tree=; for pgid in $case_pgids $(jobs -p); do tree="$tree $(proc_freeze "$pgid")"; done
		for pgid in $case_pgids; do kill -KILL -- "-$pgid"; done
		[ -z "${tree// }" ] || kill -KILL $tree
		wait
		for sid in $all_sids $(cat "$work/sids"); do session_kill "$sid"; done
		[ $keep = 1 ] || rm -rf "$work"
	} 2>/dev/null
}
# proc_freeze PID: PID and every process under it, each stopped before its
# children are listed, so none forks one that escapes (timeout puts sq in a
# process group of its own); their pids
proc_freeze() {
	local child
	kill -STOP "$1" 2>/dev/null; echo "$1"
	for child in $(ps -o pid= --ppid "$1" 2>/dev/null); do proc_freeze "$child"; done
}
trap suite_exit EXIT
# a killed run still runs the EXIT trap, so its work dir goes too
trap 'stopped_by=SIGHUP; exit 129' HUP; trap 'stopped_by=SIGINT; exit 130' INT; trap 'stopped_by=SIGTERM; exit 143' TERM

ESC=$'\033'
# the suite's own bound on sq, found before any case puts a fake timeout first
# on PATH (tests/lib/timeout-as)
bound=$(command -v timeout) || { echo "run.sh: no timeout on PATH" >&2; exit 2; }

# ============================================================================
# running sq
# ============================================================================
# sq_run FIXTURE [VAR=value | -VAR]... -- [sq args...]
# Runs sq in a clean environment: the stubs first on PATH, a fresh HOME (the
# bell's state file lives under it), a small timeout and a fixed size, and
# `id -u` saying 4242 (tests/bin/id), a uid no record has unless a fixture
# makes it the caller's own; VAR=value
# adds or overrides a variable, -VAR removes one.  --no-bell is passed unless
# BELL=1, which only rings with a terminal (PTY=1, below).
# NOTTY=1 runs sq in a new session (setsid), so it has no controlling terminal.
# BOUND=SECONDS raises the 30 s sq may take (sq log follows a job for a while).
# Leaves OUT, ERR, LOG (the stub log) and RC for the assertions below.
sq_run() {
	sq_env "$@"
	if [ -n "${PTY:-}" ]; then pty_exec "${ENVLIST[@]}" -- "${SQ_ARGV[@]}"
	else  # bounded, so a hanging sq fails its case instead of hanging the suite;
		# setsid outside timeout, so a hanging sq stays timeout's own child
		env -i "${ENVLIST[@]}" ${NOTTY:+setsid -w} "$bound" -k 2 "${BOUND:-30}" "$sq" "${SQ_ARGV[@]}" > "$OUT" 2> "$ERR" < /dev/null; RC=$?
		[ $RC -ne 124 ] || T_FAIL+=("sq did not finish within ${BOUND:-30}s")
	fi
	note_run
}
# sq_env FIXTURE [VAR=value | -VAR]... -- [sq args...]: a fresh run (RUN, OUT,
# ERR, LOG), its environment in ENVLIST and sq's arguments in SQ_ARGV
sq_env() {
	local fixture=$1; shift
	run_n=$((run_n+1))
	RUN=$T_DIR/run$run_n; mkdir -p "$RUN/home"
	OUT=$RUN/out ERR=$RUN/err LOG=$RUN/log; : > "$LOG"
	# TZ=UTC: a fixture's \{now-2h} is printed in local time and sq reads it back
	# with mktime, which cannot tell the two passes of a repeated DST hour apart.
	# HOME is the run's own unless the case sets or removes it
	local -A env=([PATH]="$here/bin:$PATH" [LC_ALL]=$utf8 [TZ]=UTC
	              [SQSTUB_FIXTURE]=$([[ $fixture == /* ]] && echo "$fixture" || echo "$fixtures/$fixture")
	              [SQ_TIMEOUT]=3 [SQ_WIDTH]=120 [SQ_HEIGHT]=50 [SQSTUB_UID]=4242 [HOME]=$RUN/home)
	while [ $# -gt 0 ] && [ "$1" != -- ]; do
		case $1 in -*) unset "env[${1#-}]" ;; *=*) env[${1%%=*}]=${1#*=} ;; esac
		shift
	done
	[ $# -gt 0 ] && shift
	env[SQSTUB_LOG]=$LOG
	ENVLIST=(); local k
	# sq's own mktemp -d lands under the run, so a sq killed before its EXIT trap
	# (the 30s bound below) leaves nothing behind once $work is removed
	mkdir -p "$RUN/tmp"; [ -n "${env[TMPDIR]+set}" ] || env[TMPDIR]=$RUN/tmp
	for k in "${!env[@]}"; do ENVLIST+=("$k=${env[$k]}"); done
	SQ_ARGV=("$@")
	[ -n "${BELL:-}" ] || SQ_ARGV=(--no-bell "${SQ_ARGV[@]}")
}

# ---- sq in the background: signals, a gone reader, leftover processes ------
# sq_start FIXTURE [VAR=value | -VAR]... -- [sq args...]: sq_run's run, but in
# the background, in a session of its own whose id is sq's pid, SQ_PID; RUN
# names the run for sq_finish.  Its stdout goes to OUT, or with SQOUT=head3
# through `| head -n 3` into OUT, or with SQOUT=full into /dev/full.  The
# session is how its processes are found again: `ps -s`, never by pattern.
sq_start() {
	sq_env "$@"
	: > "$RUN/pid"
	# sh writes its pid and execs setsid, which (sh leading no process group)
	# makes it a session leader and execs sq: one pid all along.  env first
	# resets SIGINT, SIGQUIT and SIGHUP to their default: a run.sh started with
	# & from a non-interactive shell has INT and QUIT ignored, one started
	# under nohup HUP; sq inherits that and cannot trap a signal ignored on entry
	local launch='printf "%s\n" "$$" > "$0"; exec env --default-signal=INT,QUIT,HUP setsid "$@"'
	local -a cmd=(sh -c "$launch" "$RUN/pid" env -i "${ENVLIST[@]}" "$sq" "${SQ_ARGV[@]}")
	# (bash's own "Killed" notice for a sq a case killed goes nowhere), and
	# what still ran in its session the moment sq returned goes to left-at-exit
	case ${SQOUT:-file} in
		file)  { "${cmd[@]}" > "$OUT" 2> "$ERR" < /dev/null; at_exit $?; } 2>/dev/null & ;;
		head3) { "${cmd[@]}" 2> "$ERR" < /dev/null; at_exit $?; } 2>/dev/null | head -n 3 > "$OUT" & ;;
		full)  : > "$OUT"; { "${cmd[@]}" > /dev/full 2> "$ERR" < /dev/null; at_exit $?; } 2>/dev/null & ;;
	esac
	echo $! > "$RUN/job"
	waits_for 5 eval '[ -s "$RUN/pid" ]' || T_FAIL+=("sq did not start")
	SQ_PID=$(cat "$RUN/pid"); T_SIDS="$T_SIDS $SQ_PID" all_sids="$all_sids $SQ_PID"
	echo "$SQ_PID" >> "$work/sids"
}
at_exit() { leftovers "$(cat "$RUN/pid")" > "$RUN/left-at-exit"; echo "$1" > "$RUN/rc"; }
nothing_at_exit() { [ ! -s "$RUN/left-at-exit" ]; }   # sq waited for all it started
use_run() {   # use_run RUN: make that run the current one (OUT, ERR, LOG, SQ_PID)
	RUN=$1; OUT=$RUN/out ERR=$RUN/err LOG=$RUN/log; SQ_PID=$(cat "$RUN/pid")
}
# sq_finish RUN [SECONDS]: wait for that run's sq, 60 s at most, then its RC
sq_finish() {
	use_run "$1"
	if ! waits_for "${2:-60}" eval '[ -s "$RUN/rc" ]'; then
		T_FAIL+=("sq did not finish within ${2:-60}s"); session_kill "$SQ_PID"
	fi
	wait "$(cat "$RUN/job")" 2>/dev/null
	RC=$(cat "$RUN/rc" 2>/dev/null); RC=${RC:-124}
	note_run
}
# waits_for SECONDS CMD...: until CMD holds, polling every 0.1 s; counted, not
# timed, as WSL steps its clock back now and then
waits_for() {   # (SECONDS may have one decimal: 2.5)
	local n=0 limit
	case $1 in *.?) limit=$((10#${1/./})) ;; *) limit=$(( $1 * 10 )) ;; esac; shift
	until "$@"; do
		[ $n -lt $limit ] || return 1
		sleep 0.1; n=$((n + 1))
	done
}
leftovers() { ps -s "$1" -o pid=,args= 2>/dev/null; }    # leftovers SID: what still runs in it
nothing_left() { [ -z "$(leftovers "$SQ_PID")" ]; }       # in the current run's session
session_kill() {   # session_kill SID: every process still in it, by pid
	local pid
	for pid in $(ps -s "$1" -o pid= 2>/dev/null); do kill -KILL "$pid" 2>/dev/null; done
}
stub_calls() { grep -c '^CALL' "$LOG"; }                   # how often a stub was asked

# The pty variant: sq on a pseudo-terminal of PTY_ROWS x PTY_COLS made by
# util-linux script, so [ -t 1 ] and tput see a terminal.  stdout of script is
# the terminal's output, so OUT gets CRs and colour; plain() takes them out.
# PTY_STDIN=FILE gives sq that stdin instead of the terminal, PTY_VMEM_KB=N
# caps its virtual memory (ulimit -v), for a run that may grow without end.
pty_exec() {
	local -a envlist=()
	while [ "$1" != -- ]; do envlist+=("$1"); shift; done; shift
	if ! command -v script > /dev/null; then
		T_FAIL+=("util-linux script is not installed (needed for the pty cases)"); RC=127; : > "$OUT"; return
	fi
	local inner
	inner="${PTY_VMEM_KB:+ulimit -v $PTY_VMEM_KB; }stty rows $PTY_ROWS cols $PTY_COLS; exec $(printf '%q ' "$sq" "$@")"
	[ -n "${PTY_STDIN:-}" ] && inner="$inner < $(printf '%q' "$PTY_STDIN")"
	# --foreground: without it timeout stops script's child with SIGTTOU in the pty
	env -i "${envlist[@]}" SHELL=/bin/sh \
		"$bound" --foreground -k 2 20 script -qec "$inner" /dev/null > "$OUT" 2> "$ERR" < /dev/null
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
# The column oracle, independent of sq's width table: each distinct character
# beyond ASCII is measured by `wc -L` on its own under a UTF-8 locale (glibc's
# wcwidth), once for the whole suite (in $work/oracle.map), and these
# deviations of sq's rule from glibc are stated here: U+FE0F counts 1 (glibc
# 0), a regional indicator 2 (glibc 1), the nine emoji tmux draws wide (☝ ⛹ ✌
# ✍ and U+1F3CB, 1F3CC, 1F574, 1F575, 1F590; glibc 1) 2, and the -1 characters
# the fixtures hold, U+2028 and U+2029, 1 (wc -L 0).  A fixture holds no
# character whose glibc width changed between versions.
# cplain: the screen as plain() prints it, cellified: a 2-column character
# followed by a U+E000 filler, a 0-column one dropped, so a helper counting
# characters counts columns.  oracle_width TEXT: TEXT's columns by it.
# oracle_fill FILE first measures what the map lacks (a gawk running wc -L
# itself would ignore SIGPIPE, and a reader that stops early made it fail)
oracle_awk='
BEGIN {
	map = ENVIRON["ORACLE_MAP"]
	while ((getline ln < map) > 0) { t = index(ln, "\t"); OW[substr(ln, 1, t - 1)] = substr(ln, t + 1) + 0 }
	close(map)
	OW["\357\270\217"] = 1                                   # U+FE0F
	OW["\342\200\250"] = OW["\342\200\251"] = 1             # U+2028, U+2029
	n = split("\342\230\235 \342\233\271 \342\234\214 \342\234\215 \360\237\217\213 \360\237\217\214 \360\237\225\264 \360\237\225\265 \360\237\226\220", E, " ")
	for (i = 1; i <= n; i++) OW[E[i]] = 2
	n = split("\246 \247 \250 \251 \252 \253 \254 \255 \256 \257 \260 \261 \262 \263 \264 \265 \266 \267 \270 \271 \272 \273 \274 \275 \276 \277", E, " ")
	for (i = 1; i <= n; i++) OW["\360\237\207" E[i]] = 2     # the regional indicators
	FILL = "\356\200\200"                                   # U+E000
}
function cellify(s,   n, C, i, out, w) {
	n = split(s, C, ""); out = ""
	for (i = 1; i <= n; i++) {
		if (C[i] ~ /^[\001-\177]$/) { out = out C[i]; continue }
		if (!(C[i] in OW)) { print "oracle: no width for " C[i] > "/dev/stderr"; exit 2 }
		w = OW[C[i]]; out = out (w == 0 ? "" : w == 1 ? C[i] : C[i] FILL)
	}
	return out
}'
oracle_fill() {   # oracle_fill FILE: each character of FILE beyond ASCII the map lacks, by wc -L
	local c
	ORACLE_MAP=$work/oracle.map LC_ALL=$utf8 gawk "$oracle_awk"' { n = split($0, C, "")
		for (i = 1; i <= n; i++) if (C[i] !~ /^[\001-\177]$/ && !(C[i] in OW) && !(C[i] in seen)) { seen[C[i]]; print C[i] } }' "$1" |
	while IFS= read -r c; do
		printf '%s\t%s\n' "$c" "$(printf '%s' "$c" | LC_ALL=$utf8 wc -L)" >> "$work/oracle.map"
	done
}
cplain() {
	oracle_fill "$OUT"
	ORACLE_MAP=$work/oracle.map LC_ALL=$utf8 gawk "$oracle_awk"' { gsub(/\033\[[0-9;]*m/, ""); gsub(/\r/, ""); print cellify($0) }' "$OUT"
}
oracle_width() {
	printf '%s\n' "$1" > "$T_DIR/oracle.text"; oracle_fill "$T_DIR/oracle.text"
	ORACLE_MAP=$work/oracle.map T=$1 LC_ALL=$utf8 gawk "$oracle_awk"' BEGIN { print length(cellify(ENVIRON["T"])) }'
}
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
width() { cplain | LC_ALL=$utf8 gawk '{ if (length($0) > m) m = length($0) } END { print m+0 }'; }   # in columns

# the blocks of sq's screen, found by what they start with
section() {   # section queue|recent|footer: that block's lines (SRC=cplain: cellified)
	${SRC:-plain} | LC_ALL=$utf8 gawk -v want="$1" '
		BEGIN { RS = ""; HDR = "^ *[A-Z][A-Z/_()]*( +[A-Z][A-Z/_()]*)* *$" }   # a table header
		{ split($0, L, "\n"); first = L[1] }
		want == "queue"  && first ~ /^ *(queue is empty|job list unavailable|no readable rows|⚠ queue output)/ { print; exit }
		want == "queue"  && first ~ HDR { print; exit }
		want == "recent" && first ~ /^ *(recently finished|finished jobs unavailable)/ { print; exit }
		want == "footer" && first ~ /^ *([0-9]+|\?) jobs? / { print; exit }'
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
column_aligned() {   # column_aligned HEADER, e.g. USER (in columns)
	SRC=cplain section queue | H=$1 LC_ALL=$utf8 gawk 'NR == 1 { p = index($0 " ", " " ENVIRON["H"] " ") + 1; if (p < 2) exit 1; next }
		{ n++; if (substr($0, p-1, 1) != " " || substr($0, p, 1) == " " || substr($0, p, 1) == "") bad++ }
		END { exit !(p >= 2 && n > 0 && !bad) }'
}
footer_is() { # footer_is JOBS RUNNING PENDING OTHER
	section footer | grep -qE "^ *$1 $(jobs_noun "$1") +$2 running +$3 pending +$4 other\$"
}
jobs_noun() { [ "$1" = 1 ] && echo job || echo jobs; }   # jobs_noun N: the footer's noun for N jobs
# the counts sq does not know: "?" for each, on the last line, the one footer
footer_sgr() { tail -n 1 "$OUT" | LC_ALL=C grep -o "$ESC\[[0-9;]*m" | tr -d "$ESC" | paste -sd' '; }   # the footer's SGRs, ESC left out
footer_unknown() { [ "$(section footer | wc -l)" -eq 1 ] && plain | tail -n 1 | grep -qE '^ *\? jobs +\? running +\? pending +\? other$'; }
no_skips()   { lacks unreadable && lacks incomplete; }
rc_is()      { [ "$RC" -eq "$1" ]; }
# how often sq asked the terminal its size (tests/bin/stty logs every call)
stty_size_calls() { gawk -F'\t' '$1 == "STTY" && $2 == "size" { n++ } END { print n+0 }' "$LOG"; }
err_empty()  { [ ! -s "$ERR" ]; }
# for a need's text: " (the first 200 bytes of stderr)" where there is any
err_quoted() { [ ! -s "$ERR" ] || printf ' (%s)' "$(head -c 200 "$ERR" | tr '\n' ' ')"; }
out_empty()  { [ ! -s "$OUT" ]; }

# ---- the stub log: one CALL line per invocation, see tests/lib/stub.sh ------
calls() {     # calls sinfo|squeue|sacct|sstat|queue|fallback|alloc|mirror: how many
	case $1 in
		queue)    gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && (" " $3) !~ / -t all / && $0 !~ /tres-alloc/ { n++ } END { print n+0 }' "$LOG" ;;
		# JOBMEM's allocation call asks StateCompact too, MEMALLOC's mirror call not
		alloc)    gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && $0 ~ /tres-alloc/ && $0 ~ /StateCompact/ { n++ } END { print n+0 }' "$LOG" ;;
		mirror)   gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && $0 ~ /tres-alloc/ && $0 !~ /StateCompact/ { n++ } END { print n+0 }' "$LOG" ;;
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

# verdict: the case's status into T_STATUS, and its line
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
	T_STATUS=$status
	printf '%-5s  %-24s %s\n' "$status" "$T_NAME" "${reason//$'\x1f'/; }"
}
# tally: case T_NAME's T_STATUS counted; a failed case keeps its run
# directories (T_DIR) even without -k, as a flake may not come back for a
# rerun: moved out of the work dir the suite removes
tally() {
	case $T_STATUS in
		PASS) n_pass=$((n_pass+1)) ;; FAIL) n_fail=$((n_fail+1)) ;;
		XFAIL) n_xfail=$((n_xfail+1)) ;; XPASS) n_xpass=$((n_xpass+1)) ;;
	esac
	if { [ $T_STATUS = FAIL ] || [ $T_STATUS = XPASS ]; } && [ $keep = 0 ]; then
		if [ "$keep_failed" = 0 ]; then printf '       evidence: not kept (SQ_KEEP_FAILED=0), rerun with -k\n'
		elif failrun_make && mv "$T_DIR" "$failrun/"; then printf '       evidence kept in %s\n' "$failrun/$T_NAME"
		else printf '       evidence: rerun with -k\n'
		fi
	fi
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
	# 1103's start estimate is 400 days ahead: its date, taken either side of
	# the run in case the run straddles midnight
	local est0 est1
	est0=$(date -u -d '+400 days' +%F); sq_run mixed --; est1=$(date -u -d '+400 days' +%F)
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: sinfo, queue, sacct once each" calls_are 1 1 0 1
	need "footer 6/3/2/1"             footer_is 6 3 2 1
	need "6 queue rows"               eval '[ "$(nrows queue)" -eq 6 ]'
	need "rows are 1101..1106"        eval '[ "$(row_first_fields queue | sort | paste -sd,)" = 1101,1102,1103,1104,1105,1106 ]'
	need "USER and NODE/REASON columns line up" eval 'column_aligned USER && column_aligned NODE/REASON'
	need "pending reason with its backfill estimate, over a year ahead: a date" eval 'rows queue | grep -qE "^ +1103 .*PENDING .*\(Resources\) → ($est0|$est1)$"'
	need "no estimate where squeue has none" eval 'rows queue | grep -qE "^ +1102 .*PENDING .*\(Priority\)$"'
	need "finished row 1001 COMPLETED" eval 'rows recent | grep -qE "^ +1001 +done +COMPLETED "'
	need "finished block has 1 row (steps folded)" eval '[ "$(nrows recent)" -eq 1 ]'
	need "no unreadable/incomplete note" no_skips
	need "queue call: squeue -h -S t,i" argv_has squeue -h -S t,i
	need "every call has SLURM_TIME_FORMAT=standard" all_calls_env SLURM_TIME_FORMAT standard sinfo squeue sacct
	need "queue format framed by SQ_NONCE, ends in hidden %t %l %S, and %A %U as MEM is shown" eval '
		f=$(env_of squeue 1 SQUEUE_FORMAT); n=$(env_of squeue 1 SQ_NONCE)
		[ "$f" = "%i$n%i$n%j$n%u$n%T$n%M$n%L$n%C$n%m$n%R$n%t$n%l$n%S$n%A$n%U$n" ]'
	need "sacct: -p --delimiter=SQ_NONCE2 -n -S now-2hours -E now -a -o <8 fields>" eval '
		argv_has sacct -p "--delimiter=$(env_of sacct 1 SQ_NONCE2)" -n -S now-2hours -E now -a -o JobID,User,State,ExitCode,Elapsed,End,NodeList,JobName'
	need "sacct's delimiter is not the queue nonce" eval '[ "$(env_of sacct 1 SQ_NONCE2)" != "$(env_of sacct 1 SQ_NONCE)" ]'
	need "sinfo: -hN -O, every field size 0 and framed by SQ_NONCE3" eval '
		n=$(env_of sinfo 1 SQ_NONCE3)
		argv_has sinfo -hN -O "CPUsState:0$n,NodeList:0$n,FreeMem:0$n,Memory:0$n,StateLong:0$n,Reason:0$n,TimeStamp:0$n,CPUsLoad:0$n,AllocMem:0$n"'
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

# ---- 4b. a node in more than one partition ------------------------------------
# sinfo -N prints one record per node and partition, all alike: sq lists each
# node once, where its first record came, and a dropped record is no unreadable
# one.  A node is its name as the pass (scrub -s) leaves it, controls and all,
# so names only the control rule makes alike stay apart; names alike once
# decoded are one (nodes_not_utf8).
# Most fixtures repeat a record of _common/sinfo-two-idle (which `empty` shows),
# of drained/sinfo or of node-one byte for byte; nodes-cntrl, nodes-dup-unreadable
# and nodes-dup-differ say in their sinfo what they hold.
dup_nodes() { lines_matching " cpu " | first_words; }   # the node lines' names, on one line
dup_two_idle() {   # dup_two_idle FIXTURE: in FULL, two-idle's node lines byte for byte
	sq_run empty -- --full
	need "each node once: rc 0"       rc_is 0
	local once=$RUN/nodes; node_lines > "$once"
	sq_run "$1" -- --full
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "node lines node01, node02, in that order" eval '[ "$(dup_nodes)" = "node01 node02" ]'
	need "node lines byte for byte those of each node once" node_lines_are "$once"
	need "no unreadable node note"    no_skips
	need "no node caption"            lacks "node output"
}
# compact_case's labels know no "queue is empty", so the empty queue's COMPACT
# screen is checked here: it fits, the footer last, and the one summary line
dup_compact4() {   # dup_compact4 FIXTURE DIGEST: COMPACT at 4 lines, empty queue
	sq_run "$1" SQ_WIDTH=100 SQ_HEIGHT=4 -- --compact
	need "COMPACT at 4: rc 0, stderr empty, stubs called" eval 'rc_is 0 && err_empty && calls_are 1 1 0 1'
	need "COMPACT at 4: at most 4 lines, footer 0/0/0/0 last" eval 'lines_within 4 && footer_last 0 0 0 0'
	need "COMPACT at 4: '$2'"         nodes_digest "$2"
}
c_nodes_dup_apart()    { T_TITLE="a node in two partitions, its records apart: one line, where it came first"; dup_two_idle nodes-dup-apart; }
c_nodes_dup_adjacent() { T_TITLE="a node in two partitions, its records adjacent: one line"; dup_two_idle nodes-dup-adjacent; }
c_nodes_dup_digest() {
	T_TITLE="COMPACT at 4 lines: the node summary counts a node in two partitions once"
	dup_compact4 nodes-dup-apart "nodes: 2 idle · 0/64 cpu · 0/250G mem"
}
c_nodes_dup_drained() {
	T_TITLE="a drained node in two partitions: one line, one ↳ reason, counted once in the summary"
	sq_run drained-dup -- --full
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "node lines node01, node02"  eval '[ "$(dup_nodes)" = "node01 node02" ]'
	need "one ↳ line, right after node02" eval '[ "$(lines_matching "^ +↳ " | wc -l)" -eq 1 ] &&
		plain | grep -A1 -E "^ +node02 " | tail -1 | grep -qE "^ +↳ bad\|disk\?replace · since 2026-10-01$"'
	need "no unreadable node note"    no_skips
	need "no node caption"            lacks "node output"
	dup_compact4 drained-dup "nodes: 1 idle, 1 drained · 0/64 cpu · 0/250G mem"
}
c_node_one_dup() {
	T_TITLE="one node in two partitions: the screen of it in one, FULL and COMPACT at 4, 5 and 6 lines"
	local h once
	sq_run node-one -- --full
	need "FULL, one partition: rc 0"  rc_is 0
	once=$OUT
	sq_run node-one-dup -- --full
	need "FULL: rc 0, stderr empty"   eval 'rc_is 0 && err_empty'
	need "FULL: the node once, in full" nodes_full node01 ""
	need "FULL: the screen of one partition, clock aside" eval 'cmp -s <(without_clock_ago "$once") <(without_clock_ago "$OUT")'
	for h in 4 5 6; do
		sq_run node-one SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
		need "$h, one partition: rc 0" rc_is 0
		once=$OUT
		sq_run node-one-dup SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
		need "$h: rc 0, stderr empty"  eval 'rc_is 0 && err_empty'
		need "$h: the node once, in full, no summary line" nodes_full node01 ""
		need "$h: the screen of one partition, clock aside" eval 'cmp -s <(without_clock_ago "$once") <(without_clock_ago "$OUT")'
	done
}
c_nodes_dup_compact() {
	T_TITLE="two-idle with node01 in two partitions, COMPACT at 6..11 lines: the screen of each node once"
	local fx h once off
	for fx in nodes-dup-apart nodes-dup-adjacent; do
		off=
		for h in $(seq 6 11); do
			sq_run empty SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
			rc_is 0 || off="$off $h(each once: rc $RC)"
			once=$OUT
			sq_run "$fx" SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
			{ rc_is 0 && err_empty && cmp -s <(without_clock_ago "$once") <(without_clock_ago "$OUT"); } || off="$off $h"
		done
		need "$fx: the screen of each node once, clock aside (not at H =${off:- none})" test -z "$off"
	done
}
c_nodes_dup_cntrl() {
	T_TITLE="names alike only once scrubbed (node\\x01, node?, node\\x02) stay three nodes; node\\x01's second record goes"
	sq_run nodes-cntrl -- --full
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "three node lines, each 'node?'" eval '[ "$(dup_nodes)" = "node? node? node?" ]'
	need "no unreadable node note"    no_skips
	need "no node caption"            lacks "node output"
}
c_nodes_dup_unreadable() {
	T_TITLE="an unreadable record of a node is skipped and counted, before or after its readable one"
	sq_run nodes-dup-unreadable -- --full
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "node lines node01, node02, in that order" eval '[ "$(dup_nodes)" = "node01 node02" ]'
	need "'↳ 2 unreadable node rows skipped', once" eval '[ "$(lines_matching "^ +↳ 2 unreadable node rows skipped$" | wc -l)" -eq 1 ]'
	need "no node caption"            lacks "node output"
}
c_nodes_dup_differ() {
	T_TITLE="a later record of a node changes nothing: node01 stays idle, with no reason line"
	sq_run nodes-dup-differ -- --full
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "node lines node01, node02, in that order" eval '[ "$(dup_nodes)" = "node01 node02" ]'
	need "node01 idle, from its first record" matches "^ +node01 .* 0/32 cpu .* idle$"
	need "no ↳ reason line, no 'drained'" eval '! matches "^ +↳ " && lacks drained'
	need "no unreadable node note"    no_skips
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
# Whenever sq does not know the job counts, the footer keeps its shape with "?"
# for each count, as Franz chose 2026-10-15: squeue failed or hung, and (a call
# made for him) its stream was unreadable or cut off.  It used to claim 0 jobs.
c_squeue_fails() {
	T_TITLE="squeue rc 1: the job list is unavailable, and the footer says '? jobs' instead of a count"
	sq_run squeue-fails --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: queue once, no fallback, sacct still asked" calls_are 1 1 0 1
	need "banner carries squeue's first stderr line" matches "^  ⚠ slurm unreachable · squeue: error: Unable to contact"
	need "'job list unavailable'"     has "job list unavailable"
	need "finished block still from sacct" eval 'rows recent | grep -qE "^ +1001 +done +COMPLETED "'
	need "no '0 jobs' footer while the job list is unavailable" eval '! section footer | grep -qE "^ *0 jobs "'
	need "footer ? ? ? ?, the last line" footer_unknown
	# the same colours as a footer with counts: the "?" only stands in for the numbers
	local normal
	sq_run mixed -- --color
	normal=$(footer_sgr)
	need "a footer with counts, coloured: bold jobs, green running, yellow pending, red other" \
		eval 'rc_is 0 && [ "$normal" = "[1m [0m [32m [0m [33m [0m [31m [0m" ]'
	sq_run squeue-fails -- --color
	need "the '?' footer, coloured: the same SGR sequences" eval 'rc_is 0 && [ "$(footer_sgr)" = "$normal" ]'
	# of several lines of stderr, the first is the reason
	sq_run "$(stderr_fixture squeue 'the first line\nthe second line')" --
	need "squeue's stderr of two lines: rc 0, the first on the banner" eval 'rc_is 0 && matches "^  ⚠ slurm unreachable · squeue: error: the first line$"'
}
c_squeue_hangs() {
	T_TITLE="squeue hangs (cut at SQ_TIMEOUT=1): the job list is unavailable, and the footer says '? jobs' instead of a count"
	local t0=$SECONDS
	sq_run squeue-hangs SQ_TIMEOUT=1 --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: queue once, no fallback" calls_are 1 1 0 1
	need "finished within 10s"        eval '[ $((SECONDS - t0)) -lt 10 ]'
	need "banner 'no response after 1s'" matches "^  ⚠ slurm unreachable · no response after 1s$"
	need "'job list unavailable'"     has "job list unavailable"
	need "no '0 jobs' footer while the job list is unavailable" eval '! section footer | grep -qE "^ *0 jobs "'
	need "footer ? ? ? ?, the last line" footer_unknown
}
# A squeue that ignores SIGTERM outlives the deadline and is killed 2s later:
# timeout then exits 137, as for any SIGKILL.  It is the timeout because
# timeout said it signalled (--verbose, to its own stderr), or, where timeout
# predates --verbose (coreutils < 8.29, faked by tests/lib/timeout-as), because
# a 137 cannot be told apart there and reads as the timeout (Franz, 2026-10-16).
# A SIGKILL timeout did not send is a crash; so is a SIGSEGV, whose "dumped
# core" from timeout never reaches the screen.  bash's own "Killed" and
# "Segmentation fault" notices stay off sq's stderr.
timeout_as() { printf 'PATH=%s' "$here/lib/timeout-as:$here/bin:$PATH"; }   # timeout_as: the PATH for SQSTUB_TIMEOUT=...
signal_fixture() {   # signal_fixture FILE N: as stderr_fixture, FILE dies by signal N at once
	local d; d=$(stderr_fixture "$1" x)
	printf '@signal %s\n' "$2" > "$d/$1"
	printf '%s' "$d"
}
c_squeue_ignores_term() {
	T_TITLE="squeue ignoring SIGTERM, killed after SQ_TIMEOUT=1: 'no response after 1s', with and without timeout --verbose"
	local t0 how
	for how in verbose old; do
		t0=$SECONDS
		if [ $how = verbose ]; then sq_run squeue-hangs SQ_TIMEOUT=1 SQSTUB_IGNORE_TERM=squeue --
		else sq_run squeue-hangs SQ_TIMEOUT=1 SQSTUB_IGNORE_TERM=squeue "$(timeout_as)" SQSTUB_TIMEOUT=old --; fi
		need "$how: rc 0, stderr empty, stubs: queue once, no fallback" eval 'rc_is 0 && err_empty && calls_are 1 1 0 1'
		need "$how: finished within 10s" eval '[ $((SECONDS - t0)) -lt 10 ]'
		need "$how: banner 'no response after 1s'" matches "^  ⚠ slurm unreachable · no response after 1s$"
		need "$how: 'job list unavailable', footer ? ? ? ?" eval 'has "job list unavailable" && footer_unknown'
	done
}
c_collector_killed() {
	T_TITLE="a SIGKILL nobody's timeout sent, and a SIGSEGV with timeout's 'dumped core', are crashes; timeout failing itself (rc 125) says why"
	sq_run "$(signal_fixture squeue 9)" --
	need "squeue killed at once: rc 0, stderr empty, 'squeue crashed (signal 9)'" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue crashed \(signal 9\)$"'
	sq_run "$(silent_fixture squeue 137)" --
	need "squeue exit 137 at once, no stderr: rc 0, 'squeue crashed (signal 9)'" \
		eval 'rc_is 0 && matches "^  ⚠ slurm unreachable · squeue crashed \(signal 9\)$"'
	sq_run "$(signal_fixture squeue 9)" "$(timeout_as)" SQSTUB_TIMEOUT=old --
	need "squeue killed at once, timeout without --verbose: rc 0, read as the timeout" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · no response after 3s$"'
	sq_run "$(signal_fixture squeue 11)" --
	need "squeue SIGSEGV: rc 0, stderr empty, 'squeue crashed (signal 11)'" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue crashed \(signal 11\)$"'
	sq_run "$(signal_fixture sinfo 11)" "$(timeout_as)" SQSTUB_TIMEOUT=core --
	need "sinfo SIGSEGV, timeout says 'dumped core': rc 0, stderr empty, 'sinfo crashed (signal 11)'" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · sinfo crashed \(signal 11\)$" && lacks "dumped core"'
	sq_run mixed "$(timeout_as)" SQSTUB_TIMEOUT=broken --
	need "timeout fails itself (rc 125): rc 0, its first line on the banner, no client ran" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · timeout: fork system call failed" && [ "$(grep -c "^CALL" "$LOG")" -eq 0 ]'
	sq_run mixed "$(timeout_as)" SQSTUB_TIMEOUT=broken SQSTUB_TIMEOUT_TEXT='timeout: \033[2Jcannot fork\nTry again later' --
	need "timeout fails itself in two lines, an ESC in the first: rc 0, the first line on the banner, scrubbed" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · timeout: \[2Jcannot fork$" && [ "$(escapes)" -eq 0 ]'
	# a client may exit 125 too: its own line is the reason, timeout said nothing
	sq_run "$(silent_fixture squeue 125 'squeue: error: its own reason')" --
	need "squeue exit 125 with its own stderr: rc 0, its line on the banner" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: its own reason$"'
	# ... and so it is when timeout did say something, a warning of its own
	local tbin=$T_DIR/tbin
	mkdir -p "$tbin"; printf '#!/bin/sh\necho "timeout: a warning of its own" >&2\nexec %q "$@"\n' "$bound" > "$tbin/timeout"; chmod +x "$tbin/timeout"
	sq_run "$(silent_fixture squeue 125 'squeue: error: its own reason')" PATH="$tbin:$here/bin:$PATH" --
	need "squeue exit 125 with its own stderr, timeout warning on its own: rc 0, squeue's line on the banner" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: its own reason$"'
}
# sh -c gets the tool's name as its $0, so a client missing from PATH reads
# "sinfo: ...: not found" on the banner, not "sh: ...", which names no tool
c_tool_missing() {
	T_TITLE="sinfo missing from PATH: its 'not found' names sinfo, not sh"
	local t dir dirs path= nobin=$T_DIR/nobin
	mkdir -p "$nobin"
	for t in squeue sacct stty; do printf '#!/bin/sh\nexec %q "$@"\n' "$here/bin/$t" > "$nobin/$t"; chmod +x "$nobin/$t"; done
	IFS=: read -ra dirs <<< "$PATH"
	for dir in "${dirs[@]}"; do [ -x "$dir/sinfo" ] || path=$path:$dir; done     # nor any other sinfo
	sq_run mixed PATH="$nobin$path" --
	need "rc 0, stderr empty, sinfo's 'not found' on the banner" eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · sinfo: .*not found"'
	need "no 'sh:' on the banner" eval '! matches "^  ⚠ slurm unreachable · sh: "'
	need "squeue still answered: footer 6/3/2/1" footer_is 6 3 2 1
}
# a timeout with a leading zero is still a number of seconds to timeout(1);
# bash arithmetic would read 08 as a bad octal number and abort
c_timeout_leading_zero() {
	T_TITLE="SQ_TIMEOUT=08 and 09.5: sq runs, and a SIGKILL still reads as a crash"
	local t
	for t in 08 09.5; do
		sq_run mixed SQ_TIMEOUT=$t --
		need "$t: rc 0, stderr empty, footer 6/3/2/1" eval 'rc_is 0 && err_empty && footer_is 6 3 2 1'
		sq_run "$(signal_fixture squeue 9)" SQ_TIMEOUT=$t --
		need "$t, squeue killed at once: rc 0, stderr empty, 'squeue crashed (signal 9)'" \
			eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue crashed \(signal 9\)$"'
	done
}
c_squeue_garbage() {
	T_TITLE="squeue answers unframed text: 'queue output unreadable', footer '? jobs'"
	sq_run squeue-garbage --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "caption 'queue output unreadable'" has "⚠ queue output unreadable (output format overridden?)"
	need "no row from the garbage"    lacks "train"
	need "no counts from an unreadable stream: footer ? ? ? ?, the last line" footer_unknown
	need "no unreachable banner"      lacks "slurm unreachable"
}
c_queue_cut() {
	T_TITLE="squeue's stream ends inside a record: 'queue output incomplete', footer '? jobs'"
	sq_run queue-cut --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs called"               calls_are 1 1 0 1
	need "caption 'queue output incomplete'" has "⚠ queue output incomplete"
	need "no counts from a cut stream, only a lower bound: footer ? ? ? ?, the last line" footer_unknown
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
# ---- 7b. the EXIT cell: ExitCode's second field --------------------------
# A signal only up to 31; 125 is Slurm's OOM marker, any other value the low
# 7 bits of one of Slurm's own error codes.  The cell is rc, rc/sigN, rc/oom or
# rc/errN; a folded group lists its distinct exits by rc, then N, as numbers.
fin_exit() {   # fin_exit ID: the EXIT cell of the finished row whose first cell is ID
	rows recent | ID=$1 LC_ALL=$utf8 gawk '$1 == ENVIRON["ID"] {
		i = ($2 ~ /^×[0-9]+$/) ? 5 : 4                  # past the ×N of a fold, NAME and STATE
		x = $i; for (j = i + 1; j <= NF - 2; j++) x = x " " $j   # ELAPSED and AGO end the row
		print x; exit }'
}
exit_is() { [ "$(fin_exit "$1")" = "$2" ]; }    # exit_is ID EXIT
c_exit_labels() {
	T_TITLE="EXIT: 1-31 sigN, 125 oom, any other N errN, from the allocation row or a step; the first non-zero field, but 125 wins; folds rc first, then N"
	sq_run exits SQ_RECENT_MAX=50 --
	need "rc 0, stderr empty, stubs called" eval 'rc_is 0 && err_empty && calls_are 1 1 0 1'
	need "22 finished rows, no step row"    eval '[ "$(nrows recent)" -eq 22 ] && ! rows recent | grep -qE "batch|extern|srun"'
	need "53 on the allocation row and its step: 0/err53" exit_is 6100 0/err53
	need "125 on the allocation row: 0/oom"                exit_is 6101 0/oom
	need "125 on a step of a COMPLETED job: 0/oom, STATE stays COMPLETED" \
		eval 'exit_is 6102 0/oom && rows recent | grep -qE "^ +6102 +stepoom +COMPLETED "'
	need "125 on a later step wins over the batch step's earlier 15" exit_is 6103 0/oom
	need "rc from the batch step, oom from an srun step: 1/oom" exit_is 6104 1/oom
	need "31 is a signal, 32 an error"      eval 'exit_is 6105 0/sig31 && exit_is 6106 0/err32'
	need "124, 126, 127 are errors"         eval 'exit_is 6107 0/err124 && exit_is 6108 0/err126 && exit_is 6109 0/err127'
	need "the canceller follows the label"  eval '[[ "$(fin_exit 6110)" == "0/err53 by "?* ]]'
	need "125 on a later step wins over an earlier 53 too" exit_is 6111 0/oom
	need "only 125 wins: a later 126 leaves the earlier 15" exit_is 6112 0/sig15
	need "only 125 wins: a later 124 leaves the earlier 15" exit_is 6116 0/sig15
	need "the first non-zero rc (batch 3, then srun 5): 3" exit_is 6113 3
	need "the first non-zero N (batch 15, then srun 9): 0/sig15" exit_is 6114 0/sig15
	need "sacct 0:1 is signal 1: the 0:1 reading is the fallback's alone" exit_is 6115 0/sig1
	need "fold of every kind: 2, 1, then the cap" eval 'row_cell recent "6200_[0-5] ×6" && exit_is 6200_[0-5] "2,1,0/oom,…"'
	need "rc 0 only: 125, 53, 9 by number, not err < oom < sig by text" exit_is 6300_[0-2] "0/oom,0/err53,0/sig9"
	need "126 before 125 by number; the cap of three cuts the rest" exit_is 6400_[0-3] "0/err126,0/oom,0/err102,…"
	need "one rc: 53 before 9 before none" exit_is 6500_[0-2] "1/err53,1/sig9,1"
	need "three-digit return codes by number: 127, then 100" exit_is 6600_[0-1] "127,100"
}
c_exit_compact() {
	T_TITLE="EXIT in COMPACT's one-line form: the newest failure, a fold, with the same cell as its row"
	sq_run exits SQ_WIDTH=100 SQ_HEIGHT=10 -- --compact
	need "rc 0, stderr empty, stubs called" eval 'rc_is 0 && err_empty && calls_are 1 1 0 1'
	need "one line: 6200 with its exits rc first, then N, capped" \
		fin_line_is "recently finished: 6200_[0-5] ×6 sweep FAILED 2,1,0/oom,…"
}
c_exit_garbage() {
	T_TITLE="EXIT: a field that is not 1-3 ASCII digits reads as 0, so no 1e3, 53.9, +inf or -1 leaks through"
	local id
	sq_run exits-garbage SQ_RECENT_MAX=50 --
	need "rc 0, stderr empty, stubs called" eval 'rc_is 0 && err_empty && calls_are 1 1 0 1'
	need "22 finished rows"                 eval '[ "$(nrows recent)" -eq 22 ]'
	for id in 101 104 105 106 107 108 109 110 111 112 113 114 115 116 117 118 119; do
		need "$id ($(rows recent | gawk -v i=$id '$1 == i { print $2 }')): 0" exit_is $id 0
	done
	need "':53' and '0:53:7': field 2 is 53"  eval 'exit_is 102 0/err53 && exit_is 103 0/err53'
	need "three digits read: 0:999 is err999, 007:0 is 7" eval 'exit_is 120 0/err999 && exit_is 121 7'
	need "a fold of junk: the junk is 0:0"    exit_is 7300_[0-2] "0/sig9,0"
}
c_exit_fallback() {
	T_TITLE="EXIT from squeue -t all, in 23.11's n:n form: 0:125 oom, 0:53 err53, 0:1 read as 1:0, empty and junk 0"
	sq_run exits-fallback --
	need "rc 0, stderr empty, stubs: sacct, then the fallback" eval 'rc_is 0 && err_empty && calls_are 1 1 1 1'
	need "15 finished rows, the running job not among them" eval '[ "$(nrows recent)" -eq 15 ] && ! row_cell recent 3001'
	need "1:0 is 1, 137:0 is 137 (not reduced)" eval 'exit_is 6001 1 && exit_is 6003 137'
	need "0:125 is 0/oom, 0:53 0/err53, 0:9 0/sig9" eval 'exit_is 6002 0/oom && exit_is 6005 0/err53 && exit_is 6007 0/sig9'
	need "0:1, slurmctld's raw 1, is exit 1, not signal 1" exit_is 6006 1
	need "2:1 stays 2/sig1: only rc 0 with signal 1 is read as exit 1" exit_is 6010 2/sig1
	need "1:1 stays 1/sig1 as well" exit_is 6015 1/sig1
	need "the values are read, not the text: ' 0:1', 00:1, 0:01, 0:1:0 are exit 1 too" \
		eval 'exit_is 6011 1 && exit_is 6012 1 && exit_is 6013 1 && exit_is 6014 1'
	need "nothing (NO_VAL) and 0:1x are 0, 0:0 is 0" eval 'exit_is 6004 0 && exit_is 6008 0 && exit_is 6009 0'
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
# Backslashes in outside text.  gawk processes the escapes of a -v value after
# sq has scrubbed the control characters, so "\n" in a filter, an env setting,
# the host name or a collector's stderr became a newline - a forged line - and
# "\033" a raw ESC.  Every path must show the text byte for byte.
bs_text='x\nFORGED: 0 jobs\tT\033[31mR\\B'
bs_inert() { ! matches '^ *FORGED' && [ "$(escapes)" -eq 0 ] && ! grep -q $'\t' "$OUT"; }   # nothing it spells out happened
bs_kept()  { has "$bs_text" && bs_inert; }     # ... and it is on the screen as typed
# "wide" has a job name wider than any screen, so no caption is clipped short
stderr_fixture() {   # stderr_fixture FILE|none TEXT: "wide", but its FILE collector fails, printing TEXT (fixture escapes) on stderr
	local d=$T_DIR/fx-$1; mkdir -p "$d"
	printf '@include %s\n' "$fixtures/_common/sinfo-two-idle" > "$d/sinfo"
	printf '@include %s\n' "$fixtures/wide/squeue" > "$d/squeue"
	printf '@include %s\n' "$fixtures/_common/empty" > "$d/sacct"
	printf '@include %s\n' "$fixtures/_common/empty" > "$d/squeue-all"
	# the fallback is reached only when sacct fails too, here silently, so the
	# fallback's error is the one real reason and the caption shows it
	[ "$1" != squeue-all ] || printf '@exit 1\n' > "$d/sacct"
	[ "$1" = none ] || printf '@stderr %s: error: %s\n@exit 1\n' "${1%-all}" "$2" > "$d/$1"
	printf '%s' "$d"
}
# the fixture escape for a backslash is a doubled one
bs_fixture() { stderr_fixture "$1" "${bs_text//\\/\\\\}"; }   # bs_fixture FILE|none: bs_text on FILE's stderr
c_backslash_text() {
	T_TITLE="'\\n' '\\t' '\\033' '\\\\' in -u, -p, -n, SQ_SINCE, the host name and every collector's stderr reach the screen byte for byte"
	local f fx hbin=$T_DIR/hbin
	for f in -u -p; do
		sq_run wide -- "$f" "$bs_text"
		need "$f: rc 0, stubs called"     eval 'rc_is 0 && calls_are 1 1 0 1'
		need "$f: the filter on the caption, literally, and no forged line" bs_kept
	done
	sq_run "$(bs_fixture none)" -- -n "$bs_text"      # -n has no sacct equivalent: the fallback
	need "-n: rc 0, the value forwarded to squeue as typed" eval 'rc_is 0 && argv_has squeue -n "$bs_text"'
	need "-n: no forged line, no ESC, no tab" bs_inert
	sq_run wide SQ_SINCE="$bs_text" --
	need "SQ_SINCE: rc 0, the window on the caption, literally" eval 'rc_is 0 && bs_kept'
	mkdir -p "$hbin"; printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "$bs_text" > "$hbin/hostname"; chmod +x "$hbin/hostname"
	sq_run wide PATH="$hbin:$here/bin:$PATH" --
	need "host name: rc 0, on the title, literally" eval 'rc_is 0 && bs_kept && plain | head -1 | grep -qF "SLURM $bs_text "'
	for f in sinfo squeue sacct squeue-all; do
		fx=$(bs_fixture "$f")
		sq_run "$fx" --
		need "$f stderr: rc 0, shown literally" eval 'rc_is 0 && bs_kept'
	done
}

# Control characters.  squeue echoes what the user typed into its stderr
# ("Invalid user: <name>"), and that first line went to the banner raw, as did
# sinfo's and the host name to the title: an ESC could clear the screen, a CR
# overwrite the line.  They lose their control characters like every other
# outside text, so ESC[2J reads "[2J" and the CR is gone.
ctl_fixture_text='Invalid user: \e[2Jboom\rX'      # in the stub's escapes: ESC and CR
ctl_shown='Invalid user: [2JboomX'
ctl_c1_fixture_text='Invalid user: a\xc2\x9b2Jb\xc2\x85c\xc2\x9dd é€✓ \xc2\xa0!'   # C1 CSI NEL OSC, then text that stays
ctl_c1_shown=$(printf 'Invalid user: a2Jbcd é€✓ \xc2\xa0!')                     # U+00A0 is no control
c1_inert() { ! LC_ALL=C grep -q $'\xc2[\x80-\x9f]' "$OUT"; }
ctl_inert() { [ "$(escapes)" -eq 0 ] && ! LC_ALL=C grep -q $'\r' "$OUT"; }   # no ESC, no CR byte
c_control_text() {
	T_TITLE="ESC and CR in squeue's, sinfo's, sacct's and the fallback's stderr and in the host name, and C1 controls in stderr and a filter, are scrubbed before they reach the screen"
	local f fx
	for f in squeue sinfo sacct squeue-all; do
		fx=$(stderr_fixture "$f" "$ctl_fixture_text")
		sq_run "$fx" --
		need "$f stderr: rc 0, stderr empty" eval 'rc_is 0 && err_empty'
		need "$f stderr: shown without its control characters" has "${f%-all}: error: $ctl_shown"
		need "$f stderr: no ESC, no CR in the output" ctl_inert
	done
	fx=$(stderr_fixture squeue "$ctl_fixture_text")
	sq_run "$fx" COLUMNS=120 LINES=50 --
	need "squeue stderr in colour: rc 0, the banner scrubbed" eval 'rc_is 0 && has "slurm unreachable · squeue: error: $ctl_shown"'
	need "squeue stderr in colour: every ESC is sq's own SGR, no CR" eval 'escapes_all_sgr && ! LC_ALL=C grep -q $'"'"'\r'"'"' "$OUT"'
	# C1 controls arrive as UTF-8 pairs (\xc2\x9b is CSI, \x85 NEL, \x9d OSC), which a
	# byte-wise tr never saw; any other UTF-8 text stays as it is
	for f in squeue sinfo; do
		sq_run "$(stderr_fixture "$f" "$ctl_c1_fixture_text")" --
		need "$f stderr with C1: rc 0, shown without them, the other UTF-8 text kept" eval 'rc_is 0 && has "$f: error: $ctl_c1_shown"'
		need "$f stderr with C1: no C1 pair in the output" c1_inert
	done
	sq_run wide -- -u "$(printf 'al\xc2\x9bi\xc2\x9dce')"
	need "-u with C1: rc 0, the caption names user=alice" eval 'rc_is 0 && calls_are 1 1 0 1 && has "recently finished · last 2h · user=alice"'
	need "-u with C1: no C1 pair in the output" c1_inert
	sq_run wide SQSTUB_HOST=$'node\033[2Jboom\rX' --
	need "host name: rc 0, stderr empty$(err_quoted)" eval 'rc_is 0 && err_empty'
	need "host name: on the title without its control characters" eval 'plain | head -1 | grep -qF "SLURM node[2JboomX "'
	need "host name: no ESC, no CR in the output" ctl_inert
}

# A collector that fails with nothing readable on stderr (a crash prints
# nothing; a line of control characters scrubs to nothing) used to read as
# success: squeue's "queue is empty" and a footer of 0 jobs, sinfo's node lines
# gone without a banner.  The reason is then its exit status, as Franz chose
# 2026-10-15: "<tool> failed (exit N)", or "<tool> crashed (signal N)" above 128.
silent_fixture() {   # silent_fixture FILE EXIT [LINE]: as stderr_fixture, FILE exits EXIT with LINE (fixture escapes) or nothing on stderr
	local d; d=$(stderr_fixture "$1" x)
	{ [ $# -lt 3 ] || printf '@stderr %s\n' "$3"; printf '@exit %s\n' "$2"; } > "$d/$1"
	printf '%s' "$d"
}
c_silent_failure() {
	T_TITLE="a collector failing with nothing readable on stderr names its exit status: 'squeue failed (exit 1)', 'squeue crashed (signal 11)'"
	sq_run "$(silent_fixture sinfo 1)" --
	need "sinfo exit 1, no stderr: rc 0, the banner 'sinfo failed (exit 1)'" eval 'rc_is 0 && matches "^  ⚠ slurm unreachable · sinfo failed \(exit 1\)$"'
	sq_run "$(silent_fixture squeue 1)" --
	need "squeue exit 1, no stderr: rc 0, the banner 'squeue failed (exit 1)'" eval 'rc_is 0 && matches "^  ⚠ slurm unreachable · squeue failed \(exit 1\)$"'
	need "squeue exit 1: 'job list unavailable' and the '?' footer, like any squeue failure" eval 'has "job list unavailable" && lacks "queue is empty" && footer_unknown'
	sq_run "$(silent_fixture squeue 139)" --
	need "squeue exit 139, no stderr: rc 0, the banner 'squeue crashed (signal 11)'" eval 'rc_is 0 && matches "^  ⚠ slurm unreachable · squeue crashed \(signal 11\)$"'
	need "squeue exit 139: 'job list unavailable' and the '?' footer" eval 'has "job list unavailable" && footer_unknown'
	sq_run "$(silent_fixture squeue 1 '\r')" --
	need "squeue exit 1, stderr a lone CR: rc 0, 'squeue failed (exit 1)', no CR byte" eval 'rc_is 0 && matches "^  ⚠ slurm unreachable · squeue failed \(exit 1\)$" && ctl_inert && footer_unknown'
	sq_run "$(silent_fixture sinfo 1 '\a')" --
	need "sinfo exit 1, stderr a lone BEL: rc 0, 'sinfo failed (exit 1)', no BEL byte" eval 'rc_is 0 && matches "^  ⚠ slurm unreachable · sinfo failed \(exit 1\)$" && [ "$(bels)" -eq 0 ]'
	sq_run "$(silent_fixture sacct 1)" --
	need "sacct exit 1, no stderr: rc 0, the fallback caption names it" eval 'rc_is 0 && calls_are 1 1 1 1 && has "recently finished · recent only (no accounting) · sacct failed (exit 1)"'
	# the exit status as given, and 128 is still an exit: only above it is a signal
	local x want
	for x in 2:"squeue failed (exit 2)" 128:"squeue failed (exit 128)" 129:"squeue crashed (signal 1)"; do
		want=${x#*:}
		sq_run "$(silent_fixture squeue "${x%%:*}")" --
		need "squeue exit ${x%%:*}, no stderr: rc 0, '$want'" eval 'rc_is 0 && lines_matching "⚠ slurm unreachable" | grep -qxF "  ⚠ slurm unreachable · $want"'
	done
	# a squeue failing silently has failed all the same: no fallback asks it again
	fx=$(silent_fixture squeue 1); printf '@exit 1\n' > "$fx/sacct"
	sq_run "$fx" --
	need "squeue and sacct silent: rc 0, sacct asked, no fallback" eval 'rc_is 0 && calls_are 1 1 0 1'
}
# Where a line could name several reasons, a real one (stderr, the timeout)
# beats one made up from an exit status; among real ones the order stays: the
# filter or sacct's, then the fallback's, then squeue's; sinfo's, then squeue's
c_real_reason_wins() {
	T_TITLE="a real error text beats 'failed (exit N)': the fallback's stderr over a silent sacct, squeue's over a silent sinfo"
	local fx
	fx=$(silent_fixture squeue-all 1 'squeue: error: the fallback says why')     # sacct fails silently there
	sq_run "$fx" --
	need "sacct silent, the fallback with stderr: rc 0, its text on the caption" \
		eval 'rc_is 0 && calls_are 1 1 1 1 && has "finished jobs unavailable · squeue: error: the fallback says why"'
	fx=$(silent_fixture squeue-all 1)
	sq_run "$fx" --
	need "sacct and the fallback both silent: rc 0, 'sacct failed (exit 1)'" eval 'rc_is 0 && has "finished jobs unavailable · sacct failed (exit 1)"'
	fx=$(silent_fixture squeue 1 'squeue: error: the controller says why'); printf '@exit 1\n' > "$fx/sacct"
	sq_run "$fx" --
	need "sacct silent, squeue with stderr: rc 0, squeue's text on the caption" \
		eval 'rc_is 0 && calls_are 1 1 0 1 && has "finished jobs unavailable · squeue: error: the controller says why"'
	fx=$(silent_fixture squeue 1 'squeue: error: the controller says why'); printf '@exit 1\n' > "$fx/sinfo"
	sq_run "$fx" --
	need "sinfo silent, squeue with stderr: rc 0, squeue's text on the banner" \
		eval 'rc_is 0 && matches "^  ⚠ slurm unreachable · squeue: error: the controller says why$"'
	fx=$(silent_fixture squeue 1 'squeue: error: the controller says why'); printf '@stderr sinfo: error: sinfo says why\n@exit 1\n' > "$fx/sinfo"
	sq_run "$fx" --
	need "sinfo and squeue both with stderr: rc 0, sinfo's text on the banner, as before" \
		eval 'rc_is 0 && matches "^  ⚠ slurm unreachable · sinfo: error: sinfo says why$"'
	# the filter no accounting can express is real text too, and outranks the fallback's
	sq_run "$(silent_fixture squeue-all 1 'squeue: error: the fallback says why')" -- -n x
	need "-n x, the fallback with stderr: rc 0, the filter on the caption" \
		eval 'rc_is 0 && calls_are 1 1 1 0 && has "finished jobs unavailable · sq does not translate -n for sacct"'
}

# Every byte rule of the scrub, on one stderr line: a pair nested in a pair, both
# ends of the C1 range, DEL, the last C0 byte, NUL (bash would drop it from the
# reason with a warning of its own), and a C0 byte between the halves of a pair,
# which taking C0 out first would join.  The nested pair's outer halves and the
# split pair's are no UTF-8, so each reads ␚, and the pair inside goes.  Then
# each site that scrubs, with a C1 byte none of them let through before: the
# three usage errors that echo a value, the filters on the caption, SQ_SINCE
# and the host name; the skipped filter is named without its value.
c1_err_inert() { ! LC_ALL=C grep -q $'\xc2[\x80-\x9f]' "$ERR"; }
c_scrub_sites() {
	T_TITLE="the scrub's bytes (nested pair, \\xc2\\x80 and \\x9f, DEL, \\x1f, NUL, C0 inside a pair) and each site that scrubs: usage errors, filters, SQ_SINCE, host"
	local c1=$'\xc2\x9b'
	sq_run "$(stderr_fixture squeue 'p\xc2\xc2\x9b\x9bq\xc2\x80r\xc2\x9fs\x7ft\x1fu\x00v\xc2\x01\x9bw')" --
	need "squeue stderr with every byte rule: rc 0, stderr empty, 'p␚␚qrstuv␚␚w' on the banner" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: p␚␚qrstuv␚␚w$"'
	sq_run wide -- --reserve "${c1}x"
	need "--reserve: refused, the value echoed as 'x'" eval 'rc_is 2 && grep -qF "not '"'"'x'"'"'" "$ERR" && c1_err_inert'
	sq_run wide -- --reserve $'a\x7fb'       # plain ASCII, which takes a shorter way
	need "--reserve with DEL in ASCII text: refused, the value echoed as 'ab'" eval 'rc_is 2 && grep -qF "not '"'"'ab'"'"'" "$ERR"'
	sq_run wide -- "--fo${c1}o"
	need "an unknown long option: refused, echoed as --foo" eval 'rc_is 2 && grep -qF "sq: --foo is not one of the long options" "$ERR" && c1_err_inert'
	sq_run wide -- -u "-${c1}x"
	need "-u -x: refused, the value echoed as '-x'" eval 'rc_is 2 && grep -qF "not '"'"'-x'"'"'" "$ERR" && c1_err_inert'
	sq_run "$(stderr_fixture none x)" -- "-nx${c1}y"
	need "-nx…y (not translated for sacct): rc 0, the caption names -n, no C1" \
		eval 'rc_is 0 && calls_are 1 1 1 0 && has "recent only (sq does not translate -n for sacct)" && c1_inert'
	sq_run "$(stderr_fixture none x)" -- -p "x${c1}y"
	need "-p x…y: rc 0, the caption's filter reads part=xy, no C1" \
		eval 'rc_is 0 && calls_are 1 1 0 1 && has "recently finished · last 2h · part=xy" && c1_inert'
	sq_run wide SQ_SINCE="2026-01-01${c1}T00" --
	need "SQ_SINCE with C1: rc 0, the caption says since 2026-01-01T00, no C1" eval 'rc_is 0 && has "recently finished · since 2026-01-01T00" && c1_inert'
	# the host name from tests/bin/hostname (SQSTUB_HOST), no script written
	# and run in the case; three needs, not one, and stderr quoted: this failed
	# now and then in full runs, and which part did and why is the first thing
	# to know
	sq_run wide SQSTUB_HOST="no${c1}de" --
	need "host name with C1: rc 0, stderr empty$(err_quoted)" eval 'rc_is 0 && err_empty'
	need "host name with C1: the title says SLURM node" eval 'plain | head -1 | grep -qF "SLURM node "'
	need "host name with C1: no C1 on the screen" c1_inert
}

# Bytes that are no UTF-8 - Latin-1 text, a character cut in half - reach no
# screen and no gawk as they are (gawk warned "Invalid multibyte data" on sq's
# stderr, the terminal drew U+FFFD or worse): each piece of them, as long as it
# could have been the start of a character, reads one ␚.  A ␚ or U+FFFD that
# was in the text itself is a character like any other and stays.
err_utf8_valid() { OUT=$ERR utf8_valid; }
c_scrub_not_utf8() {
	T_TITLE="Latin-1 bytes and halved characters read one ␚ each on a banner, a caption, a filter echo and a usage error; a genuine ␚ or U+FFFD stays"
	local x
	sq_run "$(stderr_fixture squeue 'user ren\xe9 not found')" --
	need "Latin-1 in squeue's stderr: rc 0, stderr empty, 'user ren␚ not found' on the banner" \
		eval 'rc_is 0 && err_empty && utf8_valid && matches "^  ⚠ slurm unreachable · squeue: error: user ren␚ not found$"'
	sq_run "$(stderr_fixture sacct 'user ren\xe9')" --
	need "Latin-1 in sacct's stderr: rc 0, stderr empty, 'user ren␚' on the fallback's caption" \
		eval 'rc_is 0 && err_empty && utf8_valid && has "recent only (no accounting) · sacct: error: user ren␚"'
	sq_run wide -- -u "$(printf 'ren\xe9')"
	need "-u in Latin-1: rc 0, stderr empty, the caption says user=ren␚" \
		eval 'rc_is 0 && err_empty && utf8_valid && has "recently finished · last 2h · user=ren␚"'
	sq_run wide -- -u "$(printf -- '-ren\xe9')"
	need "-u -ren… in Latin-1: refused, the value echoed as '-ren␚'" eval 'rc_is 2 && grep -qF "not '"'"'-ren␚'"'"'" "$ERR" && err_utf8_valid'
	sq_run wide -- --reserve "$(printf 'ren\xe9')"
	need "--reserve in Latin-1: refused, the value echoed as 'ren␚'" eval 'rc_is 2 && grep -qF "not '"'"'ren␚'"'"'" "$ERR" && err_utf8_valid'
	sq_run wide -- "$(printf -- '--f\xfco')"
	need "an unknown long option in Latin-1: refused, echoed as --f␚o" eval 'rc_is 2 && grep -qF "sq: --f␚o is not one of the long options" "$ERR" && err_utf8_valid'
	# é, € and 😀 each lose their last byte: one ␚ apiece, mid-text and at the end
	sq_run "$(stderr_fixture squeue 'a\xc3b\xe2\x82c\xf0\x9f\x98d')" --
	need "halved 2-, 3- and 4-byte characters mid-text: rc 0, stderr empty, 'a␚b␚c␚d'" \
		eval 'rc_is 0 && err_empty && utf8_valid && matches "^  ⚠ slurm unreachable · squeue: error: a␚b␚c␚d$"'
	for x in '\xc3' '\xe2\x82' '\xf0\x9f\x98'; do
		sq_run "$(stderr_fixture squeue "end$x")" --
		need "a halved $x at the end of squeue's stderr: rc 0, stderr empty, 'end␚'" \
			eval 'rc_is 0 && err_empty && utf8_valid && matches "^  ⚠ slurm unreachable · squeue: error: end␚$"'
	done
	# the edges of Unicode's Table 3-7, where a second byte outside the lead's
	# range makes the lead no character: an overlong 3-byte form, a surrogate, an
	# overlong 4-byte form, one above U+10FFFF, each next to its valid neighbour
	local row bad good marks
	for row in '\xe0\x80\x80:\xe0\xa0\x80' '\xed\xa0\x80:\xed\x9f\xbf' \
	           '\xf0\x80\x80\x80:\xf0\x90\x80\x80' '\xf4\x90\x80\x80:\xf4\x8f\xbf\xbf'; do
		IFS=: read -r bad good <<< "$row"
		marks=${bad//\\x??/␚}                        # each byte is its own broken piece
		sq_run "$(stderr_fixture squeue "a${bad}b${good}c")" --
		need "$bad then $good on squeue's stderr: rc 0, stderr empty, '$marks' then the character" \
			eval 'rc_is 0 && err_empty && utf8_valid && lines_matching "⚠ slurm unreachable" | grep -qxF "  ⚠ slurm unreachable · squeue: error: a${marks}b$(printf "$good")c"'
	done
	sq_run wide -- -u "$(printf 'end\xf0\x9f\x98')"
	need "-u ending in a halved 😀: rc 0, stderr empty, the caption says user=end␚" \
		eval 'rc_is 0 && err_empty && utf8_valid && has "recently finished · last 2h · user=end␚"'
	sq_run "$(stderr_fixture squeue 'a␚b\xef\xbf\xbdc')" --
	need "a genuine ␚ and U+FFFD in squeue's stderr: rc 0, stderr empty, both kept, 'a␚b�c'" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: a␚b�c$"'
	sq_run wide -- -u 'a␚b�c'
	need "a genuine ␚ and U+FFFD in -u: rc 0, the caption says user=a␚b�c" eval 'rc_is 0 && err_empty && has "recently finished · last 2h · user=a␚b�c"'
}

# The scrub reads a text once, whatever it holds, so its work grows with the
# length alone: 100 KB of nested C1 pairs held the old one, which looped, for
# 30s.  It keeps 4096 characters, counted once decoded, so a character is never
# halved: each half pair that is no UTF-8 counts as its ␚.
raw_stderr_fixture() {   # raw_stderr_fixture NAME GAWK-PRINT: "wide" whose squeue fails with these raw bytes on stderr
	local d; d=$(stderr_fixture squeue x); mv "$d" "$d-$1"; d=$d-$1
	{ printf '@stderr squeue: error: '; LC_ALL=C gawk "BEGIN { $2 }"; printf '\n@exit 1\n'; } > "$d/squeue"
	printf '%s' "$d"
}
c_scrub_bounded() {
	T_TITLE="100 KB of nested C1 pairs on squeue's stderr: sq answers within seconds, a ␚ for each half; a cut never halves a character"
	local t0
	t0=$SECONDS
	sq_run "$(raw_stderr_fixture deep 'for (i=0; i<50000; i++) printf "\302"; for (i=0; i<50000; i++) printf "\233"')" --
	need "50000 pairs nested: rc 0 within 10s, stderr empty (no gawk warning), ␚s on the banner" \
		eval 'rc_is 0 && [ $((SECONDS - t0)) -lt 10 ] && err_empty && utf8_valid && matches "^  ⚠ slurm unreachable · squeue: error: ␚␚␚␚"'
	sq_run "$(raw_stderr_fixture tail 'for (i=0; i<2000; i++) printf "\302"; for (i=0; i<2000; i++) printf "\233"; for (i=0; i<96000; i++) printf "x"')" --
	need "2000 pairs nested, then text: rc 0, stderr empty, a ␚ for each outer half on the banner, no C1" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: ␚␚␚␚" && c1_inert'
	sq_run "$(raw_stderr_fixture halved 'for (i=0; i<3000; i++) printf "\303\251"')" --
	need "3000 é, 6000 bytes: rc 0, stderr empty (no invalid UTF-8 for gawk), é on the banner" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: éééé"'
}

# What the scrub keeps is counted in characters once decoded, so a run of
# controls ahead of a message cannot push it out: past 4 KiB of them the banner
# lost it (and then made up "squeue failed (exit 1)").  The 4096 also keep a long
# text within what Linux takes as an environment string, which is how gawk gets
# it: past 128 KiB exec failed with E2BIG, exit 126, no screen, the temp dir
# left behind.  The four sites that echo a value keep 40 characters, not bytes;
# the others 4096, seen whole only on the title, which draws the host name in full.
tmp_left() { [ -n "$(ls -A "$RUN/tmp")" ]; }     # sq's temp dir outlived it
since_given() {   # the -S value of sacct's first call, as sacct got it
	local -a w; local i
	eval "w=($(gawk -F'\t' '$1 == "CALL" && $2 == "sacct" { print $3; exit }' "$LOG"))"
	for ((i = 0; i + 1 < ${#w[@]}; i++)); do [ "${w[i]}" != -S ] || { printf '%s' "${w[i+1]}"; return; }; done
}
c_scrub_counts() {
	T_TITLE="the scrub counts characters once decoded: controls ahead of a message never push it out, long texts draw, the echoes keep 40 characters, the rest 4096"
	local m name bytes n u p c50 c40 c38 c14 x38 u50 host hbin=$T_DIR/hbin
	for m in 'cr5000 \r 5000' 'esc \033 4100' 'csi2100 \302\233 2100'; do
		read -r name bytes n <<< "$m"
		sq_run "$(raw_stderr_fixture "$name" "for (i=0; i<$n; i++) printf \"$bytes\"; printf \"the real message\"")" --
		need "$name ahead of the message: rc 0, stderr empty, the real message on the banner" \
			eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: the real message$"'
	done
	sq_run "$(raw_stderr_fixture long 'for (i=0; i<100000; i++) printf "\303\251"')" --
	need "a 200 KB line of é on squeue's stderr: rc 0, stderr empty, drawn, no temp dir left" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: éééé" && footer_unknown && ! tmp_left'
	u=$(printf 'u%.0s' {1..70000}); p=$(printf 'p%.0s' {1..70000})
	sq_run wide -- -u "$u" -p "$p"
	need "-u and -p of 70 KB each: rc 0, stderr empty, drawn, no temp dir left" \
		eval 'rc_is 0 && err_empty && calls_are 1 1 0 1 && has "recently finished · last 2h · user=uuuu" && ! tmp_left'
	c14=$(printf '中%.0s' {1..14}); c38=$(printf '中%.0s' {1..38}); c40=$c38中中; c50=$(printf '中%.0s' {1..50})
	x38=$(printf 'x%.0s' {1..38})
	sq_run wide SQ_SINCE="$c14" --
	need "SQ_SINCE of 14 中, 42 bytes: rc 0, stderr empty (no gawk warning), all 14 on the caption and to sacct" \
		eval 'rc_is 0 && err_empty && has "recently finished · since $c14" && [ "$(since_given)" = "$c14" ]'
	sq_run wide SQ_SINCE="$c50" --
	need "SQ_SINCE of 50 中: rc 0, stderr empty, sacct -S gets the first 40" \
		eval 'rc_is 0 && err_empty && [ "$(since_given)" = "$c40" ]'
	sq_run wide -- -u "-${x38}éyyyy"
	need "-u -xxx…xé…: refused, the value cut at 40 characters, é whole" \
		eval 'rc_is 2 && grep -qF "not '"'"'-${x38}é'"'"';" "$ERR" && err_utf8_valid'
	sq_run wide -- --reserve "$c50"
	need "--reserve of 50 中: refused, the value cut at 40 characters" eval 'rc_is 2 && grep -qF "not '"'"'$c40'"'"';" "$ERR"'
	sq_run wide -- --reserve "${c14}"$'\n'"$c50"
	need "--reserve of 14 中, a newline, 50 中: refused, 40 中 echoed, the newline gone" eval 'rc_is 2 && grep -qF "not '"'"'$c40'"'"';" "$ERR"'
	sq_run wide -- "--$c50"
	need "--中… of 52 characters: refused, echoed cut at 40" eval 'rc_is 2 && grep -qF "sq: --$c38 is not one" "$ERR"'
	u50=$(printf 'u%.0s' {1..50}); host=$(printf 'h%.0s' {1..5000})
	sq_run wide -- -u "$u50"
	need "-u of 50 characters: rc 0, all 50 on the caption" eval 'rc_is 0 && has "recently finished · last 2h · user=$u50"'
	mkdir -p "$hbin"; printf '#!/bin/sh\nprintf "%%s\\n" %q\n' "$host" > "$hbin/hostname"; chmod +x "$hbin/hostname"
	sq_run wide PATH="$hbin:$here/bin:$PATH" --
	need "a host name of 5000 characters: rc 0, the title shows 4096 of them" eval 'rc_is 0 && plain | head -1 | grep -qF "SLURM ${host:0:4096}  "'
}

# Of a collector's stderr only the first line is read, and only 1 MiB of it: a
# character that bound cuts in half goes, as the cut made it and not the
# collector, while bytes the collector left unfinished right there read ␚.
# Controls fill the line, as they are never shown, so the cut lands in sight.
c_scrub_read_bound() {
	T_TITLE="a stderr line past 1 MiB: read up to 1 MiB, a character the bound halves dropped without a ␚, the message before it shown"
	local pad=$((1048576 - 31))      # "squeue: error: the real message" is 31 bytes
	sq_run "$(raw_stderr_fixture halved "printf \"the real message\"; for (i=0; i<$pad-2; i++) printf \"\\r\"; printf \"\\344\\270\\255tail\"")" --
	need "中 across the bound: rc 0, stderr empty, dropped, no ␚, the message shown" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: the real message$"'
	sq_run "$(raw_stderr_fixture halved4 "printf \"the real message\"; for (i=0; i<$pad-3; i++) printf \"\\r\"; printf \"\\360\\237\\230\\200tail\"")" --
	need "😀 across the bound, 3 of its 4 bytes within: rc 0, stderr empty, dropped, no ␚, the message shown" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: the real message$"'
	sq_run "$(raw_stderr_fixture whole "printf \"the real message\"; for (i=0; i<$pad-3; i++) printf \"\\r\"; printf \"\\344\\270\\255tail\"")" --
	need "中 ending on the bound: rc 0, stderr empty, 中 kept, nothing after it" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: the real message中$"'
	sq_run "$(raw_stderr_fixture own "printf \"the real message\"; for (i=0; i<$pad-1; i++) printf \"\\r\"; printf \"\\344tail\"")" --
	need "a lone lead byte, the last within the bound, not continued: rc 0, stderr empty, its ␚ shown" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: the real message␚$"'
	sq_run "$(raw_stderr_fixture ascii "printf \"the real message\"; for (i=0; i<$pad-1; i++) printf \"\\r\"; printf \"xtail\"")" --
	need "ASCII only: rc 0, stderr empty, the byte on the bound kept, the one past it not" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: the real messagex$"'
}

# Fed from a pipe, the scrub reads to the end, past what it keeps: a writer
# meeting a closed pipe dies of SIGPIPE, or, where SIGPIPE is ignored (a caller
# may leave it so, and every child inherits it), says "Broken pipe" on sq's
# stderr.  Many lines, so the end is not read with the first one.
c_scrub_sigpipe() {
	T_TITLE="SIGPIPE ignored: a scrub fed long many-line text from a filter, a usage error and a stderr file leaves sq's stderr clean"
	local real=$sq line u d i
	local sq=$T_DIR/sq-nopipe       # what sq_run runs, here and only here
	printf '#!/usr/bin/env bash\ntrap "" PIPE\nexec %q "$@"\n' "$real" > "$sq"; chmod +x "$sq"
	line=$(printf 'u%.0s' {1..99}); u=$(for i in {1..1200}; do printf '%s\n' "$line"; done)
	sq_run wide -- -u "$u" -p "${u//u/p}"
	need "-u and -p of 1200 lines each: rc 0, stderr empty, drawn" eval 'rc_is 0 && err_empty && calls_are 1 1 0 1 && has "user=uuuu"'
	sq_run wide -- -u "-$u"
	need "-u -… of 1200 lines: refused, the one line of sq's on stderr" eval 'rc_is 2 && [ "$(wc -l < "$ERR")" -eq 1 ] && grep -q "^sq: -u needs a user name" "$ERR"'
	d=$(stderr_fixture squeue x)
	{ printf '@stderr squeue: error: the first line\n'; for i in {1..3000}; do printf '@stderr %s\n' "$line"; done; printf '@exit 1\n'; } > "$d/squeue"
	sq_run "$d" --
	need "squeue's stderr of 3000 lines: rc 0, stderr empty, the first line on the banner" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: the first line$"'
}

# The scrub's stream mode (scrub -s), which every answer of Slurm's that holds
# a byte above 127 passes before it is read, run on its own (cut out of sq
# between "the scrub" and "scrub end"): it changes no ASCII byte and moves
# none, so S(x a y) = S(x) a S(y) for any ASCII byte a, checked on random lines
# of broken pieces, bidi controls and their neighbours, controls and NUL; each
# broken piece reads one ␚ and the 12 bidi controls go, as whole characters,
# also from the normal mode, while their neighbours stay.  Then a job name
# holding \001 and \002 around a Latin-1 byte, which the pass must not take for
# its own marks: the table reads a?␚?b.
scrub_is() {   # scrub_is IN OUT [ARG...]: printf IN through scrub ARG... gives printf OUT
	cmp -s <(printf "$1" | scrub "${@:3}") <(printf "$2")
}
c_scrub_stream() {
	T_TITLE="scrub -s: no ASCII byte changed or moved (S(x a y) = S(x) a S(y)), a ␚ per broken piece, the 12 bidi controls dropped as characters (also by the normal scrub), their neighbours kept; \\001 \\002 survive: a job name a\\001\\xe9\\002b reads a?␚?b"
	local d=$T_DIR/fx-marks in=$T_DIR/prop.in out=$T_DIR/prop.out bytes=$T_DIR/prop.a
	eval "$(sed -n '/^# ---- the scrub/,/^# ---- scrub end/p' "$sq")"
	need "the scrub is cut out of sq" eval '[ "$(type -t scrub)" = function ] && [ -n "${chars_awk-}" ]'
	# 3000 triples x, y, x a y: random tokens, no newline (a line is the unit)
	LC_ALL=C gawk -v n=3000 -v afile="$bytes" 'BEGIN {
		srand(20261024)
		nt = split("\330\234|\342\200\216|\342\200\217|\342\200\252|\342\200\253|\342\200\254|\342\200\255|\342\200\256|\342\201\246|\342\201\247|\342\201\250|\342\201\251|" \
		  "\342\200\247|\342\200\250|\342\200\251|\342\200\257|\342\201\245|\342\200\215|\357\273\277|\302\233|\302\200|\302\237|\303\251|\360\237\221\250|" \
		  "\340\200\256|\300\256|\360\202\200\256|\355\240\200|\342\200|\342|\200\256|\342\220\232|N0123abc|\001|\002|\r|\000", T, "|")
		for (i = 0; i < 256; i++) B[i] = sprintf("%c", i)
		for (k = 0; k < n; k++) {
			x = rnd(); y = rnd(); do a = int(rand() * 128); while (a == 10)
			printf "%s\n%s\n%s%s%s\n", x, y, x, B[a], y; print a > afile
		}
	}
	function rnd(   s, m, j, b) {
		m = int(rand() * 9)
		for (j = 0; j < m; j++) {
			if (rand() < 0.5) s = s T[int(rand() * nt) + 1]
			else { do b = int(rand() * 256); while (b == 10); s = s B[b] }
		}
		return s
	}' > "$in"
	scrub -s < "$in" > "$out"
	need "3000 random triples: S(x a y) = S(x) a S(y), line for line" eval '
		LC_ALL=C gawk -v afile="$bytes" "NR % 3 == 1 { x = \$0; next } NR % 3 == 2 { y = \$0; next }
			{ getline a < afile; if (\$0 != x sprintf(\"%c\", a) y) bad++ } END { exit bad || NR != 9000 }" "$out"'
	need "the ASCII bytes of the output are the input's, in order" \
		eval 'cmp -s <(LC_ALL=C tr -d "\200-\377" < "$in") <(LC_ALL=C tr -d "\200-\377" < "$out")'
	need "the output is valid UTF-8 (NUL aside)" eval 'LC_ALL=C tr -d "\000" < "$out" > "$out.nonul"; OUT=$out.nonul utf8_valid'
	need "-s: each of the 12 bidi controls goes, the newline stays" \
		scrub_is 'a\330\234b\342\200\216c\342\200\217d\342\200\252e\342\200\253f\342\200\254g\342\200\255h\342\200\256i\342\201\246j\342\201\247k\342\201\250l\342\201\251m\n' 'abcdefghijklm\n' -s
	need "the normal scrub: each of the 12 goes too" \
		scrub_is 'a\330\234b\342\200\216c\342\200\217d\342\200\252e\342\200\253f\342\200\254g\342\200\255h\342\200\256i\342\201\246j\342\201\247k\342\201\250l\342\201\251m\n' 'abcdefghijklm'
	need "-s and normal: ZWJ emoji, U+2028, U+2029, U+FEFF, U+202F, U+2065 kept" eval '
		scrub_is "\360\237\221\251\342\200\215\360\237\222\273 \342\200\250\342\200\251\357\273\277\342\200\257\342\201\245\n" "\360\237\221\251\342\200\215\360\237\222\273 \342\200\250\342\200\251\357\273\277\342\200\257\342\201\245\n" -s &&
		scrub_is "\360\237\221\251\342\200\215\360\237\222\273 \342\200\250\342\200\251\357\273\277\342\200\257\342\201\245\n" "\360\237\221\251\342\200\215\360\237\222\273 \342\200\250\342\200\251\357\273\277\342\200\257\342\201\245"'
	need "-s: a bidi control inside a broken piece joins nothing (E2 80 [RLO] AE reads ␚␚), an overlong one is 3 ␚" eval '
		scrub_is "\342\200\342\200\256\256\n" "␚␚\n" -s && scrub_is "\340\200\256\n" "␚␚␚\n" -s && scrub_is "\342\200\342\200\256\256" "␚␚"'
	need "-s: the input's \\001 and \\002 survive beside broken and whole characters" eval '
		scrub_is "a\001\351\002b\n" "a\001␚\002b\n" -s && scrub_is "\001\303\251\002\001\n" "\001\303\251\002\001\n" -s'
	need "-s: NUL passes, a last line without a newline gets none" scrub_is 'a\000\351b' 'a\000␚b' -s
	need "-s: C1 stays (the tables' own rule reads it), the normal scrub drops it" eval '
		scrub_is "x\302\233y\n" "x\302\233y\n" -s && scrub_is "x\302\233y\n" "xy"'
	need "-s: CR and controls stay, a newline ends a piece" eval '
		scrub_is "a\351\r\n" "a␚\r\n" -s && scrub_is "\342\n\200\256\n" "␚\n␚␚\n" -s && scrub_is "a\033[2J\tb\n" "a\033[2J\tb\n" -s'
	need "the normal scrub counts MAX once the bidi controls are out" scrub_is 'a\342\200\256bcd' 'abc' 3
	mkdir -p "$d"
	printf '@include %s\n' "$fixtures/_common/sinfo-two-idle" > "$d/sinfo"
	printf '@include %s\n' "$fixtures/_common/empty" > "$d/sacct"
	printf '@include %s\ni=3001; j=a\\x01\\xe9\\x02b\n' "$fixtures/_common/squeue-defaults" > "$d/squeue"
	sq_run "$d" --
	need "a job name a\\001\\xe9\\002b: rc 0, stderr empty, valid UTF-8, the row reads a?␚?b" \
		eval 'rc_is 0 && err_empty && utf8_valid && rows queue | grep -qE "^ +3001 +a\?␚\?b +alice "'
}

# Slurm's own tables take the same rule as outside text (scrub -s on each
# answer): bytes that are no UTF-8 used to cut a name, made gawk warn on sq's
# stderr and reached the terminal raw, and a U+202E in a job name turned the
# rest of its row around.  Now each broken piece reads ␚ and the bidi controls
# go, in the queue, the nodes, a drain reason and the finished block, under a
# UTF-8 caller and under LC_ALL=C (whose gawk runs in C.UTF-8).
bidi_inert() {   # bidi_inert [FILE]: none of the 12 bidi controls in FILE, else stdout
	! LC_ALL=C grep -qE $'\330\234|\342\200[\216\217\252-\256]|\342\201[\246-\251]' "${1:-$OUT}"
}
c_tables_not_utf8() {
	T_TITLE="Latin-1 bytes and U+202E in a job name, a user, a node name, a drain reason and a finished job's name: M␚ller-run, b␚a, n␚ode02, the bidi controls gone, a ZWJ emoji kept, valid UTF-8, no gawk warning, columns aligned; under UTF-8 and LC_ALL=C"
	local l
	for l in "$utf8" C; do
		sq_run not-utf8 LC_ALL=$l -- --full
		need "$l: rc 0, stderr empty (no gawk warning), valid UTF-8, no bidi control" \
			eval 'rc_is 0 && err_empty && utf8_valid && bidi_inert && calls_are 1 1 0 1 && no_skips'
		need "$l: the queue rows: M␚ller-run, b␚a, ab-run of cd, the ZWJ emoji whole, n␚ode02" eval '
			rows queue | grep -qE "^ +3001 +M␚ller-run +alice " && rows queue | grep -qE "^ +3002 +ok-run +b␚a " &&
			rows queue | grep -qE "^ +3003 +ab-run +cd " && rows queue | grep -qE "^ +3004 +👩‍💻-run +alice " &&
			rows queue | grep -qE "^ +3005 +on-node .* n␚ode02$"'
		need "$l: USER, STATE and NODE/REASON line up" eval 'column_aligned USER && column_aligned STATE && column_aligned NODE/REASON'
		need "$l: the node n␚ode02, node03's reason 'disk ␚chec ok'" eval '
			matches "^ +n␚ode02 .* 1/32 +cpu .* mixed$" && plain | grep -A1 -E "^ +node03 " | tail -1 | grep -qE "^ +↳ disk ␚chec ok · since 2026-10-01$"'
		need "$l: the finished rows f␚nf and rlo" eval 'rows recent | grep -qE "^ +2001 +f␚nf +COMPLETED " && rows recent | grep -qE "^ +2002 +rlo +COMPLETED "'
	done
}
# The pass costs a gawk only where an answer has a byte above 127: grep says
# so first (rc 1: none), so an ASCII screen starts no scrub (counted by a gawk
# first on PATH that logs each call with -v stream=1).  A cut stream is still
# cut once a broken byte is decoded: its record is never made whole.  Its work
# is linear (CPU time, as the suite may run under load).
gawk_wrapper() {   # gawk_wrapper DIR LOG: DIR/gawk, the real one, logging "call LC_ALL" for each call, "stream" for a scrub -s
	local real; real=$(command -v gawk)
	mkdir -p "$1"
	printf '#!/bin/sh\nfor a; do [ "$a" != stream=1 ] || echo stream >> %q; done\necho "call ${LC_ALL-}" >> %q\nexec %q "$@"\n' "$2" "$2" "$real" > "$1/gawk"
	chmod +x "$1/gawk"
}
cpu_secs() {   # cpu_secs CMD...: the CPU seconds (user + sys) CMD took, children included
	local TIMEFORMAT='%3U %3S' t
	t=$( { time "$@" > /dev/null 2>&1; } 2>&1 )
	gawk -v t="$t" 'BEGIN { split(t, a, " "); printf "%.3f", a[1] + a[2] }'
}
c_tables_pass_cost() {
	T_TITLE="the pass: no scrub where an answer is ASCII (grep alone), one where it is not; a cut queue with a broken byte still 'queue output incomplete'; 27 MB of 100k rows with a broken byte each and a 1 MB line of \\xfc each within 1 s CPU"
	local gbin=$T_DIR/gbin glog=$T_DIR/gawk.log d=$T_DIR/fx-cut big=$T_DIR/big t
	gawk_wrapper "$gbin" "$glog"
	: > "$glog"; sq_run mixed PATH="$gbin:$here/bin:$PATH" --
	need "an ASCII screen: rc 0, gawk ran, no scrub -s" eval 'rc_is 0 && err_empty && grep -q call "$glog" && ! grep -q stream "$glog"'
	: > "$glog"; sq_run not-utf8 PATH="$gbin:$here/bin:$PATH" --
	need "not-utf8: rc 0, a scrub -s for each answer with a high byte (sinfo, squeue, sacct; nodes JSON is made from sinfo)" \
		eval 'rc_is 0 && err_empty && [ "$(grep -c stream "$glog")" -ge 3 ]'
	mkdir -p "$d"
	printf '@include %s\n' "$fixtures/busy24/sacct" > "$d/sacct"; printf '@include %s\n' "$fixtures/busy24/sinfo" > "$d/sinfo"
	printf '@include %s\n@raw 4999\\x00M\\xfcller\n' "$fixtures/busy24/squeue" > "$d/squeue"
	sq_run "$d" --
	need "a queue cut in a record holding a Latin-1 byte: 'queue output incomplete', footer ? jobs" \
		eval 'rc_is 0 && err_empty && has "⚠ queue output incomplete" && footer_unknown'
	eval "$(sed -n '/^# ---- the scrub/,/^# ---- scrub end/p' "$sq")"
	LC_ALL=C gawk 'BEGIN { for (i = 0; i < 100000; i++) printf "%06d|M\374ller-run|%0255d|%0010d\n", i, 0, i }' > "$big"
	t=$(cpu_secs scrub -s < "$big")
	need "27 MB, 100k rows, a broken byte each: within 1 s CPU ($t s), a ␚ each" eval '
		[ "$(wc -c < "$big")" -gt 27000000 ] && gawk -v t="$t" "BEGIN { exit !(t < 1) }" && [ "$(scrub -s < "$big" | LC_ALL=C grep -c "|M␚ller-run|")" = 100000 ]'
	LC_ALL=C gawk 'BEGIN { for (i = 0; i < 1048576; i++) printf "\374"; printf "\n" }' > "$big"
	t=$(cpu_secs scrub -s < "$big")
	need "a 1 MB line of \\xfc: within 1 s CPU ($t s), a ␚ each" eval '
		gawk -v t="$t" "BEGIN { exit !(t < 1) }" && [ "$(scrub -s < "$big" | wc -c)" = $((1048576 * 3 + 1)) ]'
	rm -f "$big"
}
# C1 (U+0080-U+009F, \302\233 is CSI) is a whole character, which the pass
# keeps; the tables' control rule makes it "?" as it does C0, now in every
# locale: under a gawk in C (a host with no UTF-8 locale, made here by a
# locale tool that knows none) [[:cntrl:]] missed it, and a CSI in a job name
# reached the terminal raw.  As the rule acts after the names are compared,
# node\302\201 and node? stay two nodes.
c1_off() {   # c1_off [FILE]: no C1 character in FILE, else stdout
	! LC_ALL=C grep -q $'\302[\200-\237]' "${1:-$OUT}"
}
c_tables_c1() {
	T_TITLE="C1 in a job name, a drain reason and a node name reads ? under UTF-8 and under a gawk in C; node\\302\\201 and node? stay two nodes"
	local d=$T_DIR/fx-c1 gbin=$T_DIR/gbin nobin=$T_DIR/nobin glog=$T_DIR/gawk.log loc
	mkdir -p "$d" "$nobin"
	gawk_wrapper "$gbin" "$glog"
	no_utf8_locale "$nobin"
	printf '@include %s\n' "$fixtures/_common/empty" > "$d/sacct"
	printf '@include %s\ni=3001; j=a\\xc2\\x9b2Jb\n' "$fixtures/_common/squeue-defaults" > "$d/squeue"
	{ printf '@include %s\n' "$fixtures/_common/sinfo-two-idle"
	  printf 'CPUsState=0/0/32/32; NodeList=node03; FreeMem=121000; Memory=128000; StateLong=drained; Reason=x\\xc2\\x9b2Jy; TimeStamp=2026-10-01T12:00:00; CPUsLoad=0.00; AllocMem=0\n'
	  printf 'CPUsState=0/32/0/32; NodeList=node\\xc2\\x81; FreeMem=120000; Memory=128000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.01; AllocMem=0\n'
	  printf 'CPUsState=0/32/0/32; NodeList=node?; FreeMem=120000; Memory=128000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.01; AllocMem=0\n'; } > "$d/sinfo"
	for loc in utf8 C; do
		: > "$glog"
		if [ $loc = utf8 ]; then sq_run "$d" PATH="$gbin:$here/bin:$PATH" -- --full
		else sq_run "$d" LC_ALL=C PATH="$gbin:$nobin:$here/bin:$PATH" -- --full; fi
		need "$loc: rc 0, stderr empty, no C1 on the screen" eval 'rc_is 0 && err_empty && c1_off'
		need "$loc: the job name a?2Jb, the reason x?2Jy" eval '
			rows queue | grep -qE "^ +3001 +a\?2Jb +alice " && plain | grep -A1 -E "^ +node03 " | tail -1 | grep -qE "^ +↳ x\?2Jy · since 2026-10-01$"'
		need "$loc: node\\302\\201 and node? two nodes" eval '[ "$(plain | grep -cE "^ +node\? ")" = 2 ]'
	done
	need "C: every gawk ran in C, none in a UTF-8 locale" eval 'grep -qx "call C" "$glog" && ! grep -qi "utf" "$glog"'
}

# ---- display width: the table, the cut ---------------------------------------
# sq counts columns, not characters, by one table embedded in it: a list of
# hex ranges of width 0 or 2 (every other code point 1), from which both
# modes build their classes, a bracket of the characters under UTF-8 and
# alternations of their UTF-8 bytes under C (no UTF-8 locale).  The helpers
# as sq has them, cut out of it: the node readers (json_bytes, the bytes from
# octal escapes) and wide_awk
wide_awk_file() {   # wide_awk_file FILE
	{ sed -n '/^# ---- the node readers/,/^# ---- node readers end/p' "$sq"
	  sed -n "/^wide_awk='\$/,/^'\$/p" "$sq" | sed '1d;$d'; } > "$1"
}
# every scalar value as "HEX WIDTH", encoded by this program itself (its own
# octal escapes, not sq's encoder) and measured by sq's colw
allcp_awk='BEGIN {
	split("\200,\201,\202,\203,\204,\205,\206,\207,\210,\211,\212,\213,\214,\215,\216,\217,\220,\221,\222,\223,\224,\225,\226,\227,\230,\231,\232,\233,\234,\235,\236,\237," \
	      "\240,\241,\242,\243,\244,\245,\246,\247,\250,\251,\252,\253,\254,\255,\256,\257,\260,\261,\262,\263,\264,\265,\266,\267,\270,\271,\272,\273,\274,\275,\276,\277," \
	      "\300,\301,\302,\303,\304,\305,\306,\307,\310,\311,\312,\313,\314,\315,\316,\317,\320,\321,\322,\323,\324,\325,\326,\327,\330,\331,\332,\333,\334,\335,\336,\337," \
	      "\340,\341,\342,\343,\344,\345,\346,\347,\350,\351,\352,\353,\354,\355,\356,\357,\360,\361,\362,\363,\364,\365,\366,\367", b, ",")
	for (i = 1; i <= 120; i++) B[127 + i] = b[i]
	for (cp = 0; cp < 1114112; cp++) {
		if (cp >= 55296 && cp <= 57343) continue
		if (cp < 128) c = sprintf("%c", cp)
		else if (cp < 2048) c = B[192 + int(cp / 64)] B[128 + cp % 64]
		else if (cp < 65536) c = B[224 + int(cp / 4096)] B[128 + int(cp / 64) % 64] B[128 + cp % 64]
		else c = B[240 + int(cp / 262144)] B[128 + int(cp / 4096) % 64] B[128 + int(cp / 64) % 64] B[128 + cp % 64]
		printf "%X %d\n", cp, colw(c)
	}
}'
# (a) for every scalar value sq's width in UTF-8 and in C is the list's, as
# python3 reads it (the machinery: brackets, byte patterns, the lookup);
# (b) tests/width_table.py, run on this host's glibc and python's
# unicodedata, leaves the list as it is, so sq never counts less than the
# local wcwidth or Unicode's width: on a mismatch the code points it would
# change; where the list records this host's glibc alone and this
# unicodedata's version, the list must equal what they make exactly, so a
# stray entry wider than that fails too; with a unicodedata older than the
# list's Unicode, glibc and the fixed set alone, said so.  An empty list builds no class ("" would match
# everywhere, "[]" is no regex), and every glyph of sq's own, which the
# UTF-8 fast path counts by length(), is 1 in the list
c_width_table() {
	T_TITLE="the width table: sq's width of every scalar value, in UTF-8 and in C, is the embedded list's as python3 reads it; tests/width_table.py leaves the list unchanged on this host; an empty list builds no class; sq's glyphs are 1"
	local awk=$T_DIR/wide.awk mode out chk=$T_DIR/check.out rc
	sq_run mixed --
	need "the dashboard: rc 0" rc_is 0
	if ! command -v python3 > /dev/null 2>&1; then
		T_FAIL+=("python3 is missing: the width table is checked by tests/width_table.py (python3, with ctypes and unicodedata)"); return
	fi
	wide_awk_file "$awk"
	for mode in "$utf8" C; do
		out=$T_DIR/widths.$mode
		LC_ALL=$mode gawk -f "$awk" -e "$allcp_awk" > "$out" 2> "$out.err"
		python3 -I "$here/width_table.py" lookup "$sq" < "$out" > "$out.cmp" 2>&1; rc=$?
		need "(a) $mode: every scalar value as the list says ($(tail -n 1 "$out.cmp"))$([ $rc = 0 ] || printf ': %s' "$(head -n 20 "$out.cmp" | paste -sd';')")" \
			eval '[ $rc = 0 ] && [ ! -s "$out.err" ]'
	done
	python3 -I "$here/width_table.py" check "$sq" "$utf8" > "$chk" 2>&1; rc=$?
	need "(b) tests/width_table.py check: the list unchanged ($(tail -n 1 "$chk"))$([ $rc = 0 ] || printf ': %s' "$(head -n 40 "$chk" | paste -sd';')")" eval '[ $rc = 0 ]'
	! grep -q 'not checked' "$chk" || T_TITLE="$T_TITLE; $(grep 'not checked' "$chk")"
	for mode in "$utf8" C; do
		need "$mode: an empty list builds no class, and a CJK character with a combining mark is 1 + 1 + 1" eval '
			LC_ALL=$mode gawk -f "$awk" -e "BEGIN { WIDTHS = \"\"; width_classes(); exit !(W_WIDE == \"\" && W_ZERO == \"\" && colw(\"a中\314\201\") == 3) }" 2> "$T_DIR/empty.err" && [ ! -s "$T_DIR/empty.err" ]'
	done
	need "C, which has no fast path: each of sq's glyphs · … × ↳ █ ⚠ ␚ ▒ ▌ ▓ ░ ≥ → is 1" eval '
		LC_ALL=C gawk -f "$awk" -e "BEGIN { n = split(\"· … × ↳ █ ⚠ ␚ ▒ ▌ ▓ ░ ≥ →\", G, \" \"); for (i = 1; i <= n; i++) if (colw(G[i]) != 1) exit 1; exit n != 13 }"'
}

# The cut (W4): clip(s, cols) is s when it fits; "…" when cols <= 1 (1
# column even at cols <= 0); else whole units of at most cols - 1 columns,
# then "…" and nothing after it: cols - g wide, 0 <= g < the width of the
# first unit left out.  A unit starts at every character but a 0-width one,
# U+FE0F, an emoji modifier and the one after a ZWJ.  Checked on random
# strings of CJK, kana, Hangul, emoji, marks, ZWJ, VS16, modifiers, regional
# indicators and ASCII, at every cols from -1 to 2 past their width, in UTF-8
# and in C, measured by the oracle, the units by this rule written here again
clip_check_awk='
BEGIN { FS = "\t" }
{	c = $1; s = $2; x = $3
	if (length(cellify(s)) <= c) { if (x != s) bad("fits, yet changed"); next }
	if (c <= 1) { if (x != "…") bad("cols <= 1, not \"…\""); next }
	if (substr(x, length(x)) != "…") { bad("no \"…\" at its end"); next }
	p = substr(x, 1, length(x) - 1)
	if (index(s, p) != 1) { bad("not a start of the string, then \"…\""); next }
	nu = units(s, U, UW); wp = 0
	for (j = 1; j <= nu && U[j] - 1 < length(p); j++) wp += UW[j]
	if (j > nu || U[j] - 1 != length(p)) { bad("a unit split"); next }
	if (wp + 1 > c) bad("over cols")
	g = c - (wp + 1); if (g < 0 || g >= UW[j]) bad("g = " g ", the unit left out " UW[j] " wide")
}
function bad(why) { if (++nbad <= 5) printf "%s at cols %d: %s -> %s\n", why, c, s, x > "/dev/stderr" }
END { exit nbad > 0 }'
c_wide_clip() {
	T_TITLE="clip by columns, UTF-8 and C: never over cols (cols >= 1), \"…\" at cols <= 1, the text up to \"…\" cols - g wide with 0 <= g < the first unit left out, whole units only, nothing after \"…\"; 600 random strings at every cols"
	local awk=$T_DIR/wide.awk strs=$T_DIR/strings mode
	sq_run mixed --
	need "the dashboard: rc 0" rc_is 0
	wide_awk_file "$awk"
	LC_ALL=$utf8 gawk 'BEGIN {
		srand(20261024)
		n = split("中 文 名 前 あ カ 한 글 😀 👍 👨 👩 👧 ⚠ ☺ é ü \314\201 \314\210 \342\200\215 \357\270\217 \360\237\217\275 \360\237\217\273 \360\237\207\251 \360\237\207\252 a b c - _ / · …", T, " ")
		for (k = 0; k < 600; k++) { m = 1 + int(rand() * 12); s = ""; for (j = 0; j < m; j++) s = s T[1 + int(rand() * n)]; print s }
	}' > "$strs"
	oracle_fill "$strs"
	for mode in "$utf8" C; do
		LC_ALL=$mode gawk -f "$awk" -e '{ s = $0; for (c = -1; c <= colw(s) + 2; c++) printf "%d\t%s\t%s\n", c, s, clip(s, c) }' "$strs" > "$T_DIR/cuts.$mode"
		need "$mode: every cut as W4 says$(ORACLE_MAP=$work/oracle.map LC_ALL=$utf8 gawk "$oracle_awk$unit_awk$clip_check_awk" "$T_DIR/cuts.$mode" 2> "$T_DIR/cuts.err" || printf ': %s' "$(paste -sd'|' "$T_DIR/cuts.err")")" \
			eval '[ ! -s "$T_DIR/cuts.err" ] && [ "$(wc -l < "$T_DIR/cuts.$mode")" -gt 6000 ]'
	done
}
# the units of S by W4, measured by the oracle: unit J starts at character
# U[J] and is UW[J] columns; their count
unit_awk='
function units(s, U, UW,   n, C, i, nu) {
	n = split(s, C, ""); nu = 0
	for (i = 1; i <= n; i++) {
		if (i == 1 || !(OW[C[i]] == 0 && C[i] !~ /^[\001-\177]$/ || C[i] == "\357\270\217" || (C[i] >= "\360\237\217\273" && C[i] <= "\360\237\217\277") || C[i - 1] == "\342\200\215"))
			{ U[++nu] = i; UW[nu] = 0 }
		UW[nu] += (C[i] ~ /^[\001-\177]$/) ? 1 : OW[C[i]]
	}
	return nu
}'

# ---- display width: a wide screen against its ASCII twin (AC1) --------------
# A twin is the same fixture with every outside string beyond ASCII, as sq
# sees it, replaced by a distinct ASCII string of the same oracle width, so sq
# lays both out alike: every line as wide, every column at the same place.
# The twin keeps each ASCII character of the string but its letters in its
# column (digits and the ends of words, which WHOLE's guard reads, H8) and
# writes an id unique to the string (a-w) over its first letters and columns
# beyond ASCII, then each letter as it is and each other column as x.  The map
# (orig TAB twin) is the case's own, $T_DIR/twin.map; twin_of STRING prints a
# string's twin, twin_fx NAME... makes $T_DIR/twin-NAME of each fixture (an
# @include of another fixture than _common reads its twin)
twin_awk='
BEGIN {
	mapf = ENVIRON["TWIN_MAP"]
	while ((getline ln < mapf) > 0) { t = index(ln, "\t"); TW[substr(ln, 1, t - 1)] = substr(ln, t + 1); USED[substr(ln, t + 1)] }
	close(mapf)
}
function twin(s,   n, C, i, slots, id, k, j, t) {
	if (s !~ /[^\001-\177]/) return s
	if (s in TW) return TW[s]
	n = split(cellify(s), C, "")                  # a column each: a wide character and its filler
	for (i = 1; i <= n; i++) if (C[i] !~ /^[\001-\177]$/ || C[i] ~ /^[A-Za-z]$/) slots++
	k = 0
	do {
		id = ""; j = ++k
		while (j > 0) { id = substr("abcdefghijklmnopqrstuvw", (j - 1) % 23 + 1, 1) id; j = int((j - 1) / 23) }
		if (length(id) > slots) { print "twin: no twin of width " n " left for " s > "/dev/stderr"; exit 2 }
		t = ""; j = 0
		for (i = 1; i <= n; i++)                  # a letter or a column beyond ASCII: the id, then the letter, else x
			if (C[i] ~ /^[\001-\177]$/ && C[i] !~ /^[A-Za-z]$/) t = t C[i]
			else t = t ((++j <= length(id)) ? substr(id, j, 1) : (C[i] ~ /^[A-Za-z]$/) ? C[i] : "x")
	} while ((t in USED) || (t in ASCII))
	TW[s] = t; USED[t]; printf "%s\t%s\n", s, t >> mapf; close(mapf)
	return t
}'
twin_of() {   # twin_of STRING
	printf '%s\n' "$1" > "$T_DIR/twin.text"; oracle_fill "$T_DIR/twin.text"
	TWIN_MAP=$T_DIR/twin.map ORACLE_MAP=$work/oracle.map S=$1 LC_ALL=$utf8 gawk "$oracle_awk$twin_awk"' BEGIN { print twin(ENVIRON["S"]) }'
}
twin_fx() {   # twin_fx NAME...
	local name f
	for name; do
		mkdir -p "$T_DIR/twin-$name"
		for f in "$fixtures/$name"/*; do
			oracle_fill "$f"
			ASCIIFROM=$(printf '%s\n' "$fixtures/$name"/* "$fixtures"/_common/*) \
			TWIN_MAP=$T_DIR/twin.map ORACLE_MAP=$work/oracle.map FIXTURES=$fixtures TWINS=$T_DIR LC_ALL=$utf8 gawk "$oracle_awk$twin_awk"'
				BEGIN { nf = split(ENVIRON["ASCIIFROM"], FL, "\n")   # what a twin must not equal
					for (k = 1; k <= nf; k++) { while ((getline ln < FL[k]) > 0) { n = split(ln, F, ";")
						for (i = 1; i <= n; i++) { v = F[i]; sub(/^[^=]*=/, "", v); gsub(/^ +| +$/, "", v); if (v !~ /[^\001-\177]/) ASCII[v] } } close(FL[k]) } }
				/^[ \t]*(#|$)/ { print; next }
				/^@include \.\.\// { p = substr($0, 13); d = p; sub(/\/.*/, "", d)
					print "@include " (d == "_common" ? ENVIRON["FIXTURES"] "/" p : ENVIRON["TWINS"] "/twin-" p); next }
				/^@stderr / { print "@stderr " twin(substr($0, 9)); next }
				/^@/ && !/^@defaults / { print; next }
				{ pre = ""; s = $0; if (s ~ /^@defaults /) { pre = "@defaults "; s = substr(s, 11) }
				  n = split(s, F, ";"); out = ""
				  for (i = 1; i <= n; i++) {
					f = F[i]; eq = index(f, "=")
					if (!eq) { out = out (i > 1 ? ";" : "") f; continue }
					v = substr(f, eq + 1); lead = v; sub(/[^ ].*$/, "", lead); trail = v; sub(/^.*[^ ]/, "", trail)
					core = substr(v, length(lead) + 1, length(v) - length(lead) - length(trail))
					out = out (i > 1 ? ";" : "") substr(f, 1, eq) lead twin(core) trail
				  }
				  print pre out }' "$f" > "$T_DIR/twin-$name/${f##*/}"
		done
	done
}
# twin_check WIDE TWIN COLS LINES: two runs' screens (their OUT files), the
# wide one against its twin, by the oracle, escapes stripped: the widest
# line, the lines over COLS and the terminal rows (each line max(1,
# ceil(width / COLS))) no more than the twin's; each line as wide as the
# twin's, but one ending in a cut, which may be g narrower, 0 < g < the width
# of the first unit the cut left out of the original string (U1 (a): nothing
# after "…"), that string found where the twin has its twin; every
# left-aligned column of a table starting, every right-aligned one ending,
# at the same column on every row, and " cpu " and " mem " of every node
# line; where the twin fits COLS and LINES, the wide screen too.  Says what
# failed on stderr
twin_check() {
	local w=$1 t=$2
	OUT=$w cplain > "$w.cells"; OUT=$t cplain > "$t.cells"; OUT=$w plain > "$w.plain"
	TWIN_MAP=$T_DIR/twin.map ORACLE_MAP=$work/oracle.map WC=$w.cells TC=$t.cells WP=$w.plain COLS=$3 LINES=$4 LC_ALL=$utf8 gawk "$oracle_awk$unit_awk"'
	function rows_of(s) { return length(s) > COLS ? int((length(s) + COLS - 1) / COLS) : 1 }
	function bad(why) { if (++nbad <= 6) print why > "/dev/stderr" }
	function aligned(L, n,   i, r, nh, H, P, p, q, j, e, E, x, nx, RIGHT, k) {
		nx = split("CPU MIN_CPU NODES LEFT LIMIT TIME MEM PRIO Y EXIT ELAPSED AGO", x, " ")
		for (i = 1; i <= n; i++) {
			if (L[i] !~ /^ *[A-Z][A-Z\/_()]*( +[A-Z][A-Z\/_()]*)* *$/) continue
			nh = split(L[i], H, " "); p = 0; delete RIGHT
			for (j = 1; j <= nh; j++) { q = index(substr(L[i], p + 1), H[j]); P[j] = p + q; p = P[j] + length(H[j]) - 1
				for (k = 1; k <= nx; k++) if (index(x[k], H[j]) == 1) RIGHT[j]     # a header cut short too: ELAPSE
			}
			delete E
			for (r = i + 1; r <= n && L[r] != ""; r++) {
				if (L[r] ~ /^ *(…|↳|\+[0-9]+ more$)/) continue
				for (j = 1; j <= nh; j++) {
					q = (j < nh) ? P[j + 1] : length(L[r]) + 2
					if (j in RIGHT) {
						e = q - 1; while (e >= P[j] && substr(L[r], e, 1) == " ") e--
						if (e < P[j]) continue
						if (!(j in E)) E[j] = e; else if (E[j] != e) bad(sprintf("%s ends at %d, not %d: %s", H[j], e, E[j], L[r]))
					} else if (substr(L[r], P[j] - 1, 1) != " " && P[j] > 1 || substr(L[r], P[j], 1) == " " && substr(L[r], P[j], q - P[j]) !~ /^ *$/)
						bad(sprintf("%s does not start at %d: %s", H[j], P[j], L[r]))
				}
			}
		}
		for (i = 1; i <= n; i++) if (L[i] ~ / cpu .* mem /) {
			if (cpu == "") { cpu = index(L[i], " cpu "); mem = index(L[i], " mem ") }
			else if (index(L[i], " cpu ") != cpu || index(L[i], " mem ") != mem) bad("a node line off: " L[i])
		}
	}
	BEGIN {
		COLS = ENVIRON["COLS"] + 0; LINES = ENVIRON["LINES"] + 0
		while ((getline x < ENVIRON["WC"]) > 0) W[++nw] = x
		while ((getline x < ENVIRON["TC"]) > 0) T[++nt] = x
		while ((getline x < ENVIRON["WP"]) > 0) WP[++np] = x
		while ((getline x < ENVIRON["TWIN_MAP"]) > 0) { k = index(x, "\t"); ORIG[substr(x, k + 1)] = substr(x, 1, k - 1) }
		for (i = 1; i <= nw; i++) { l = length(W[i]); if (l > wmax) wmax = l; wover += (l > COLS); wrows += rows_of(W[i]) }
		for (i = 1; i <= nt; i++) { l = length(T[i]); if (l > tmax) tmax = l; tover += (l > COLS); trows += rows_of(T[i]) }
		if (wmax > tmax) bad("widest line " wmax ", the twin " tmax)
		if (wover > tover) bad(wover " lines over " COLS ", the twin " tover)
		if (wrows > trows) bad(wrows " terminal rows, the twin " trows)
		if (nw != nt) bad(nw " lines, the twin " nt)
		for (i = 1; i <= nw && i <= nt; i++) {
			lw = length(W[i]); lt = length(T[i])
			if (lw == lt) continue
			# a cut at the end, or inside the line (the finished line cuts the name, H7)
			if (lw > lt || WP[i] !~ /…/) { bad(sprintf("line %d: %d columns, the twin %d:\n  %s\n  %s", i, lw, lt, WP[i], T[i])); continue }
			u = (WP[i] ~ /…$/) ? left_out(i, lw) : left_out(i, index(W[i], "…"), 1)
			if (!(lt - lw < u)) bad(sprintf("line %d: %d short of the twin, the unit left out %d wide:\n  %s\n  %s", i, lt - lw, u, WP[i], T[i]))
		}
		aligned(W, nw)
		if (tmax <= COLS && trows <= LINES && !(wmax <= COLS && wrows <= LINES)) bad("the twin fits " COLS "x" LINES ", the wide screen not")
		exit nbad > 0
	}
	# the width of the first unit the cut of line I left out: at column B (the
	# text before "…" is B - 1 wide) the twin has the twin of string S, from
	# column ST; the unit of S at B - ST columns into it; 0 when none is found.
	# INNER: the cut inside the line, the twin read up to its own first "…"
	function left_out(i, b, inner,   t, tl, st, m, s, nu, U, UW, j, acc) {
		tl = T[i]; sub(/…$/, "", tl)
		if (inner && index(tl, "…")) tl = substr(tl, 1, index(tl, "…") - 1)
		for (t in ORIG) {
			for (st = index(tl, t); st; st = (m = index(substr(tl, st + 1), t)) ? st + m : 0)
				if (st <= b && b < st + length(t) && substr(tl, st - 1, 1) !~ /[a-x]/ && substr(tl, st + length(t), 1) !~ /[a-x]/) break
			if (!st) {                              # cut in the twin too: its start at the end
				for (m = length(t) - 1; m >= 1; m--) if (substr(tl, length(tl) - m + 1) == substr(t, 1, m)) break
				st = (m >= 1 && length(tl) - m + 1 <= b && substr(tl, length(tl) - m, 1) !~ /[a-x]/) ? length(tl) - m + 1 : 0
			}
			if (st) break
		}
		if (!st) return 0
		s = ORIG[t]; nu = units(s, U, UW); acc = 0
		for (j = 1; j <= nu && acc + UW[j] <= b - st; j++) acc += UW[j]
		return (acc == b - st && j <= nu) ? UW[j] : 0
	}'
}
# twin_sweep FIXTURE ARGS...: FIXTURE and its twin (twin_fx made it, the
# args through twin_of: TWINARGS, TWINENV) at every sampled size, colour on:
# widths 40-200, FULL at height 40 and COMPACT at 12, 20, 40 and 80 (or the
# widths in WIDTHS); one need per screen.  The caller's array twin_env holds
# VAR=value for both runs (the value twinned), sweep_env VAR=value for both
# as it is (C mode, AC6: LC_ALL and a PATH with a locale tool)
twin_sweep() {
	local fx=$1 w h mode wo two; shift
	local -a args=("$@") targs=() env=() tenv=() e
	for e in "${args[@]}"; do targs+=("$(twin_of "$e")"); done
	for e in "${twin_env[@]+"${twin_env[@]}"}"; do env+=("$e"); tenv+=("${e%%=*}=$(twin_of "${e#*=}")"); done
	env+=("${sweep_env[@]+"${sweep_env[@]}"}"); tenv+=("${sweep_env[@]+"${sweep_env[@]}"}")
	for w in ${WIDTHS:-40 50 60 72 80 100 120 160 200}; do
		for h in full:40 compact:12 compact:20 compact:40 compact:80; do
			mode=${h%:*}; h=${h#*:}
			sq_run "$fixtures/$fx" SQ_WIDTH=$w SQ_HEIGHT=$h "${env[@]+"${env[@]}"}" -- --color --$mode "${args[@]+"${args[@]}"}"; wo=$OUT
			need "$fx $mode ${w}x$h: rc 0, stderr empty" eval 'rc_is 0 && err_empty'
			sq_run "$T_DIR/twin-$fx" SQ_WIDTH=$w SQ_HEIGHT=$h "${tenv[@]+"${tenv[@]}"}" -- --color --$mode "${targs[@]+"${targs[@]}"}"; two=$OUT
			need "$fx $mode ${w}x$h: against its twin$(twin_check "$wo" "$two" "$w" "$h" 2> "$T_DIR/check.err" || printf ': %s' "$(paste -sd'|' "$T_DIR/check.err")")" \
				eval '[ ! -s "$T_DIR/check.err" ]'
		done
	done
}
wide_cols=(-o i,j,u,a,P,T,M,L,C,m,N,R,Z)
c_wide_twin_text() {
	T_TITLE="CJK, kana, Hangul, U+1F600, combining marks, ZWJ, a flag, a lone RI, VS16 and a skin tone in names, users, accounts, partitions, node lists, nodes, a drain reason, work dirs: every sampled screen as its ASCII twin, by the oracle (widest, over, rows, each line, the columns)"
	twin_fx wide-text
	twin_sweep wide-text "${wide_cols[@]}"
}
c_wide_twin_seps() {
	T_TITLE="U+2028 beside kana and han on the banner, the MEMNOTE and the finished caption (-p), the wide nodes and finished jobs: every sampled screen as its ASCII twin"
	twin_fx wide-text wide-seps
	twin_sweep wide-seps "${wide_cols[@]}" -p "区画$(printf '\342\200\250')二"
}
wide_since=開始時刻を指定しe$(printf '\314\201')た
wide_part=$(printf '%.0s区画名前長い利用者口座処理e\314\201' {1..12})
c_wide_twin_ascii() {
	T_TITLE="ASCII records, so the tables keep length(): han with combining marks on the banner, the MEMNOTE, a -p value (each over 200 columns) and SQ_SINCE, measured by columns all the same: every sampled screen as its ASCII twin"
	local -a twin_env=("SQ_SINCE=$wide_since")
	twin_fx wide-ascii
	twin_sweep wide-ascii -p "$wide_part"
}

# COMPACT's one finished line, the newest failure's name in han and kana
# (wide-fin): cut by columns, so it fits, at every width around the cut, as
# its twin does
c_wide_compact_fin() {
	T_TITLE="COMPACT's one finished line with the newest failure named in han and kana: the name cut by columns (4002 失敗した解析… FAILED 1), at widths 36-48 every screen as its ASCII twin"
	twin_fx wide-text wide-fin
	sq_run wide-fin SQ_WIDTH=40 SQ_HEIGHT=20 -- --compact --no-color
	# WHOLE (H7): the caption shortens, then the name is cut, the state and the exit whole
	need "40x20: rc 0, the one line, the name cut, within 40 columns" eval '
		rc_is 0 && matches "^  finished: 4002 失敗した解析… FAILED 1$" && [ "$(oracle_width "$(lines_matching "^  finished: ")")" -le 40 ]'
	WIDTHS="36 38 40 42 44 46 48" twin_sweep wide-fin "${wide_cols[@]}"
}
# COMPACT's one finished line with gawk in C (no UTF-8 locale to pin: the
# locale tool knows C and POSIX alone), the caption itself cut: the caption
# and the job are cut each on its own, as one cut of both, split at the
# caption's length (bytes, in C), halved its "…" at 60 and 61 columns.
# WHOLE (H7, N-B): the caption now takes its short forms, finished
# (--reservation: no sacct), instead of a cut, the same under C
c_wide_compact_fin_c() {
	T_TITLE="COMPACT's one finished line under gawk in C where its caption once was cut (noacct, --reservation=x, 24 lines, 58-63 columns): valid UTF-8, within the width, as under UTF-8"
	local nobin=$T_DIR/nobin w want
	no_utf8_locale "$nobin"
	for w in 58 59 60 61 62 63; do
		sq_run noacct SQ_WIDTH=$w SQ_HEIGHT=24 -- --compact --color --reservation=x
		want=$(LC_ALL=C grep -a '^  .*finished (' "$OUT")
		sq_run noacct SQ_WIDTH=$w SQ_HEIGHT=24 LC_ALL=C PATH="$nobin:$here/bin:$PATH" -- --compact --color --reservation=x
		need "$w columns: rc 0, valid UTF-8, the finished line within $w columns, byte for byte as under UTF-8" eval '
			rc_is 0 && err_empty && utf8_valid && [ -n "$want" ] && [ "$(LC_ALL=C grep -a "^  .*finished (" "$OUT")" = "$want" ] &&
			[ "$(oracle_width "$(lines_matching "^  finished \(")")" -le '"$w"' ]'
	done
}
# R2 4: the one finished line where caption and job fill the line exactly, and
# one column short of that: its bytes pinned, colour and all, under UTF-8 and
# under a gawk in C (R1's H: the caption is never cut into the line; WHOLE's
# H7 gives the caption's shorter form, or no caption, instead)
c_fin_caption_fills() {
	T_TITLE="COMPACT's one finished line (noacct, 24 lines) at each width where caption and job fill it exactly and one column short: byte for byte, coloured, under UTF-8 and under a gawk in C"
	local nobin=$T_DIR/nobin spec w flt want got how
	no_utf8_locale "$nobin"
	for spec in "24::" "25::finished: " "40::finished: " "41::finished (no accounting): " \
	            "43::finished (no accounting): " "44::finished (no accounting): |qc" "52::finished (no accounting): |qc" \
	            "53::recently finished (no accounting): |qc" \
	            "40:--reservation=x:finished: " "41:--reservation=x:finished (--reservation): " \
	            "53:--reservation=x:finished (--reservation): |qc" "54:--reservation=x:finished (--reservation: no sacct): |qc"; do
		IFS=: read -r w flt want <<< "$spec"
		case $want in *'|qc') want="$ESC[2m${want%|qc}$ESC[0m$ESC[31m4188 qc FAILED 1$ESC[0m" ;;
		              *) want="$ESC[2m$want$ESC[0m$ESC[31m4188 FAILED 1$ESC[0m" ;; esac
		for how in utf8 C; do
			if [ $how = utf8 ]; then sq_run noacct SQ_WIDTH="$w" SQ_HEIGHT=24 -- --compact --color $flt
			else sq_run noacct SQ_WIDTH="$w" SQ_HEIGHT=24 LC_ALL=C PATH="$nobin:$here/bin:$PATH" -- --compact --color $flt; fi
			got=$(LC_ALL=C grep -a '4188' "$OUT")
			need "W=$w${flt:+ $flt} ($how): the finished line '  $(printf '%s' "$want" | sed "s/$ESC\[[0-9;]*m//g")', byte for byte" eval 'rc_is 0 && err_empty && [ "$got" = "  $want" ]'
		done
	done
}
# a finished NAME cut by columns with a gap after "…": x and han, cut at an
# odd boundary (x日本語のとても長いジョ… at 60 is 24 of 25 columns), padded
# from its cut width, so STATE stays in its column
c_wide_fin_cut() {
	T_TITLE="a finished NAME cut one column short (an ASCII letter before han): padded from its cut width, STATE in its column, at 40 and 60 as its twin"
	twin_fx wide-text wide-fin
	sq_run wide-fin SQ_WIDTH=60 -- --full --no-color
	need "60: rc 0, x日本語のとても長いジョ… cut, STATE in one column on every finished row" eval '
		rc_is 0 && rows recent | grep -qE "^  4001  x日本語のとても長いジョ…  COMPLETED " &&
		[ "$(SRC=cplain section recent | gawk "/ (COMPLETED|FAILED) / { print match(\$0, / (COMPLETED|FAILED) /) }" | sort -u | wc -l)" = 1 ]'
	WIDTHS="40 60" twin_sweep wide-fin "${wide_cols[@]}"
}
# wide text in one input alone: the finished jobs (wide-reconly) or the node
# names (wide-nodeonly), the other answers ASCII: that input alone sets WIDE
c_wide_twin_parts() {
	T_TITLE="wide text in the finished jobs alone, then in the node names alone (the other answers ASCII): every screen at 50, 80 and 120 as its ASCII twin"
	twin_fx mixed wide-text wide-reconly wide-nodeonly
	WIDTHS="50 80 120" twin_sweep wide-reconly
	WIDTHS="50 80 120" twin_sweep wide-nodeonly
}
# no UTF-8 locale (gawk in C) where the id floor and digest() decide: the
# finished JOBID shaved to its floor (shrink-finished at 50) and the one
# summary node line cut (COMPACT, narrow): the screen of a UTF-8 caller,
# byte for byte, the clock aside
c_wide_c_floor() {
	T_TITLE="gawk in C (no UTF-8 locale): shrink-finished at 50 (the id in its F2 form, 600_… ×67) and COMPACT's one node line (digest) at narrow widths draw the UTF-8 screen byte for byte"
	local nobin=$T_DIR/nobin want spec fx mode w h
	no_utf8_locale "$nobin"
	for spec in shrink-finished:full:50:30 shrink-finished:compact:50:20 \
	            busy24:compact:30:8 busy24:compact:40:8 busy24:compact:50:8 busy24:compact:60:6 \
	            mix30:compact:30:8 mix30:compact:40:8 mix30:compact:50:8 mix30:compact:60:6 \
	            manystuck:compact:30:8 manystuck:compact:40:8 manystuck:compact:50:8 manystuck:compact:60:6; do
		IFS=: read -r fx mode w h <<< "$spec"
		sq_run "$fx" SLURM_BITSTR_LEN=0 SQ_WIDTH=$w SQ_HEIGHT=$h -- --color --$mode
		want=$RUN/screen.utf8; without_clock "$OUT" > "$want"
		sq_run "$fx" SLURM_BITSTR_LEN=0 SQ_WIDTH=$w SQ_HEIGHT=$h LC_ALL=C "PATH=$nobin:$here/bin:$PATH" -- --color --$mode
		need "$fx $mode ${w}x$h: under C rc 0, stderr empty, the UTF-8 screen" eval 'rc_is 0 && err_empty && cmp -s "$want" <(without_clock "$OUT")'
	done
	sq_run shrink-finished SLURM_BITSTR_LEN=0 SQ_WIDTH=50 SQ_HEIGHT=30 LC_ALL=C "PATH=$nobin:$here/bin:$PATH" -- --full
	need "shrink-finished at 50 under C: the id in its F2 form beside the long state, 600_… ×67 (WHOLE R-M3)" has "600_… ×67 sweep  CANCELLED"
}
# ---- display width: sq job's tables and its tail (AC2) ----------------------
# A node named in han and kana with an emoji and a combining mark, users in
# han and Hangul with a combining mark and a skin tone: node_table (the free
# and the total table), why_blockers' jobs to end first and why_res's jobs
# ahead (its UserName padded to the larger of 9 and its widest) line up as
# their ASCII twins do: each line of the why section, cellified and every
# such string put back as its twin, is the twin's line.  The output tail,
# lines of han wider than COLUMNS, each cut to fit: every line within it
untwin_awk='
BEGIN { while ((getline x < ENVIRON["TWIN_MAP"]) > 0) { k = index(x, "\t"); CELL[++nm] = cellify(substr(x, 1, k - 1)); TWIN[nm] = substr(x, k + 1) } }
{ for (m = 1; m <= nm; m++) while ((k = index($0, CELL[m]))) $0 = substr($0, 1, k - 1) TWIN[m] substr($0, k + length(CELL[m])); print }'
wide_job_node=节点ノード😀e$(printf '\314\201')
wide_job_user=田中太郎e$(printf '\314\201')
wide_job_user2=김민수김민수e$(printf '\314\201')
c_wide_job() {
	T_TITLE="sq job: node_table, why_blockers and why_res (UserName to the larger of 9 and its widest) with a node and users in han, kana, Hangul, an emoji and combining marks line up as their ASCII twins do; the output tail in han cut to COLUMNS, every line within it"
	local node user user2 tn tu tu2 fx src d long i
	tn=$(twin_of "$wide_job_node"); tu=$(twin_of "$wide_job_user"); tu2=$(twin_of "$wide_job_user2")
	for fx in resources-11964:11964 pending-est:11962; do
		src=${fx%:*}
		for d in wide twin; do
			if [ $d = wide ]; then node=$wide_job_node user=$wide_job_user user2=$wide_job_user2
			else node=$tn user=$tu user2=$tu2; fi
			res_fx "$src-$d" "$src" "s/fb2-bioinf(\$|[^-])/$node\\1/g" "s/UserName=schroder/UserName=$user/" "s/UserName=amadvi/UserName=$user2/" > /dev/null
			why_run "$T_DIR/fx-$src-$d" -- --no-color job "${fx#*:}"
			need "$src $d: rc 0, stderr empty, a why section" eval 'rc_is 0 && err_empty && [ -n "$(why_lines)" ]'
			SRC=cplain why_lines > "$T_DIR/why.$src.$d"; why_lines > "$T_DIR/why.$src.$d.plain"
		done
		TWIN_MAP=$T_DIR/twin.map ORACLE_MAP=$work/oracle.map LC_ALL=$utf8 gawk "$oracle_awk$untwin_awk" "$T_DIR/why.$src.wide" > "$T_DIR/why.$src.back"
		need "$src: the why section, every name put back as its twin, is the twin's line for line$(cmp -s "$T_DIR/why.$src.back" "$T_DIR/why.$src.twin" || printf ': %s' "$(diff "$T_DIR/why.$src.back" "$T_DIR/why.$src.twin" | paste -sd'|')")" \
			cmp -s "$T_DIR/why.$src.back" "$T_DIR/why.$src.twin"
	done
	need "the node in node_table and why_blockers, the user in why_blockers and in why_res" eval '
		[ "$(grep -cF "$wide_job_node" "$T_DIR/why.resources-11964.wide.plain")" = 2 ] && grep -qE "^    11875  $wide_job_user  32 CPUs" "$T_DIR/why.resources-11964.wide.plain" &&
		grep -qE "^    11958  $wide_job_user2  64 CPUs" "$T_DIR/why.pending-est.wide.plain"'
	need "pending-est: why_res pads the user to its width, 13 columns, not 9" eval '
		grep -E "^    11958  " "$T_DIR/why.pending-est.twin" | grep -qE "^    11958  [a-x]{13}  64 CPUs "'
	long=; for i in 1 2 3; do long="$long行$i: $(printf '%.0s解析結果を出力しましたe\314\201' {1..8})\\n"; done
	d=$(tail_fx widetail -- "$(out_file "$long")" "$(dated 200s)")
	why_run "$d" -- --no-color job 11836
	need "the tail in han: 3 lines, each cut with \"…\", each with its indent within COLUMNS=100 and at most 1 short of it" eval '
		rc_is 0 && err_empty && [ "$(tail_lines | wc -l)" = 3 ] && [ "$(tail_lines | grep -c "…$")" = 3 ] &&
		tail_lines | LC_ALL=$utf8 gawk "{ w = length(\$0) + 4; if (w > 100 || w < 99) bad = 1 } END { exit bad }"'
}

# why_res with two jobs ahead whose users are wider than 9 columns and of
# different widths (13, 16): both padded to the widest, the columns after
# them aligned
c_wide_job_ahead() {
	T_TITLE="sq job's why_res, two jobs ahead owned by longusername1 and abcdefghijklmnop: the user column 16 wide, CPUs and memory aligned"
	local d
	d=$(res_fx ahead2 pending-est 's/UserName=amadvi/UserName=longusername1/')
	printf '%s\n' 'JobID=11959; ArrayJobID=11959; StateCompact=PD; UserName=abcdefghijklmnop; Partition=LocalQ; NodeList=; NumCPUs=64; tres_alloc=cpu=64,mem=500G,node=1,billing=64; EndTime=N/A; TimeLeft=1-00:00:00; TimeLimit=1-00:00:00; SubmitTime=\{epoch-16200s}; Reason=Resources' >> "$d/squeue-queue"
	why_run "$d" -- --no-color job 11962
	need "rc 0, both jobs ahead, each user padded to 16, then the CPUs: the same column" eval '
		rc_is 0 && err_empty && why_has "    11958  longusername1     64 CPUs    500G  PENDING (Resources), submitted 4h ago" &&
		why_has "    11959  abcdefghijklmnop  64 CPUs    500G  PENDING (Resources), submitted 4h ago"'
}
# ---- display width without a UTF-8 locale (W7, AC6) ---------------------------
# A locale tool that knows no UTF-8 locale leaves gawk in C, where length()
# counts bytes: sq measures by the UTF-8 bytes themselves.  The twin sweeps at
# 50, 80 and 120; array-running's JOBID header and ×-rows as under UTF-8;
# and a caller's ja_JP.eucJP or de_DE.ISO-8859-1 (built as locale_not_utf8
# does, seen only through LOCPATH) gives the LC_ALL=C screen byte for byte,
# every gawk in C (it was the caller's locale, whose eucJP read UTF-8 bytes
# as its own characters and whose [[:cntrl:]] ate a byte of "…")
c_wide_c_mode() {
	T_TITLE="no UTF-8 locale (gawk in C): the wide screens as their twins at 50, 80 and 120; array-running's JOBID header and ×-rows as under UTF-8; LC_ALL=ja_JP.eucJP and de_DE.ISO-8859-1 give the LC_ALL=C screen (start estimates aside), every gawk in C"
	local nobin=$T_DIR/nobin loc=$T_DIR/loc gbin=$T_DIR/gbin glog=$T_DIR/gawk.log l want src charmap name
	mkdir -p "$nobin" "$loc"
	no_utf8_locale "$nobin"
	local -a sweep_env=(LC_ALL=C "PATH=$nobin:$here/bin:$PATH") twin_env=()
	twin_fx wide-text wide-seps wide-ascii
	WIDTHS="50 80 120" twin_sweep wide-text "${wide_cols[@]}"
	WIDTHS="50 80 120" twin_sweep wide-seps "${wide_cols[@]}" -p "区画$(printf '\342\200\250')二"
	twin_env=("SQ_SINCE=$wide_since")
	WIDTHS="50 80 120" twin_sweep wide-ascii -p "$wide_part"
	sq_run array-running SQ_WIDTH=80 -- --color; want=$RUN/screen; cp "$OUT" "$want"
	sq_run array-running SQ_WIDTH=80 "${sweep_env[@]}" -- --color
	need "array-running: the JOBID header and every ×-row as under UTF-8, byte for byte" eval '
		rc_is 0 && err_empty && grep -q "×" "$OUT" &&
		cmp -s <(grep -E "JOBID|×" "$want") <(grep -E "JOBID|×" "$OUT")'
	for l in ja_JP:EUC-JP:ja_JP.eucJP de_DE:ISO-8859-1:de_DE.ISO-8859-1; do
		IFS=: read -r src charmap name <<< "$l"
		localedef -i "$src" -f "$charmap" "$loc/$name" > /dev/null 2>&1
		if ! [ "$(LOCPATH=$loc LC_ALL=$name locale charmap 2>/dev/null)" = "$charmap" ]; then
			T_FAIL+=("localedef could not build $name (needs glibc's locale sources)"); return
		fi
	done
	gawk_wrapper "$gbin" "$glog"
	# wide-text's start estimates are the stub's \{now+3h}: a minute edge between the runs moves them
	sq_run wide-text SQ_WIDTH=80 "${sweep_env[@]}" -- --color "${wide_cols[@]}"; want=$RUN/screen.C; without_clock "$OUT" | mask_estimates > "$want"
	for name in ja_JP.eucJP de_DE.ISO-8859-1; do
		: > "$glog"
		sq_run wide-text SQ_WIDTH=80 LC_ALL=$name LOCPATH="$loc" "PATH=$gbin:$nobin:$here/bin:$PATH" -- --color "${wide_cols[@]}"
		need "LC_ALL=$name: rc 0, stderr empty, the LC_ALL=C screen byte for byte, every gawk in C" eval '
			rc_is 0 && err_empty && cmp -s "$want" <(without_clock "$OUT" | mask_estimates) && grep -q "^call" "$glog" && ! grep "^call" "$glog" | grep -qvx "call C"'
	done
}

# BIG5 (and BIG5-HKSCS, CP949, JOHAB) counts "…█" as two characters, as UTF-8
# does, so without a locale tool that answers, gawk's count alone took it for
# UTF-8: a garbled screen, then (with the wide classes) an invalid regexp and
# no screen.  utf8_ok also asks gawk to write U+2026 U+2588 as "…█": a BIG5
# caller gets what LC_ALL=C gets, rc 0
c_locale_big5() {
	T_TITLE="LC_ALL=zh_TW.BIG5 with no locale tool answering: no UTF-8 locale to gawk, the LC_ALL=C screen byte for byte, rc 0, stderr empty"
	local loc=$T_DIR/loc nobin=$T_DIR/nobin want
	mkdir -p "$loc" "$nobin"
	localedef -i zh_TW -f BIG5 "$loc/zh_TW.BIG5" > /dev/null 2>&1
	if ! [ "$(LOCPATH=$loc LC_ALL=zh_TW.BIG5 locale charmap 2>/dev/null)" = BIG5 ]; then
		T_FAIL+=("localedef could not build zh_TW.BIG5 (needs glibc's locale sources)"); return
	fi
	printf '#!/bin/sh\nexit 127\n' > "$nobin/locale"; chmod +x "$nobin/locale"
	sq_run wide-text SQ_WIDTH=80 LC_ALL=C "PATH=$nobin:$here/bin:$PATH" -- --color "${wide_cols[@]}"
	want=$RUN/screen.C; without_clock "$OUT" > "$want"
	need "LC_ALL=C: rc 0" rc_is 0
	sq_run wide-text SQ_WIDTH=80 LC_ALL=zh_TW.BIG5 LOCPATH="$loc" "PATH=$nobin:$here/bin:$PATH" -- --color "${wide_cols[@]}"
	need "LC_ALL=zh_TW.BIG5: rc 0, stderr empty, the LC_ALL=C screen byte for byte" eval 'rc_is 0 && err_empty && cmp -s "$want" <(without_clock "$OUT")'
}

# ---- display width: what a terminal draws (AC7) ------------------------------
# The rows a terminal takes for a screen: tmux (3.4 measured), on a private
# socket, no config, UTF-8 (-u, a UTF-8 locale), a pane of COLUMNS x LINES
# that cats it; rows written, history included.  The wide screen takes the
# twin's rows where the twin fits COLUMNS, at most them where it does not
tmux_rows() {   # tmux_rows FILE COLUMNS LINES
	local sock=sq-test-$BASHPID-$RANDOM i out
	env LC_ALL=$utf8 tmux -L "$sock" -f /dev/null -u new-session -d -x "$2" -y "$3" "cat '$1'; exec sleep 20" 2>/dev/null || { echo none; return; }
	for i in $(seq 100); do
		[ "$(tmux -L "$sock" display -p '#{pane_current_command}' 2>/dev/null)" = sleep ] && break
		sleep 0.1
	done
	out=$(tmux -L "$sock" display -p '#{history_size} #{cursor_y}' 2>/dev/null)
	tmux -L "$sock" kill-server 2>/dev/null; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$UID/$sock"
	set -- $out; [ $# = 2 ] && echo $(( $1 + $2 )) || echo none
}
c_wide_tmux() {
	T_TITLE="tmux: the wide screen takes as many terminal rows as its twin where the twin fits COLUMNS, at most as many where not (FULL 40, 80 and 120, COMPACT 60x12, 80x20)"
	local spec mode w h wo two rw rt tw
	if ! command -v tmux > /dev/null 2>&1; then
		T_TITLE="$T_TITLE; skipped: no tmux here"; sq_run mixed --; return
	fi
	twin_fx wide-text
	for spec in full:40:40 full:80:40 full:120:40 compact:60:12 compact:80:20; do
		IFS=: read -r mode w h <<< "$spec"
		sq_run wide-text SQ_WIDTH=$w SQ_HEIGHT=$h -- --color --$mode "${wide_cols[@]}"; wo=$OUT
		sq_run "$T_DIR/twin-wide-text" SQ_WIDTH=$w SQ_HEIGHT=$h -- --color --$mode "${wide_cols[@]}"; two=$OUT
		rw=$(tmux_rows "$wo" "$w" "$h"); rt=$(tmux_rows "$two" "$w" "$h"); tw=$(OUT=$two width)
		if [ "$tw" -le "$w" ]; then need "$mode ${w}x$h: the twin fits, both take $rt rows (the wide screen $rw)" eval '[ "$rw" != none ] && [ "$rw" = "$rt" ]'
		else need "$mode ${w}x$h: the twin is $tw wide, the wide screen takes no more rows ($rw) than it ($rt)" eval '[ "$rw" != none ] && [ "$rt" != none ] && [ "$rw" -le "$rt" ]'
		fi
	done
}

# U+202E (RLO) turns around what a terminal shows after it, up to the end of
# the line: no text sq draws or says may carry one, nor any other bidi
# control.  Each site that echoes outside text: a usage error, the filter on
# the caption, squeue's stderr on the banner, and the refusals that echoed
# the word as typed (-O.../--Format=, -s..., -i..., letters run together, a
# field letter squeue does not have), which also passed a terminal escape
# raw.  -o... and --format=... are sq's own column list (OPTS-v4 C3), whose
# letters alone are read.
c_bidi_sites() {
	T_TITLE="U+202E goes from every echo: -u's usage error, the caption's filter, squeue's stderr on the banner; the refusals that echoed the word raw (-O…, --Format=…, -s…, -i…, -ab…, a field letter) are scrubbed; -o… and --format=… read their letters alone, an ESC too"
	local rlo=$'\342\200\256' w
	sq_run wide -- -u "-a${rlo}b"
	need "-u -a+RLO+b: refused, the value echoed as '-ab'" eval 'rc_is 2 && grep -qF "not '"'"'-ab'"'"'" "$ERR" && bidi_inert "$ERR"'
	sq_run wide -- -u "a${rlo}b"
	need "-u a+RLO+b: rc 0, the caption says user=ab" eval 'rc_is 0 && err_empty && has "recently finished · last 2h · user=ab" && bidi_inert'
	sq_run "$(stderr_fixture squeue 'no a\xe2\x80\xaeb here')" --
	need "squeue's stderr with RLO: rc 0, the banner reads 'no ab here'" \
		eval 'rc_is 0 && err_empty && matches "^  ⚠ slurm unreachable · squeue: error: no ab here$" && bidi_inert'
	for w in "-o${rlo}u" "--format=${rlo}u"; do
		sq_run wide -- "$w"
		need "$w: sq's column list, the letter u: rc 0, the USER column alone" eval 'rc_is 0 && err_empty &&
			[ "$(section queue | head -n 1 | sed "s/^ *//; s/ *$//")" = USER ]'
	done
	for w in "--Format=${rlo}x" "-O${rlo}x"; do
		sq_run wide -- "$w"
		need "$w: refused, echoed without the RLO" eval 'rc_is 2 && bidi_inert "$ERR" &&
			grep -qxF "sq: ${w//$rlo/} would override sq'"'"'s own output format; write the column list as '"'"'sq -o i,j,u'"'"'" "$ERR"'
	done
	sq_run wide -- -o "i$ESC[2J"
	need "-o i+ESC[2J: its first letter i, rc 0, the JOBID column alone, no ESC but sq's colours" eval 'rc_is 0 && err_empty && escapes_all_sgr &&
		[ "$(section queue | head -n 1 | sed "s/^ *//; s/ *$//")" = JOBID ]'
	sq_run wide -- "-s${rlo}"
	need "-s+RLO: refused as -s" eval 'rc_is 2 && bidi_inert "$ERR" && grep -qxF "sq: -s lists job steps, which sq cannot frame safely; sq shows jobs" "$ERR"'
	sq_run wide -- "-i${rlo}5"
	need "-i+RLO+5: refused as -i5" eval 'rc_is 2 && bidi_inert "$ERR" && grep -qxF "sq: -i5 repeats squeue'"'"'s own output; sq refreshes with '"'"'watch -tc -n 5 sq'"'"'" "$ERR"'
	sq_run wide -- "-ab${rlo}" x
	need "-ab+RLO x: refused as letters run together, the word without the RLO" eval 'rc_is 2 && bidi_inert "$ERR" &&
		grep -qxF "sq: '"'"'-ab'"'"' runs options together; write each option as its own word" "$ERR"'
	sq_run wide -- -o "i,s${rlo}"
	need "-o i,s+RLO: %s refused, the list echoed as 'i,s'" eval 'rc_is 2 && bidi_inert "$ERR" &&
		grep -qxF "sq: %s is not a squeue field letter (in -o '"'"'i,s'"'"')" "$ERR"'
	sq_run wide SQ_FMT="i,s${rlo}" --
	need "SQ_FMT=i,s+RLO: refused the same, naming SQ_FMT" eval 'rc_is 2 && bidi_inert "$ERR" &&
		grep -qxF "sq: %s is not a squeue field letter (in SQ_FMT '"'"'i,s'"'"')" "$ERR"'
}
# What only the bell reads takes the same road: a user name and a cache path
# that -v would have unescaped reach gawk as given.  The bell rings only with a
# terminal, so these run on a pty with the bell left on.
bell_fixture() {   # bell_fixture: a job of alice's that FAILED a minute ago, nothing else
	local d=$T_DIR/fx-bell; mkdir -p "$d"
	printf '@include %s\n' "$fixtures/_common/sinfo-two-idle" > "$d/sinfo"
	printf '@include %s\n' "$fixtures/_common/empty" > "$d/squeue"
	printf '@include %s\nJobID=7001; JobName=crash; State=FAILED; ExitCode=1:0; End=\\{now-1m30s}\n' \
		"$fixtures/_common/sacct-defaults" > "$d/sacct"
	printf '%s' "$d"
}
bell_run() {       # bell_run FIXTURE [VAR=value...]: sq on a pty, the bell on
	BELL=1 PTY=1 PTY_ROWS=40 PTY_COLS=100 sq_run "$1" TERM=xterm-256color "${@:2}" --
}
c_bell_text() {
	T_TITLE="SQ_BELL_USER, SQ_BELL_ALL and an XDG_CACHE_HOME holding '\\n' reach the bell byte for byte"
	local fx cache=$T_DIR/'c\nd'
	fx=$(bell_fixture)
	bell_run "$fx" SQ_BELL_USER=alice XDG_CACHE_HOME="$cache"
	need "alice's fresh failure: rc 0, one bell" eval 'rc_is 0 && [ "$(bels)" -eq 1 ]'
	need "remembered in the cache path as given" eval 'grep -q "^7001[[:space:]]" "$cache/sq/alerted" 2>/dev/null'
	bell_run "$fx" SQ_BELL_USER=alice XDG_CACHE_HOME="$cache"
	need "run again: rc 0, silent, as it read that memory back" eval 'rc_is 0 && [ "$(bels)" -eq 0 ]'
	bell_run "$fx" SQ_BELL_USER='al\x69ce'
	need "SQ_BELL_USER='al\\x69ce' is not alice: rc 0, silent" eval 'rc_is 0 && [ "$(bels)" -eq 0 ]'
	bell_run "$fx" SQ_BELL_USER=bob
	need "bob: rc 0, silent, the job is alice's" eval 'rc_is 0 && [ "$(bels)" -eq 0 ]'
	bell_run "$fx" SQ_BELL_USER=bob SQ_BELL_ALL=1
	need "bob with SQ_BELL_ALL=1: rc 0, one bell" eval 'rc_is 0 && [ "$(bels)" -eq 1 ]'
}
# The bell's user (SQ_BELL_USER, else id -un) takes the rule Slurm's user
# names take (scrub -s, then the control rule), so a login that is no UTF-8,
# holds a bidi control or a control character still matches the User sacct
# prints for it.
c_bell_not_utf8() {
	T_TITLE="the bell rings for a failure of user b\\xe9a, of a+U+202E+b and of a+TAB+b, with SQ_BELL_USER set to the same bytes; not for another"
	local fx u
	for u in 'b\xe9a' 'a\xe2\x80\xaeb' 'a\tb'; do
		fx=$T_DIR/fx-bell-$RANDOM; cp -r "$(bell_fixture)" "$fx"
		printf '@include %s\nJobID=7001; User=%s; JobName=crash; State=FAILED; ExitCode=1:0; End=\\{now-1m30s}\n' \
			"$fixtures/_common/sacct-defaults" "$u" > "$fx/sacct"
		bell_run "$fx" SQ_BELL_USER="$(printf "$u")"
		need "$u's fresh failure, SQ_BELL_USER the same bytes: rc 0, one bell" eval 'rc_is 0 && [ "$(bels)" -eq 1 ]'
		bell_run "$fx" SQ_BELL_USER=alice
		need "$u's failure, SQ_BELL_USER=alice: rc 0, silent" eval 'rc_is 0 && [ "$(bels)" -eq 0 ]'
	done
}
# The bell's state directory is the one JOBMEM's snapshot uses: XDG_CACHE_HOME
# only when absolute, else HOME's .cache only when HOME is absolute, else none,
# and then the bell is off.  An unset HOME once killed sq ("HOME: unbound
# variable"), with or without the bell.  sq runs in a directory of its own
# here, so whatever a relative path would write shows up there.
c_bell_statedir() {
	T_TITLE="the bell's state directory: no HOME, or one sq cannot write in, is no state and no bell, never a crash; a relative XDG_CACHE_HOME counts for nothing"
	local fx want cwd=$T_DIR/cwd
	mkdir -p "$cwd"; pushd "$cwd" > /dev/null || return
	sq_run mixed --
	want=$RUN/screen; without_clock "$OUT" > "$want"
	sq_run mixed -HOME --
	need "HOME unset: rc 0, stderr empty, the same screen" eval 'rc_is 0 && err_empty && cmp -s "$want" <(without_clock "$OUT")'
	fx=$(bell_fixture)
	bell_run "$fx" SQ_BELL_USER=alice
	need "with HOME: one bell, remembered under HOME/.cache" eval 'rc_is 0 && [ "$(bels)" -eq 1 ] && [ -s "$RUN/home/.cache/sq/alerted" ]'
	bell_run "$fx" SQ_BELL_USER=alice -HOME
	need "HOME unset, on a terminal: rc 0, no bell, the screen drawn" eval 'rc_is 0 && [ "$(bels)" -eq 0 ] && has "7001"'
	bell_run "$fx" SQ_BELL_USER=alice HOME=relhome
	need "HOME relative: rc 0, no bell" eval 'rc_is 0 && [ "$(bels)" -eq 0 ]'
	bell_run "$fx" SQ_BELL_USER=alice XDG_CACHE_HOME=relcache
	need "XDG_CACHE_HOME relative: one bell, remembered under HOME/.cache" eval 'rc_is 0 && [ "$(bels)" -eq 1 ] && [ -s "$RUN/home/.cache/sq/alerted" ]'
	# a state directory sq cannot write in is none: it once killed gawk at the
	# end ("cannot redirect to .../alerted.PID"), rc 2.  Root writes there anyway
	if [ "$(id -u)" != 0 ]; then
		local ro=$T_DIR/ro
		mkdir -p "$ro/.cache/sq"; chmod 555 "$ro/.cache/sq"
		bell_run "$fx" SQ_BELL_USER=alice HOME="$ro"
		chmod 755 "$ro/.cache/sq"
		need "~/.cache/sq read-only: rc 0, no bell, no gawk error, the screen drawn, nothing left in it" \
			eval 'rc_is 0 && [ "$(bels)" -eq 0 ] && has "7001" && lacks "gawk" && [ -z "$(ls -A "$ro/.cache/sq")" ]'
	fi
	need "nothing written in the working directory" eval '[ -z "$(ls -A "$cwd")" ]'
	popd > /dev/null || return
}
# The bell's probe of its state directory is the temp file itself, made and
# removed at once: one left behind would be renamed over the bell's memory by
# a run that never writes that memory, one without a terminal (NOTTY: no
# controlling terminal, so /dev/tty cannot be opened)
c_bell_notty() {
	T_TITLE="the bell on without a terminal: no bell, the bell's memory as it was, no probe file left beside it"
	local fx home=$T_DIR/home
	fx=$(bell_fixture)
	bell_run "$fx" SQ_BELL_USER=alice HOME="$home"
	need "on a terminal: one bell, remembered" eval 'rc_is 0 && [ "$(bels)" -eq 1 ] && [ -s "$home/.cache/sq/alerted" ]'
	cp "$home/.cache/sq/alerted" "$T_DIR/alerted.before"
	BELL=1 NOTTY=1 sq_run "$fx" SQ_BELL_USER=alice HOME="$home" --
	need "no terminal: rc 0, no bell, the memory unchanged, nothing else in its directory" \
		eval 'rc_is 0 && [ "$(bels)" -eq 0 ] && cmp -s "$T_DIR/alerted.before" "$home/.cache/sq/alerted" && [ "$(ls -A "$home/.cache/sq")" = alerted ]'
	BELL=1 NOTTY=1 sq_run "$fx" SQ_BELL_USER=alice --
	need "no terminal, no memory yet: none written, nothing left" eval 'rc_is 0 && [ -z "$(ls -A "$RUN/home/.cache/sq" 2>/dev/null)" ]'
}
# The bell's memory is a regular file or none: one that was a directory read
# as nothing (the bell rang on every run, and a temp file piled up in it each
# time), a FIFO blocked sq for good, and /dev/zero behind a symlink took all
# memory (capped here at 1 GB).  And a run that writes no memory never renames
# an alerted.PID over it: a stray one of another process that had sq's pid,
# planted here by a wrapper that execs sq and so hands it its pid
c_bell_state_odd() {
	T_TITLE="the bell's memory a directory, a FIFO or a symlink to /dev/zero: no bell, sq ends, nothing grows or piles up; with the bell off a stray alerted.PID never replaces the memory"
	local fx home cache kind n before=$T_DIR/alerted.before real=$sq
	fx=$(bell_fixture)
	for kind in directory fifo zero; do
		home=$T_DIR/home-$kind cache=$T_DIR/home-$kind/.cache/sq; mkdir -p "$cache"
		case $kind in
			directory) mkdir "$cache/alerted" ;; fifo) mkfifo "$cache/alerted" ;; zero) ln -s /dev/zero "$cache/alerted" ;;
		esac
		for n in 1 2; do
			PTY_VMEM_KB=1000000 bell_run "$fx" SQ_BELL_USER=alice HOME="$home"
			need "alerted a $kind, run $n: rc 0, no bell, the screen drawn, nothing beside it or in it" eval '
				rc_is 0 && [ "$(bels)" -eq 0 ] && has 7001 && [ "$(ls -A "$cache")" = alerted ] &&
				{ [ $kind != directory ] || [ -z "$(ls -A "$cache/alerted")" ]; }'
		done
	done
	home=$T_DIR/home cache=$T_DIR/home/.cache/sq
	bell_run "$fx" SQ_BELL_USER=alice HOME="$home"
	need "on a terminal: one bell, remembered" eval 'rc_is 0 && [ "$(bels)" -eq 1 ] && [ -s "$cache/alerted" ]'
	cp "$cache/alerted" "$before"
	printf '#!/bin/sh\nprintf "STRAY\\tpartial\\n" > "$HOME/.cache/sq/alerted.$$"\nexec "$PLANT_SQ" "$@"\n' > "$T_DIR/plant"
	chmod +x "$T_DIR/plant"
	local sq=$T_DIR/plant          # sq_run and pty_exec start the wrapper
	sq_run "$fx" SQ_BELL_USER=alice HOME="$home" PLANT_SQ="$real" --
	need "--no-bell, a stray alerted.PID: rc 0, the memory unchanged, the stray gone" eval '
		rc_is 0 && cmp -s "$before" "$cache/alerted" && [ "$(ls -A "$cache")" = alerted ]'
	PTY=1 PTY_ROWS=40 PTY_COLS=100 sq_run "$fx" TERM=xterm-256color SQ_BELL_USER=alice HOME="$home" PLANT_SQ="$real" --
	need "--no-bell on a terminal, a stray alerted.PID: rc 0, no bell, the memory unchanged, the stray gone" eval '
		rc_is 0 && [ "$(bels)" -eq 0 ] && cmp -s "$before" "$cache/alerted" && [ "$(ls -A "$cache")" = alerted ]'
	BELL=1 sq_run "$fx" SQ_BELL=0 SQ_BELL_USER=alice HOME="$home" PLANT_SQ="$real" --
	need "SQ_BELL=0, a stray alerted.PID: rc 0, the memory unchanged, the stray gone" eval '
		rc_is 0 && cmp -s "$before" "$cache/alerted" && [ "$(ls -A "$cache")" = alerted ]'
	BELL=1 PTY=1 PTY_ROWS=40 PTY_COLS=100 sq_run "$fx" TERM=xterm-256color SQ_BELL=0 SQ_BELL_USER=alice HOME="$home" PLANT_SQ="$real" --
	need "SQ_BELL=0 on a terminal, a stray alerted.PID: rc 0, no bell, the memory unchanged, the stray gone" eval '
		rc_is 0 && [ "$(bels)" -eq 0 ] && cmp -s "$before" "$cache/alerted" && [ "$(ls -A "$cache")" = alerted ]'
}
# -c centres the screen in the width, -C in the height too, but only on a
# screen (a terminal, or COLUMNS and LINES set): the screen moves as a whole
# and nothing in it changes.  At 140 columns "mixed" is 80 wide.
c_centre() {
	T_TITLE="-c moves the whole screen to the middle of the width, -C also of the height on a screen, not in a pipe"
	local margin top centred
	sq_run mixed SQ_WIDTH=140 SQ_HEIGHT=30 --
	margin=$(( (140 - $(SRC=cplain section queue | head -n 1 | gawk '{ print length($0) - 2 }')) / 2 ))
	need "uncentred: rc 0, narrower than the screen" eval 'rc_is 0 && [ "$margin" -gt 2 ]'
	local plain=$RUN/uncentred; without_clock "$OUT" > "$plain"
	sq_run mixed SQ_WIDTH=140 SQ_HEIGHT=30 -- -c
	need "-c: rc 0, every line $margin in instead of 2, nothing else changed" eval '
		rc_is 0 && cmp -s <(sed -E "s/^  /$(printf "%*s" "$margin" "")/" "$plain") <(without_clock "$OUT")'
	centred=$RUN/centred; without_clock "$OUT" > "$centred"
	# vertically only on a screen: COLUMNS and LINES set, as watch does (--full
	# and --no-color keep it the screen above)
	sq_run mixed SQ_WIDTH=140 SQ_HEIGHT=30 COLUMNS=140 LINES=30 -- -C --full --no-color
	top=$(( (30 - $(wc -l < "$centred")) / 2 ))
	need "-C on a screen: rc 0, -c's screen under $top blank lines" eval '
		rc_is 0 && [ "$top" -gt 0 ] && [ -z "$(head -n "$top" "$OUT" | tr -d "\n")" ] &&
		cmp -s "$centred" <(tail -n +$((top + 1)) "$OUT" | without_clock /dev/stdin)'
	sq_run mixed SQ_WIDTH=140 SQ_HEIGHT=30 -- -C
	need "-C in a pipe: rc 0, -c's screen, no blank line above it" eval 'rc_is 0 && cmp -s "$centred" <(without_clock "$OUT")'
	sq_run mixed SQ_WIDTH=140 SQ_HEIGHT=30 SQ_CENTER=2 --
	need "SQ_CENTER=2 in a pipe: rc 0, the same" eval 'rc_is 0 && cmp -s "$centred" <(without_clock "$OUT")'
}

# ---- 8. sacct fails: the squeue -t all fallback -----------------------------
c_sacct_fallback() {
	T_TITLE="sacct rc 1: finished block falls back to squeue -t all, caption says so"
	sq_run sacct-fails --
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "stubs: sacct, then the fallback" calls_are 1 1 1 1
	need "every call has SLURM_TIME_FORMAT=standard" all_calls_env SLURM_TIME_FORMAT standard sinfo squeue sacct
	need "fallback argv: squeue -h -t all, -t all last" eval 'argv_has squeue -h -t all && fallback_t_all_last'
	# squeue's third call: the second is the mirror call MEM's totals come from
	need "fallback uses SQUEUE_FORMAT2 and not SQUEUE_FORMAT" eval '
		[ "$(env_of squeue 3 SQUEUE_FORMAT)" = "(unset)" ] && [ "$(env_of squeue 3 SQUEUE_FORMAT2)" != "(unset)" ]'
	need "fallback -O list framed by SQ_NONCE" eval '
		n=$(env_of squeue 3 SQ_NONCE)
		[ "$(env_of squeue 3 SQUEUE_FORMAT2)" = "JobID:$n,StateCompact:$n,State:$n,exit_code:$n,TimeUsed:$n,EndTime:$n,ArrayJobID:$n,ArrayTaskID:$n,UserName:$n,Name:$n" ]'
	need "queue call uses SQUEUE_FORMAT and not SQUEUE_FORMAT2" eval '
		[ "$(env_of squeue 1 SQUEUE_FORMAT2)" = "(unset)" ] && [ "$(env_of squeue 1 SQUEUE_FORMAT)" != "(unset)" ]'
	need "caption names the cause"    eval 'section recent | head -1 | grep -qE "^ +recently finished · recent only \(no accounting\) · sacct: error: Problem"'
	need "finished 6001 shown"        eval 'rows recent | grep -qE "^ +6001 +finished-one +COMPLETED "'
	need "running 3001 only in the queue" eval '[ "$(row_first_fields recent | grep -c "^3001$")" -eq 0 ] && row_cell queue 3001'
	need "footer 1/1/0/0"             footer_is 1 1 0 0
}

# A forwarded flag that changes only how squeue shows its jobs keeps the
# finished block on sacct (Franz, 2026-10-22, "Map/drop, keep 3"): --array and
# -r become sacct's --array, as SQUEUE_ARRAY does when set at all (squeue
# reads it so, empty too); --noconvert, --priority and -P are not passed on.
# OPTS-v4's R-D7: --hide and --all only choose whether squeue shows hidden
# partitions' jobs, which sacct always shows, so they are dropped too, and
# --local is sacct's --local.  Each reaches the queue call in its short
# spelling (--array -r, --priority -P).
c_sacct_flags() {
	T_TITLE="--array/-r and SQUEUE_ARRAY map to sacct --array, --noconvert/--priority/-P/--hide/--all are dropped, --local reaches sacct"
	local f
	for f in --array -r; do
		sq_run empty -- "$f"
		need "$f: rc 0, the block from sacct, which got --array, the queue call $f" eval '
			rc_is 0 && calls_are 1 1 0 1 && has "recently finished · last 2h" && argv_has sacct --array && argv_lacks sacct -r && argv_has squeue -h -S t,i -r'
	done
	local q
	for f in --noconvert:--noconvert --priority:-P -P:-P; do
		q=${f#*:} f=${f%%:*}
		sq_run empty -- "$f"
		need "$f: rc 0, the block from sacct, which got neither it nor --array, the queue call $q" eval '
			rc_is 0 && calls_are 1 1 0 1 && has "recently finished · last 2h" && argv_lacks sacct "$f" && argv_lacks sacct "$q" && argv_lacks sacct --array && argv_has squeue -h -S t,i "$q"'
	done
	for f in SQUEUE_ARRAY=1 SQUEUE_ARRAY=; do
		sq_run empty "$f" --
		need "$f: rc 0, the block from sacct, which got --array" eval '
			rc_is 0 && calls_are 1 1 0 1 && has "recently finished · last 2h" && argv_has sacct --array'
	done
	sq_run empty --
	need "neither: sacct without --array" eval 'rc_is 0 && calls_are 1 1 0 1 && argv_lacks sacct --array'
	for f in --hide:--hide --all:-a; do
		q=${f#*:} f=${f%%:*}
		sq_run empty -- "$f"
		need "$f: rc 0, the block from sacct as without it, the queue call $q" eval '
			rc_is 0 && calls_are 1 1 0 1 && has "recently finished · last 2h" && argv_lacks sacct "$f" && argv_has squeue -h -S t,i "$q"'
	done
	sq_run empty -- --local
	need "--local: rc 0, the block from sacct, which got --local" eval '
		rc_is 0 && calls_are 1 1 0 1 && has "recently finished · last 2h" && argv_has sacct --local && argv_has squeue -h -S t,i --local'
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
	need "--states=R forwarded as -t R" argv_has squeue -h -S t,i -t R
}
# A state filter is the queue's alone (Franz's decision): the finished block
# shows every finished job.  sacct never gets it, and the fallback puts its own
# -t all last, as squeue keeps the last -t; it used to come first, so -t R
# also emptied the fallback's finished block
fallback_t_all_last() {   # the fallback call's arguments end in "-t all"
	gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && (" " $3) ~ / -t all / { n++; if ($3 ~ / -t all $/) last++ }
		END { exit !(n == 1 && last == 1) }' "$LOG"
}
c_state_filter_queue_only() {
	T_TITLE="-t filters the queue only: the finished block from sacct as without it, and the fallback's own -t all comes last"
	local t
	for t in "-t R" "-tR" "--states=R" "--state R"; do
		sq_run mixed -- $t
		need "$t: rc 0, stderr empty, sacct and no fallback" eval 'rc_is 0 && err_empty && calls_are 1 1 0 1'
		need "$t: the queue call has it as -t R, sacct not" eval 'argv_has squeue -h -S t,i -t R && ! grep "^CALL	sacct" "$LOG" | grep -qE " (-t|--states?)"'
		need "$t: finished row 1001, the caption of no filter" eval 'rows recent | grep -qE "^ +1001 +done +COMPLETED " && has "recently finished · last 2h" && lacks "translate"'
	done
	sq_run noacct -- -t R
	need "no accounting, -t R: rc 0, the fallback, its -t all after -t R" eval 'rc_is 0 && calls_are 1 1 1 1 && argv_has squeue -h -t R -t all && fallback_t_all_last'
	need "... and its three finished rows" eval '[ "$(nrows recent)" -eq 3 ] && has "recently finished · recent only (no accounting)"'
	sq_run noacct -- -t R -n x
	need "-t R -n x: the fallback for -n, its -t all last, the caption names -n" eval '
		rc_is 0 && calls_are 1 1 1 0 && fallback_t_all_last && [ "$(nrows recent)" -eq 3 ] && has "recent only (sq does not translate -n for sacct)"'
}
c_accept_S_empty() {
	T_TITLE="-S '' accepted (rc 0) and forwarded as given; the sort is squeue's alone, sacct as without it"
	sq_run empty -- -S ''
	need "rc 0"                       rc_is 0
	need "stderr empty"               err_empty
	need "forwarded after sq's own sort" argv_has squeue -h -S t,i -S ''
	need "sacct as without it, no fallback" calls_are 1 1 0 1
	need "caption of no filter"       has "recently finished · last 2h"
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
# in (see section 12).  Height: FULL shows every finished job whatever the
# height, so the height is read through --compact.  With 34 finished jobs (30
# single, and an older 4-task array that folds into one row) and no
# SQ_RECENT_MAX the finished block takes what the screen has left, so the
# output fills the height exactly; the
# array is the oldest, so it is never shown, and "+N more" must count its 4 tasks:
# the JOBS shown (a ×K row is K) plus "+N more" account for all 34.
jobs_shown() { rows recent | LC_ALL=$utf8 gawk '{ n += ($2 ~ /^×[0-9]+$/) ? substr($2, 2) : 1 } END { print n+0 }'; }
fills() {     # fills HEIGHT: the output is HEIGHT lines and accounts for all 34 jobs
	[ "$(plain | wc -l)" -eq "$1" ] && ! row_first_fields recent | grep -q "^5000_" &&
	[ $(( $(jobs_shown) + $(more_count) )) -eq 34 ]
}
c_layout_size() {
	T_TITLE="in a pipe: SQ_WIDTH, COLUMNS, SQ_HEIGHT and LINES set the layout (the height through --compact)"
	sq_run wide SQ_WIDTH=123 --
	need "SQ_WIDTH=123: widest line 123"  eval 'calls_are 1 1 0 1 && [ "$(width)" -eq 123 ]'
	sq_run wide SQ_WIDTH=123 COLUMNS=90 --
	need "SQ_WIDTH beats COLUMNS"         eval 'calls_are 1 1 0 1 && [ "$(width)" -eq 123 ]'
	sq_run wide -SQ_WIDTH COLUMNS=110 --
	need "COLUMNS=110: widest line 110"   eval 'calls_are 1 1 0 1 && [ "$(width)" -eq 110 ]'
	sq_run many-finished SQ_HEIGHT=20 -- --compact
	need "SQ_HEIGHT=20: 20 lines, 34 jobs accounted, the hidden array in +N more" eval 'calls_are 1 1 0 1 && fills 20'
	sq_run many-finished SQ_HEIGHT=30 -- --compact
	need "SQ_HEIGHT=30: 30 lines, 34 jobs accounted, the hidden array in +N more" eval 'calls_are 1 1 0 1 && fills 30'
	sq_run many-finished -SQ_HEIGHT LINES=20 -- --compact
	need "LINES=20: 20 lines, 34 jobs accounted, the hidden array in +N more" eval 'calls_are 1 1 0 1 && fills 20'
	sq_run many-finished SQ_HEIGHT=20 LINES=30 -- --compact
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
		! { rows queue | grep -q "^ *7001_" && section footer | grep -qE "^ *1 jobs? "; }'
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
		! { rows queue | grep -q "^ *11137_" && section footer | grep -qE "^ *1 jobs? "; }'
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
# Under LC_ALL=C length() counts bytes and "…" is 3, so the elision measures
# it rather than assuming 1.  sq now runs gawk under a UTF-8 locale whenever one
# exists (locale_pinned compares whole screens), so this guard on the elided id,
# its exact ×N in valid UTF-8, holds for that path; a host without any UTF-8
# locale, where the bytes are counted, is not one the suite can make.
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
# gawk counts characters only under a UTF-8 locale, and cron, systemd and
# containers run sq under C or none at all: under C the old build cut the id
# cell at another width (and split a character at some).  sq pins a UTF-8
# locale for gawk, so the screen, colour and all, is the one the UTF-8 caller
# gets: an elided id, the shrink ladder, bar glyphs, a COMPACT "… n jobs".
# Where no locale tool answers (musl has none) gawk alone judges a locale: a
# failing one first on PATH stands in for it
without_clock() { sed -E '1s/[0-9]{2}:[0-9]{2}:[0-9]{2}//' "$1"; }
# a start estimate's clock and date on stdin masked: it is the stub's \{now+3h},
# so a minute (or a day) rolling over between two runs moves it
mask_estimates() { sed -E 's/→ ([A-Z][a-z]{2}[0-9]{2} )?[0-9]{2}:[0-9]{2}/→ \1HH:MM/g; s/→ [0-9]{4}-[0-9]{2}-[0-9]{2}/→ DATE/g'; }
c_locale_pinned() {
	T_TITLE="under LC_ALL=C, and with no locale set at all, sq draws byte for byte the screen it draws under UTF-8, also where the locale tool fails"
	local fx args want how nolocale=$T_DIR/nolocale
	mkdir -p "$nolocale"
	printf '#!/bin/sh\necho "locale: not found" >&2\nexit 127\n' > "$nolocale/locale"; chmod +x "$nolocale/locale"
	for args in "shrink-pending SLURM_BITSTR_LEN=0 SQ_WIDTH=79" "shrink-pending SLURM_BITSTR_LEN=0 SQ_WIDTH=80" \
	            "shrink-finished SLURM_BITSTR_LEN=0 SQ_WIDTH=50" "shrink-finished SLURM_BITSTR_LEN=0 SQ_WIDTH=80" \
	            "bars-busy SQ_WIDTH=60" "bars-busy SQ_WIDTH=100" "busy24 SQ_WIDTH=100 SQ_HEIGHT=24"; do
		set -- $args; fx=$1; shift
		sq_run "$fx" "$@" -- --color --compact
		want=$RUN/screen.utf8; without_clock "$OUT" > "$want"
		for how in LC_ALL=C -LC_ALL; do
			sq_run "$fx" "$@" "$how" -- --color --compact
			need "$args, $how: rc 0, the UTF-8 screen" eval 'rc_is 0 && cmp -s "$want" <(without_clock "$OUT")'
			sq_run "$fx" "$@" "$how" PATH="$nolocale:$here/bin:$PATH" -- --color --compact
			need "$args, $how, the locale tool failing: rc 0, stderr empty, the UTF-8 screen" \
				eval 'rc_is 0 && err_empty && cmp -s "$want" <(without_clock "$OUT")'
		done
	done
}
# Where the locale tool fails (musl has none) gawk's own count alone judges a
# locale, and a caller's ja_JP.eucJP counts "…" as one character too: only
# "…█" (3 there, 2 under UTF-8) tells it apart, so sq pins C.UTF-8 and draws
# the UTF-8 screen.  The locale is built as wide_c_mode builds it
c_locale_eucjp_notool() {
	T_TITLE="LC_ALL=ja_JP.eucJP with the locale tool failing: the UTF-8 screen byte for byte, stderr empty"
	local loc=$T_DIR/loc nolocale=$T_DIR/nolocale want args fx
	mkdir -p "$loc" "$nolocale"
	printf '#!/bin/sh\necho "locale: not found" >&2\nexit 127\n' > "$nolocale/locale"; chmod +x "$nolocale/locale"
	localedef -i ja_JP -f EUC-JP "$loc/ja_JP.eucJP" > /dev/null 2>&1
	if ! [ "$(LOCPATH=$loc LC_ALL=ja_JP.eucJP locale charmap 2>/dev/null)" = EUC-JP ]; then
		T_FAIL+=("localedef could not build ja_JP.eucJP (needs glibc's locale sources)"); sq_run mixed --; return
	fi
	for args in "shrink-pending SLURM_BITSTR_LEN=0 SQ_WIDTH=79" "bars-busy SQ_WIDTH=60"; do
		set -- $args; fx=$1; shift
		sq_run "$fx" "$@" -- --color --compact; want=$RUN/screen.utf8; without_clock "$OUT" > "$want"
		sq_run "$fx" "$@" LC_ALL=ja_JP.eucJP LOCPATH="$loc" "PATH=$nolocale:$here/bin:$PATH" -- --color --compact
		need "$args: rc 0, stderr empty, the UTF-8 screen byte for byte" eval 'rc_is 0 && err_empty && cmp -s "$want" <(without_clock "$OUT")'
	done
}
# A caller's LC_ALL may name a locale that is not installed.  bash says so
# once as it starts, which sq cannot help; sq itself must add nothing, since
# watch shows stderr on the screen.  "LC_ALL=x cmd" in sq's shell made bash
# warn again each time it put the caller's value back.
c_locale_missing() {
	T_TITLE="LC_ALL naming no installed locale: the UTF-8 screen, and on stderr only bash's own warning as it starts; sq log and sq job on a job Slurm forgot, and sq job on one whose parent it forgot, add only their own note"
	local bad=sq_TEST.UTF-8 want noop=$T_DIR/noop d=$T_DIR/fx-forgot purged
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 --
	want=$RUN/screen.utf8; without_clock "$OUT" > "$want"
	printf '#!/usr/bin/env bash\n:\n' > "$noop"; chmod +x "$noop"
	env -i PATH="$here/bin:$PATH" LC_ALL=$bad "$noop" 2> "$T_DIR/startup"
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 LC_ALL=$bad --
	need "rc 0, the UTF-8 screen"     eval 'rc_is 0 && cmp -s "$want" <(without_clock "$OUT")'
	# every line, not the whole: a wrapper given as SQ_UNDER_TEST starts a bash too
	need "stderr: only the line bash prints starting any script" eval '! grep -qvxFf "$T_DIR/startup" "$ERR"'
	# the three answers sq reads for "Invalid job id specified" (by env LC_ALL=C grep)
	mkdir -p "$d"
	printf '@stderr slurm_load_jobs error: Invalid job id specified\n@exit 1\n' > "$d/squeue-all"
	printf '@include %s\n' "$fixtures/_common/sacct-defaults" > "$d/sacct"
	sq_run "$d" LC_ALL=$bad -- log 500
	purged="sq log: Slurm does not know job 500 (it ended more than about 5 minutes ago, or never existed), so its output path is unknown"
	need "sq log on a job Slurm forgot: rc 1, stderr bash's line and the note alone" eval '
		rc_is 1 && [ "$(grep -vxFf "$T_DIR/startup" "$ERR")" = "$purged" ]'
	sq_run "$d" LC_ALL=$bad -- job 500
	need "sq job on a job Slurm forgot: rc 1, stderr bash's line and the note alone" eval '
		rc_is 1 && [ "$(grep -vxFf "$T_DIR/startup" "$ERR")" = "sq job: Slurm does not know job 500 (neither the queue nor accounting has it)" ]'
	d=$(dep_fx forgot 'afterok:900(unfulfilled)' '@stderr slurm_load_jobs error: Invalid job id specified' '@exit 1')
	why_run "$d" LC_ALL=$bad -- --no-color job 800
	need "sq job on a job whose parent Slurm forgot: rc 0, the parent unknown to Slurm, stderr bash's line alone" eval '
		rc_is 0 && why_has "    900  Slurm no longer knows it" && ! grep -qvxFf "$T_DIR/startup" "$ERR"'
}
# The same, over every screen: the dashboard on each fixture and sq job's tail
# of a failed job (its reader of the last bytes ran as "LC_ALL=C gawk" inside
# $(...), which bash answered with a setlocale warning): nothing on stderr names
# setlocale but the line bash prints as it starts.
c_locale_missing_screens() {
	T_TITLE="LC_ALL naming no installed locale: the dashboard on every fixture and sq job's tail of failed1, failed127 and sigill-recent, sq log with a failing tail print no setlocale warning of sq's own"
	local bad=xx_YY.UTF-8 noop=$T_DIR/noop dir fx id
	printf '#!/usr/bin/env bash\n:\n' > "$noop"; chmod +x "$noop"
	env -i PATH="$here/bin:$PATH" LC_ALL=$bad "$noop" 2> "$T_DIR/startup"
	for dir in "$fixtures"/*/; do
		fx=${dir%/}; fx=${fx##*/}
		case $fx in _common|sqjob) continue ;; esac
		sq_run "$fx" LC_ALL=$bad -- --full
		need "$fx: no setlocale on stderr but bash's own line" eval '! grep -vxFf "$T_DIR/startup" "$ERR" | grep -q setlocale'
	done
	for fx in failed1-11837 failed127-11836 sigill-recent-11353; do
		id=${fx##*-}
		why_run "$fx" LC_ALL=$bad -- --no-color job "$id"
		need "sq job $id: its tail read, no setlocale on stderr but bash's own line" eval '
			why_lines | grep -q " ends with:$" && ! grep -vxFf "$T_DIR/startup" "$ERR" | grep -q setlocale'
	done
	# sq log reads the first line of a failing tail's stderr (log_tail_verdict):
	# a tail that fails reading the file, --no-follow
	local tbin=$T_DIR/tbin
	mkdir -p "$tbin"
	printf '#!/bin/sh\necho "tail: error reading %s: Input/output error" >&2\nexit 1\n' "'x'" > "$tbin/tail"; chmod +x "$tbin/tail"
	sq_run "$(log_fx tailfail <<'EOF'
StateCompact=R
@file create wd/out_500.log a\n
EOF
)" LC_ALL=$bad PATH="$tbin:$here/bin:$PATH" -- log --no-follow 500
	need "sq log, its tail failing: rc 1, tail's reason, no setlocale on stderr but bash's own line" eval '
		rc_is 1 && [ "$(grep -vxFf "$T_DIR/startup" "$ERR")" = "sq log: tail: error reading '"'"'x'"'"': Input/output error" ]'
}
# A multibyte locale is not a UTF-8 one: under ja_JP.eucJP gawk counts "…" as
# one character, as UTF-8 does, but "█" as two, and warns of invalid data on
# stderr: that locale passed a probe that only measured "…".
# glibc has no such locale installed by default, so the case builds one with
# localedef (glibc's own) where only this run's LOCPATH can see it.
c_locale_not_utf8() {
	T_TITLE="LC_ALL=ja_JP.eucJP is no UTF-8 locale: sq draws byte for byte the UTF-8 screen, with nothing on stderr"
	local loc=$T_DIR/loc args want
	mkdir -p "$loc"; localedef -i ja_JP -f EUC-JP "$loc/ja_JP.eucJP" > /dev/null 2>&1
	if ! [ "$(LOCPATH=$loc LC_ALL=ja_JP.eucJP locale charmap 2>/dev/null)" = EUC-JP ]; then
		T_FAIL+=("localedef could not build ja_JP.eucJP (needs glibc's locale sources)"); return
	fi
	for args in "bars-busy SQ_WIDTH=100" "shrink-pending SLURM_BITSTR_LEN=0 SQ_WIDTH=79"; do
		set -- $args
		sq_run "$@" -- --color
		want=$RUN/screen.utf8; without_clock "$OUT" > "$want"
		sq_run "$@" LC_ALL=ja_JP.eucJP LOCPATH="$loc" -- --color
		need "$args: rc 0, the UTF-8 screen" eval 'rc_is 0 && cmp -s "$want" <(without_clock "$OUT")'
		need "$args: stderr empty"    err_empty
	done
}
# The start estimate names its month in English whatever the caller's locale
# (Franz, 2026-10-22: "Always English").  strftime's %b said "Okt" under
# de_DE, a wide "10月" under ja_JP.UTF-8, and where LC_CTYPE is UTF-8 but
# LC_TIME is not (LANG=ja_JP.eucJP LC_CTYPE=C.UTF-8) put that locale's raw
# bytes on the screen and gawk's "Invalid multibyte data" on stderr.  Job 1103
# starts tomorrow, which reads "Oct23 14:05", unless tomorrow is next year: a
# date then, with no month name to check.  The locales are built as in
# locale_not_utf8.
month_row() {   # month_row: job 1103's row holds its start as an English month, day and time
	local en='(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[0-3][0-9] [0-2][0-9]:[0-5][0-9]'
	[ "$(TZ=UTC date -d '+1 day' +%Y)" = "$(TZ=UTC date +%Y)" ] || en='[0-9]{4}-[0-9]{2}-[0-9]{2}'
	rows queue | grep -E "^ *1103 " | grep -qE "(^| )$en( |$)"
}
c_month_english() {
	T_TITLE="the start estimate's month in English under de_DE.UTF-8, de_DE.ISO-8859-1, ja_JP.UTF-8 and a non-UTF-8 LC_TIME: valid UTF-8, stderr empty"
	local loc=$T_DIR/loc l src charmap name fx how
	mkdir -p "$loc"
	for l in de_DE:UTF-8:de_DE.UTF-8 de_DE:ISO-8859-1:de_DE.ISO-8859-1 ja_JP:UTF-8:ja_JP.UTF-8 ja_JP:EUC-JP:ja_JP.eucJP; do
		IFS=: read -r src charmap name <<< "$l"
		localedef -i "$src" -f "$charmap" "$loc/$name" > /dev/null 2>&1
		if ! [ "$(LOCPATH=$loc LC_ALL=$name locale charmap 2>/dev/null)" = "$charmap" ]; then
			T_FAIL+=("localedef could not build $name (needs glibc's locale sources)"); return
		fi
	done
	fx=$(mem_fixture mixed squeue "$(sed 's/S=\\{now+400d}/S=\\{now+1d}/' "$fixtures/mixed/squeue" | sed "s|^@include \.\./|@include $fixtures/|")")
	for how in LC_ALL=C.UTF-8 LC_ALL=de_DE.UTF-8 LC_ALL=de_DE.ISO-8859-1 LC_ALL=ja_JP.UTF-8 \
	           "-LC_ALL LANG=C.UTF-8 LC_TIME=de_DE.UTF-8" "-LC_ALL LANG=ja_JP.eucJP LC_CTYPE=C.UTF-8" \
	           "-LC_ALL LANG=de_DE.ISO-8859-1 LC_CTYPE=C.UTF-8"; do
		sq_run "$fx" $how LOCPATH="$loc" --
		need "$how: rc 0, stderr empty, valid UTF-8, job 1103 starts on an English month" \
			eval 'rc_is 0 && err_empty && utf8_valid && month_row'
	done
}
# POSIXLY_CORRECT in the caller's environment once put bash in POSIX mode and
# made every gawk a --posix one: the dashboard exited 1 with nothing on
# stdout, and sq job died on a newline in a gawk string
c_posixly_correct() {
	T_TITLE="POSIXLY_CORRECT=1: the dashboard, sq job and sq log print what they print without it"
	local want fx
	sq_run mixed --
	want=$RUN/screen; without_clock "$OUT" > "$want"
	sq_run mixed POSIXLY_CORRECT=1 --
	need "dashboard: rc 0, stderr empty, the same screen" eval 'rc_is 0 && err_empty && cmp -s "$want" <(without_clock "$OUT")'
	job_run finished-11912 -- --no-color job 11912
	want=$RUN/report; cp "$OUT" "$want"
	job_run finished-11912 POSIXLY_CORRECT=1 -- --no-color job 11912
	need "sq job: rc 0, stderr empty, the same report" eval 'rc_is 0 && err_empty && job_is "$want"'
	fx=$(log_fx posix <<'EOF'
StateCompact=CD
@file create wd/out_500.log line\n
EOF
)
	sq_run "$fx" POSIXLY_CORRECT=1 -- log --no-follow 500
	need "sq log: rc 0, the file, and the note it prints without it" eval 'rc_is 0 && out_is "line
" && err_is "sq log: job 500 ended: COMPLETED (exit code 0:0)"'
}
# WSL steps its clock back about 1.5 s every 30 s, so between the stub's answer
# and sq reading the clock a second can go missing: a job that ended exactly
# 12h before the stub ran then reads 11h, and a case comparing two runs'
# screens failed now and then.  So every end a dashboard fixture gives sits
# mid-bucket (12h30m, 3m30s), and a step of 2 s either way (SQSTUB_SKEW) draws
# the same screen
c_clock_step() {
	T_TITLE="every fixture with a relative time draws the same screen when the clock steps 2 s back or forward after the stub answered, a start estimate's clock and date aside"
	local dir fx want skew
	for dir in "$fixtures"/*/; do
		fx=${dir%/}; fx=${fx##*/}
		case $fx in _common|sqjob) continue ;; esac
		grep -qE '\\\{(now|epoch)|_common/(sacct|squeue-all)-defaults' "$dir"* 2>/dev/null || continue
		# a start estimate moves with the stub's clock (it is \{now+3h} too), and
		# its HH:MM with it whenever a minute edge falls between the runs
		sq_run "$fx" -- --full --color
		want=$RUN/screen; without_clock "$OUT" | mask_estimates > "$want"
		for skew in -2 2; do
			sq_run "$fx" SQSTUB_SKEW=$skew -- --full --color
			need "$fx, the clock stepped ${skew}s: the same screen, start estimates aside" eval 'cmp -s "$want" <(without_clock "$OUT" | mask_estimates)'
		done
	done
}
# W4/V5 (why-v2): an age from 48 h on reads in days and hours, as elap()
# prints a day, where hours alone ran to 8736h; below 48 h byte for byte as
# before.  The dashboard shows one only when SQ_SINCE reaches back that far
c_ago_days() {
	T_TITLE="the finished block's AGO from 48 h on in days and hours (2d02h, a group's range too), below 48 h as before (47h)"
	local d=$T_DIR/fx; mkdir -p "$d"
	printf '@include %s\n' "$fixtures/_common/sinfo-two-idle" > "$d/sinfo"
	: > "$d/squeue"
	cat > "$d/sacct" <<EOF
@include $fixtures/_common/sacct-defaults
JobID=701; JobName=new; End=\{now-47h30m}
JobID=702; JobName=old; End=\{now-50h30m}
JobID=703_0; JobName=arr; End=\{now-77h30m}
JobID=703_1; JobName=arr; End=\{now-47h10m}
EOF
	sq_run "$d" SQ_SINCE=now-5days -- --full
	need "rc 0, stderr empty" eval 'rc_is 0 && err_empty'
	need "47h30m ago: 47h" eval 'rows recent | grep -qE "^ +701 +new +COMPLETED .* 47h$"'
	need "50h30m ago: 2d02h" eval 'rows recent | grep -qE "^ +702 +old +COMPLETED .* 2d02h$"'
	need "a group from 47h10m to 77h30m ago: 47h-3d05h" eval 'rows recent | grep -qE "^ +703_\[0-1\] ×2 +arr +COMPLETED .* 47h-3d05h$"'
}
# V15 (why-v2): the cancellers' names come from one getent call through
# collect, shared with sq job: bounded by SQ_TIMEOUT like any Slurm call
c_cancel_names() {
	T_TITLE="a canceller's uid reads as getent's name for it, from one bounded getent call; a hanging getent leaves the uid"
	local d=$T_DIR/fx; mkdir -p "$d"
	printf '@include %s\n' "$fixtures/_common/sinfo-two-idle" > "$d/sinfo"
	: > "$d/squeue"
	cat > "$d/sacct" <<EOF
@include $fixtures/_common/sacct-defaults
JobID=801; JobName=killed; State=CANCELLED by 1025; End=\{now-15m30s}
JobID=802; JobName=gone; State=CANCELLED by 1077; End=\{now-16m30s}
EOF
	printf 'bob:x:1025:1025::/home/bob:/bin/bash\n' > "$d/passwd"
	sq_run "$d" -- --full
	need "rc 0; 1025 is bob, 1077 unknown stays a uid; one getent call for both" eval '
		rc_is 0 && err_empty && rows recent | grep -qE "^ +801 +killed +CANCELLED +0 by bob " &&
		rows recent | grep -qE "^ +802 +gone +CANCELLED +0 by 1077 " && [ "$(grep -c "^CALL	getent" "$LOG")" = 1 ] &&
		grep -qx "CALL	getent	passwd 1025 1077" "$LOG"'
	printf '@hang 20\nbob:x:1025:1025::/home/bob:/bin/bash\n' > "$d/passwd"
	sq_run "$d" SQ_TIMEOUT=1 -- --full
	need "getent hanging: within SQ_TIMEOUT, the uids, nothing left" eval '
		rc_is 0 && rows recent | grep -qE "^ +801 +killed +CANCELLED +0 by 1025 " && [ -z "$(ls -A "$RUN/tmp")" ]'
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
	# WHOLE (R-M3, H6): FULL keeps the long state, so at 50 JOBID takes F2's next forms
	need "50: cell '600_… ×67' beside CANCELLED" eval 'row_cell recent "600_… ×67" && rows recent | grep -qE "^ *600_.* CANCELLED "'
	need "50: cell '5000_…' beside FAILED"     eval 'row_cell recent "5000_…" && rows recent | grep -qE "^ *5000_.* FAILED "'
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
	T_TITLE="JOBID exactly BASE_[…] ×N wide reads 6000000_[…] ×67; one narrower, BASE_… ×N (DISPLAY-v4 F2), the base id and the count whole"
	local fx; fx=$(pending_fixture floor "6000000_[$shrink_ids]")
	sq_run "$fx" SLURM_BITSTR_LEN=0 SQ_WIDTH=25 -- -o i,T
	need "25: rc 0"                   rc_is 0
	need "25: stubs called"           calls_are 1 1 0 1
	need "25: cell '6000000_[…] ×67'" row_cell queue "6000000_[…] ×67"
	need "25: footer 67/0/67/0"       footer_is 67 0 67 0
	sq_run "$fx" SLURM_BITSTR_LEN=0 SQ_WIDTH=24 -- -o i,T
	need "24: rc 0"                   rc_is 0
	need "24: cell '6000000_… ×67', F2's next form" row_cell queue "6000000_… ×67"
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
		t ~ /^([0-9]+|\?) jobs? +([0-9]+|\?) running / { print "FOOTER\t" t; zone = ""; next }
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
centred_in()   { # centred_in H: under int((H - its length) / 2) blank lines, at least one
	local body top; body=$(plain | sed '/./,$!d' | wc -l); top=$(( $(plain | wc -l) - body ))
	[ "$top" -gt 0 ] && [ "$top" -eq $(( ($1 - body) / 2 )) ]
}
lines_within() { [ "$(plain | wc -l)" -le "$1" ]; }
blanks_are()   { [ "$(labelled BLANK | wc -l)" -eq "$1" ]; }
footer_last()  { # footer_last JOBS RUNNING PENDING OTHER: the one footer, on the last line
	[ "$(labelled FOOTER | wc -l)" -eq 1 ] &&
	plain | tail -n 1 | grep -qE "^ *$1 $(jobs_noun "$1") +$2 running +$3 pending +$4 other\$"
}
# the title is "▌ SLURM <host>  HH:MM:SS ZONE", nothing more, whatever the host is called
# (CALL (made inside the target screens, listed to Franz, overrulable): no "· compact" mode marker)
title_first()  { screen | head -n 1 | grep -qE '^TITLE'$'\t''▌ SLURM [^ ]+  [0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+$'; }
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
without_clock_ago() { sed -E '1s/[0-9]{2}:[0-9]{2}:[0-9]{2} [^ ]+$//; s/ +([0-9]+d[0-9]{2}h|[0-9]+[smh]|-)$//' "$1"; }

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
	need "the nodes as one summary line"  nodes_digest "nodes: 1 allocated, 1 down* · 128/256 cpu · 443/1006G mem"
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
c_compact_filter_line() {   # decision 29
	T_TITLE="noacct at 24 lines with --reservation=x: a filter sacct cannot express sends the block to the fallback, and the one line says so"
	sq_run noacct SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact --reservation=x
	need "rc 0, stderr empty, squeue and its -t all fallback, no sacct" eval 'rc_is 0 && err_empty && calls_are 1 1 1 0'
	need "at most 24 lines, footer last" eval 'lines_within 24 && footer_last 151 128 23 0'
	need "the one line names the filter and the newest failure" \
		fin_line_is "recently finished (sq does not translate --reservation for sacct): 4188 qc FAILED 1"
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
# throttled: a throttled array waits with JobArrayTaskLimit, which is ordinary
# waiting (decision 28): its 8 tasks are counted in "… n jobs pending", no row
c_compact_throttled() {   # decision 28
	T_TITLE="throttled at 12 lines: the 8 tasks waiting with JobArrayTaskLimit are counted in '… 9 jobs pending', no row of them"
	compact_case throttled 100 12 "1 1 0 1" "11 2 9 0"
	need "the pending ones only in '… 9 jobs pending', before the running row" queue_seq_is "… 9 jobs pending|8000_[0-1]"
	local totals="stuck=0 blocked=0 held=0 pending=9 running=2 other=0"
	need "counted as pending, none as stuck, and every section adds up" eval 'census_says "$totals" 12 rows "stuck=0 blocked=0 held=0 pending=0 running=1 other=0 finished=0 nodes=2" && census_says "$totals" 12 acct ""'
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
		# collapses, and JobArrayTaskLimit, decision 28) is ordinary pending, and
		# so are the holds Slurm sets on a requeue, which the owner releases
		# (why-v2 V8); node reasons and the other cluster faults are blocked;
		# JobHeldAdmin is held; EVERY OTHER reason is stuck, visible by default, so a
		# misread or unknown reason fails loud (NodeDrain, which 23.11 does not
		# have, among them).  The reason is what the NODE/REASON cell
		# shows inside its parentheses (to the cell'"'"'s end, if the cell was cut).
		function sec(t,   m, r) {
			if (t ~ / RUNNING /) return "running"
			if (t !~ / PENDING /) return "other"
			r = match(t, /\(([^)]*)/, m) ? m[1] : ""
			if (r ~ /^(None|Priority|Resources|Dependency|BeginTime|Prolog|Cleaning|SchedDefer|Reservation|Licenses|JobHeldUser|JobArrayTaskLimit)$/) return "pending"
			if (r ~ /requeued held$/ || r ~ /^job requeued in /) return "pending"
			if (r ~ /^ReqNodeNotAvail/ || r ~ /^Nodes required for job are / ||
			    r ~ /^(NodeDown|PartitionDown|PartitionInactive|FrontEndDown|PowerNotAvail|PowerReserved)$/) return "blocked"
			if (r == "JobHeldAdmin") return "held"
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
# blocked on nodes; a launch failure requeued held and a job requeued in held
# state are pending, held for their owner to release (why-v2 V8: Slurm sets
# its user hold, WAIT_HELD_USER), and
# NodeDrain, no reason 23.11 has, is unknown and so stuck
c_compact_sweep_faults() {
	T_TITLE="faults at every height 6..50: partition, front-end and power faults count as blocked on nodes, 'launch failed requeued held' and 'job requeued in held state' as pending (the owner's hold), NodeDrain as stuck; every sweep invariant"
	sweep_case faults 100 50 "1 1 0 1" "22 8 14 0" \
		"stuck=1 blocked=6 held=0 pending=7 running=8 other=0" "recently finished: 600 qc FAILED 1"
	sq_run faults SQ_WIDTH=100 SQ_HEIGHT=17 -- --compact
	need "17 lines: PartitionDown blocked, NodeDrain stuck, 604, 610 and 614 (requeued held) in '… 7 jobs pending', no held section" \
		queue_seq_is "601|608|… 5 jobs blocked on nodes|… 7 jobs pending|626|627|… 6 jobs running"
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
# FULL shows every finished job: the window (SQ_SINCE) bounds the block, not
# the height.  It used to be cut to the lines the rest left, at most 25 rows,
# which hid an old failure behind "+N more" (Franz, 2026-10-15)
c_full_recent_fits() {
	T_TITLE="FULL at every height 6..50 shows every finished job: the screen of height 100, no '+N more'"
	local fx h off tall
	for fx in oldfail many-finished; do
		sq_run "$fx" SQ_HEIGHT=100 -- --full
		need "$fx at 100: rc 0, no '+N more'" eval 'rc_is 0 && [ -z "$(more_count)" ]'
		tall=$RUN/tall; without_clock_ago "$OUT" > "$tall"
		off=
		for h in $(seq 6 50); do
			sq_run "$fx" SQ_HEIGHT="$h" -- --full
			{ rc_is 0 && cmp -s "$tall" <(without_clock_ago "$OUT"); } || off="$off $h"
		done
		need "$fx: the screen of height 100, clock and AGO aside (not at H =${off:- none})" test -z "$off"
	done
	sq_run many-finished SQ_HEIGHT=20 --
	need "many-finished at 20: all 31 rows, 34 jobs, no '+N more'" eval 'rc_is 0 && [ "$(nrows recent)" -eq 31 ] && [ "$(jobs_shown)" -eq 34 ] && [ -z "$(more_count)" ]'
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
# --reserve takes its value as the next word or attached with "=" (decision
# 27): reserve_arg SPELLING VALUE sets RARGS to the arguments that write it
reserve_arg() { if [ "$1" = = ]; then RARGS=("--reserve=$2"); else RARGS=(--reserve "$2"); fi; }
c_reserve_refused() {   # decisions 23 and 27: sq only parses --reserve
	T_TITLE="--reserve -1 / x / '' / 1.5, as the next word or after '=', or no value: refused (rc 2) for the value, before any Slurm call"
	local v sp
	for sp in " " =; do
		for v in -1 x "" 1.5; do
			reserve_arg "$sp" "$v"
			sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact "${RARGS[@]}"
			need_refused "${RARGS[*]} ('$v')"
			need "${RARGS[*]} ('$v'): refused for its value, naming --reserve" eval 'grep -q -- --reserve "$ERR" && ! unknown_option --compact && ! unknown_option --reserve'
		done
	done
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact --reserve
	need_refused "--reserve with no value"
	need "--reserve with no value: names --reserve" eval 'grep -q -- --reserve "$ERR" && ! unknown_option --compact'
	stubs_answer
}
c_compact_reserve() {   # decisions 23 and 27
	T_TITLE="--reserve N and --reserve=N: 0 is no reserve, 2 at 26 lines is the screen of 24, and a reserve leaving one line draws the footer alone"
	compact_case busy24 100 24 "1 1 0 1" "151 128 23 0"
	local seq24 lines24 out24=$OUT sp
	seq24=$(queue_seq); lines24=$(plain | wc -l)
	for sp in " " =; do
		reserve_arg "$sp" 0
		sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact "${RARGS[@]}"
		need "${RARGS[*]}: the same screen as no --reserve, clock and AGO aside" eval 'rc_is 0 && cmp -s <(without_clock_ago "$out24") <(without_clock_ago "$OUT")'
		reserve_arg "$sp" 2
		sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=26 -- --compact "${RARGS[@]}"
		need "${RARGS[*]} at 26 lines: rc 0, footer last" eval 'rc_is 0 && footer_last 151 128 23 0'
		need "${RARGS[*]} at 26 lines: the queue and line count of 24 lines" eval '[ "$(queue_seq)" = "$seq24" ] && [ "$(plain | wc -l)" -eq "$lines24" ]'
		reserve_arg "$sp" 23
		sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact "${RARGS[@]}"
		need "${RARGS[*]} at 24 lines: rc 0, stubs called" eval 'rc_is 0 && calls_are 1 1 0 1'
		need "${RARGS[*]} at 24 lines: the footer line alone" eval '[ "$(plain | wc -l)" -eq 1 ] && footer_last 151 128 23 0'
	done
}
c_reservation_forwarded() {   # decision 23's caveat: no prefix clash with --reserve
	T_TITLE="--reservation=x and --reservation x still reach squeue"
	sq_run empty -- --reservation=x
	need "=x: rc 0, sacct skipped for the fallback" eval 'rc_is 0 && calls_are 1 1 1 0'
	need "=x: forwarded as -R x"          argv_has squeue -h -S t,i -R x
	sq_run empty -- --reservation x
	need "x: rc 0, sacct skipped for the fallback" eval 'rc_is 0 && calls_are 1 1 1 0'
	need "x: forwarded as -R x"           argv_has squeue -h -S t,i -R x
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
# ---- G1 (DISPLAY-v4): on a terminal COMPACT leaves the prompt's row free ----
# first_tenth: wait for the first tenth of a second, so two runs started now
# read the same second (a run takes well under 0.9 s at low load)
first_tenth() { local n; for n in $(seq 200); do [ "$(date +%N)" -lt 100000000 ] && return 0; sleep 0.01; done; }
# pty_pipe FIXTURE ROWS COLS "PTY VARS" "PIPE VARS" [sq args]: sq on a ROWS x
# COLS pty (colour by detection), and sq into a pipe with --color and the PIPE
# VARS (watch's COLUMNS and LINES, say), the two started together in the first
# tenth of a second.  PAIR_SAME 1 when they print the same bytes (the pty's CRs
# aside), in this try or one of two more: a relative time (the title clock,
# AGO, ELAPSED, → est) can tick between the two once, a change differs every
# time.  PTY_LINES: the pty's line count, PAIR_RUNS the tries
pty_pipe() {
	local fx=$1 rows=$2 cols=$3 try prun pipe_run; local -a pvars qvars penv pargv
	read -ra pvars <<< "$4"; read -ra qvars <<< "$5"; shift 5
	PAIR_SAME=0 PAIR_RUNS=0
	for try in 1 2 3; do
		sq_env "$fx" TERM=xterm-256color -SQ_WIDTH -SQ_HEIGHT "${pvars[@]}" -- "$@"
		prun=$RUN penv=("${ENVLIST[@]}") pargv=("${SQ_ARGV[@]}")
		sq_env "$fx" TERM=xterm-256color -SQ_WIDTH -SQ_HEIGHT "${qvars[@]}" -- --color "$@"
		pipe_run=$RUN
		first_tenth
		( OUT=$prun/out ERR=$prun/err PTY_ROWS=$rows PTY_COLS=$cols; pty_exec "${penv[@]}" -- "${pargv[@]}"; echo "$RC" > "$prun/rc" ) &
		env -i "${ENVLIST[@]}" "$bound" -k 2 30 "$sq" "${SQ_ARGV[@]}" > "$OUT" 2> "$ERR" < /dev/null; echo $? > "$pipe_run/rc"
		wait $!
		use_pair_run "$pipe_run"; note_run; use_pair_run "$prun"; note_run
		PAIR_RUNS=$try PTY_LINES=$(plain | wc -l)
		tr -d '\r' < "$prun/out" | cmp -s - "$pipe_run/out" && [ "$(cat "$prun/rc")" = 0 ] && [ "$(cat "$pipe_run/rc")" = 0 ] && { PAIR_SAME=1; return; }
	done
}
use_pair_run() { RUN=$1; OUT=$RUN/out ERR=$RUN/err LOG=$RUN/log; RC=$(cat "$RUN/rc"); }
c_compact_prompt_row() {
	T_TITLE="G1: on a terminal COMPACT fits one row less, for the prompt, byte for byte what a pipe prints with watch's COLUMNS and LINES one less; SQ_HEIGHT is exact; FULL unchanged"
	local c fx rows cols want extra
	# FIXTURE ROWS COLS LINES-THE-PTY-PRINTS PTY-VARS (, for none) sq-ARGS
	for c in "noacct 20 80 19 , " "noacct 20 80 19 , -C" "noacct 20 80 17 , --reserve 2" "noacct 20 80 19 LINES=20 " \
	         "busy24 24 100 23 , " "mixed 20 80 18 , " "mixed 20 80 18 , -C" "mixed 30 80 18 , " "mixed 30 80 23 , -C" \
	         "membar-busy 12 120 11 , "; do
		read -r fx rows cols want extra args <<< "$c"; [ "$extra" != , ] || extra=
		read -ra argv <<< "$args"
		pty_pipe "$fx" "$rows" "$cols" "$extra" "COLUMNS=$cols LINES=$((rows - 1))" "${argv[@]}"
		need "$fx ${rows}x$cols${extra:+ $extra}${args:+ $args}: the pty prints what a pipe at COLUMNS=$cols LINES=$((rows - 1)) does (tries: $PAIR_RUNS)" test "$PAIR_SAME" = 1
		need "$fx ${rows}x$cols${extra:+ $extra}${args:+ $args}: $want lines (has $PTY_LINES)" test "$PTY_LINES" = "$want"
	done
	# the height sq measures itself: SQ_HEIGHT empty, or LINES no usable number (the 24-line fallback)
	for c in "SQ_HEIGHT= 19" "LINES=abc 23" "LINES=0 23"; do
		read -r extra want <<< "$c"
		PTY=1 PTY_ROWS=20 PTY_COLS=80 sq_run noacct TERM=xterm-256color -SQ_WIDTH -SQ_HEIGHT "$extra" --
		need "noacct on a 20-row pty, $extra: rc 0, $want lines, the footer last" eval 'rc_is 0 && [ "$(plain | wc -l)" = '"$want"' ] && footer_last 151 128 23 0'
	done
	# SQ_HEIGHT is the height to fill, exactly: as a pipe with it
	pty_pipe noacct 20 80 "SQ_HEIGHT=15" "COLUMNS=80 LINES=20 SQ_HEIGHT=15"
	need "SQ_HEIGHT=15 on a 20-row pty: what a pipe at SQ_HEIGHT=15 prints (tries: $PAIR_RUNS)" test "$PAIR_SAME" = 1
	need "... 15 lines (has $PTY_LINES)" test "$PTY_LINES" = 15
	# ... down to the smallest: 1 the footer alone, 2 the title and the footer, as before
	for h in 1 2; do
		pty_pipe noacct 20 80 "SQ_HEIGHT=$h" "COLUMNS=80 LINES=20 SQ_HEIGHT=$h"
		need "SQ_HEIGHT=$h on a 20-row pty: what a pipe at SQ_HEIGHT=$h prints, $h line(s), the footer last (tries: $PAIR_RUNS, lines: $PTY_LINES)" eval '
			[ "$PAIR_SAME" = 1 ] && [ "$PTY_LINES" = '"$h"' ] && footer_last 151 128 23 0'
	done
	# FULL on a terminal is not fitted: what a pipe prints
	pty_pipe noacct 20 80 "" "COLUMNS=80" --full
	need "--full on a 20-row pty: what a pipe prints with --full (tries: $PAIR_RUNS)" test "$PAIR_SAME" = 1
}
c_display_docs() {
	T_TITLE="DISPLAY-v4's docs: sq -h and the README's --reserve row name the prompt's row, the README's Usage the ssh -qt note (G1 AC5); the README's bars paragraph: CR_CORE's memory in use as █, the dim line naming an unusable figure but FreeMem and CPUsLoad N/A, the summary's ! and ?, its fault states kept longest (E AC7)"
	local readme=${here%/*}/README.md
	sq_run empty -- -h
	need "sq -h: the --reserve line and its prompt row" eval 'rc_is 0 && plain | grep -A1 -E "^ *sq --reserve N +COMPACT leaves N lines of the screen unused$" | tail -n 1 | grep -qE "^ +\(on a terminal one more, for the prompt\)$"'
	need "README: the --reserve row says it" grep -qF '| `--reserve N` | COMPACT leaves N lines of the screen unused, e.g. for `watch`'"'"'s own header (on a terminal one more, for the prompt).' "$readme"
	need "README: Usage, ssh -qt and the closing line, or --reserve 1" eval 'grep -qE "^ssh -qt host sq +# " "$readme" && grep -qF "ssh'"'"'s \"Connection to … closed.\" line takes the row" "$readme" && grep -qF "(or give it --reserve 1)" "$readme"'
	need "README: CR_CORE's memory in use draws as █ in the bar's colours, no ▓ for memory" eval '
		grep -qF "memory in use draws as \`█\` in the bar'"'"'s colours" "$readme" && ! grep -qF "all of it draws as \`▓\`" "$readme"'
	need "README: an unusable figure reads - or · with a dim line naming it, FreeMem and CPUsLoad N/A without it" eval '
		grep -qF "reads \`-\` or \`·\`," "$readme" && grep -qF "with a dim line naming it" "$readme" &&
		grep -qF "except FreeMem and CPUsLoad \`N/A\`, which read unknown without the line" "$readme"'
	need "README: the summary line marks a RealMemory total with !, an unknown sum with ?, keeps the fault states longest" eval '
		grep -qF "marks with \`!\` a total that counts RealMemory for any node" "$readme" && grep -qF "an unknown" "$readme" &&
		grep -qF "sum with \`?\`" "$readme" && grep -qF "states (\`down*\`, \`drained\`, …) are kept longest" "$readme"'
	stubs_answer
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
# oldfail: the newest failure (100) is older than 30 COMPLETED groups, so it lies
# beyond the 25 rows COMPACT gives the finished block.  The one line names it;
# once the block opens (decision 26, "pullin") the failure is its last row and
# "+8 more" counts the newer jobs that did not fit, so it is named at every
# height.  106, the group the cap cuts first, is a 3-task array: a failure
# written over its row instead of shifting it would read "+6 more".
# Reference renders: screens/fincap/pullin-h{30,40,60}.txt (made before 106
# became an array, so they read "+6 more").
c_compact_oldfail() {   # decision 26
	T_TITLE="oldfail at every height 6..60: the newest failure, older than the finished block's cap, is named on screen; once the block opens it is its last row"
	local h ran= lost=
	sq_run oldfail SQ_WIDTH=100 SQ_HEIGHT=50 -- --full
	need "FULL: rc 0, stubs called, footer 1/1/0/0" eval 'rc_is 0 && calls_are 1 1 0 1 && footer_is 1 1 0 0'
	for h in $(seq 6 60); do
		sq_run oldfail SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
		{ rc_is 0 && err_empty && calls_are 1 1 0 1 && lines_within "$h"; } || ran="$ran $h"
		matches '(^ *|: )100 +bad +FAILED +1( |$)' || lost="$lost $h"
	done
	need "rc 0, stderr empty, stubs called, at most H lines (not at H =${ran:- none})" test -z "$ran"
	need "the failure named at every height (not at H =${lost:- none})" test -z "$lost"
	for h in 40 60; do
		sq_run oldfail SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
		need "$h lines: the block is the 24 newest, 130 down to 107, then 100 as its last row, then '+8 more' (106_[0-2] and 101-105)" \
			fin_block_is "recently finished · last 2h" "$(seq -s ' ' 130 -1 107) 100" "+8 more"
		need "$h lines: '+8 more' is the line right after the failure's row" \
			eval 'screen | gawk -F"\t" '"'"'p && $1 == "FMORE" && $2 == "+8 more" { ok = 1 } { p = ($1 == "FROW" && $2 ~ /^100 /) } END { exit !ok }'"'"
	done
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
without_clock_ago_sgr() { sed -E "/SLURM/s/[0-9]{2}:[0-9]{2}:[0-9]{2}//; s/ +([0-9]+d[0-9]{2}h|[0-9]+[smh]|-)($ESC\[[0-9;]*m)?\$//" "$1"; }
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
	# centred vertically, the height FULL believes shows: FULL shows every job at
	# any height, so only the blank lines above tell, and -C draws them only on
	# a screen (COLUMNS and LINES set, as watch does).  LINES is 30, not 24, so
	# the case tells the fixed fallback of 24 from falling back to LINES
	sq_run empty SQ_WIDTH=100 SQ_HEIGHT=24 COLUMNS=100 LINES=30 SQ_CENTER=2 -- --full
	need "FULL empty centred at 24: rc 0, centred in 24 lines" eval 'rc_is 0 && centred_in 24'
	full24=$OUT
	sq_run empty SQ_WIDTH=100 SQ_HEIGHT=3 COLUMNS=100 LINES=30 SQ_CENTER=2 -- --full
	need "FULL empty centred at 3, LINES=30: the screen of 24, not of LINES, clock and AGO aside" \
		eval 'rc_is 0 && cmp -s <(without_clock_ago_sgr "$full24") <(without_clock_ago_sgr "$OUT")'
	for h in 1 2 3 4; do
		sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
		need "$h: rc 0, stubs called, at most $h lines, footer last" eval 'rc_is 0 && calls_are 1 1 0 1 && lines_within '"$h"' && footer_last 151 128 23 0'
	done
	sq_run busy24 SQ_WIDTH=100 SQ_HEIGHT=1 -- --compact
	need "1: the footer alone" lines_are 1
}
# error screens: sinfo failing (the unreachable banner), squeue failing, a cut
# queue stream (qtrunc) and an unreadable one (qbad): at every height the
# screen fits and the footer is the last line, its counts "?" where the job
# list is unknown
error_sweep() {   # error_sweep FIXTURE "CALLS"
	local fx=$1 h fits= foot= wide=
	sq_run "$fx" --
	need "$fx FULL: rc 0, stubs called" eval 'rc_is 0 && calls_are '"$2"
	for h in $(seq 6 30); do
		sq_run "$fx" SQ_WIDTH=100 SQ_HEIGHT="$h" -- --compact
		{ rc_is 0 && lines_within "$h"; } || fits="$fits $h"
		{ [ "$(labelled FOOTER | wc -l)" -eq 1 ] && screen | tail -n 1 | grep -q '^FOOTER'; } || foot="$foot $h"
		[ "$(width)" -le 100 ] || wide="$wide $h"
	done
	need "$fx: rc 0 and at most H lines (not at H =${fits:- none})" test -z "$fits"
	need "$fx: the footer is the last line (not at H =${foot:- none})" test -z "$foot"
	need "$fx: no line wider than 100 (wider at H =${wide:- none})" test -z "$wide"
}
c_compact_error_screens() {
	T_TITLE="COMPACT error screens at every height 6..30: sinfo failing, squeue failing, a cut and an unreadable queue stream fit, footer last"
	error_sweep sinfo-fails "1 1 0 1"
	error_sweep squeue-fails "1 1 0 1"
	error_sweep queue-cut "1 1 0 1"
	error_sweep squeue-garbage "1 1 0 1"
}

# ---- node bars: allocated and in use, against the screens Franz accepted ----
# fixtures/bars-*/nodes-w<W>.{txt,ansi} are the node lines of the accepted target
# screens (2026-10-07) at 120, 80 and 60 columns, without and with colour.  The
# used-memory number is bold like the CPU one (bold red above 95%), as Franz chose
# 2026-10-15; the prototype that drew the screens already printed it so.  These
# clusters schedule memory (AllocMem), so since MEMBAR (2026-10-22) their memory
# bar counts it allocated, re-pinned so; the in-use bar is membar-crcore's.
node_lines() {    # the node block: after the blank below the title, up to the next blank
	gawk 'b == 1 && $0 == "" { exit } b == 1 { print } $0 == "" { b++ }' "$OUT"
}
node_lines_are() { node_lines | cmp -s - "$1"; }
bars_screens() {  # bars_screens SITUATION: its six screens, byte for byte
	local w ext
	for w in 120 80 60; do
		for ext in txt ansi; do
			sq_run "bars-$1" SQ_WIDTH=$w SQ_HEIGHT=40 -- --full $([ $ext = ansi ] && echo --color)
			need "$w cols $ext: rc 0" rc_is 0
			need "$w cols $ext: stderr empty" err_empty
			need "$w cols $ext: node lines as on the screen" node_lines_are "$fixtures/bars-$1/nodes-w$w.$ext"
		done
	done
}
c_bars_idle()     { T_TITLE="bars, idle: all free, FreeMem above RealMemory reads as 0 in use"; bars_screens idle; }
c_bars_busy()     { T_TITLE="bars, busy: allocation and use agree, █ up to both"; bars_screens busy; }
c_bars_waste()    { T_TITLE="bars, waste: all allocated, little used, ▒ for the idle part"; bars_screens waste; }
c_bars_over()     { T_TITLE="bars, over: use beyond the allocation in magenta ▓"; bars_screens over; }
c_bars_overfull() { T_TITLE="bars, overfull: a load above the core count fills the bar, no more"; bars_screens overfull; }
c_bars_down()     { T_TITLE="bars, down: load and FreeMem N/A draw · where nothing is allocated"; bars_screens down; }
c_bars_round() {
	T_TITLE="bars: counts round to the nearest cell, so a tiny allocation and load draw none"
	local w
	for w in 120 80; do
		sq_run bars-round SQ_WIDTH=$w --
		need "$w cols: rc 0" rc_is 0
		need "$w cols: node01's bars are all ░" eval 'lines_matching "^ +node01 " | grep -qE "^ +node01 +░+ +0% .* cpu +░+ +0% "'
		need "$w cols: node02, half allocated, does draw ▒" eval 'lines_matching "^ +node02 " | grep -qE "^ +node02 +▒+░+ +50% "'
	done
}

# the cells of one bar as "SGR:glyph", one per cell, from the coloured output
bar_of() {        # bar_of NODE K: the K-th bar (1 CPU, 2 memory) on NODE's line
	LC_ALL=$utf8 gawk -v node="$1" -v k="$2" '
		{ t = $0; gsub(/\033\[[0-9;]*m/, "", t); split(t, f, " ") }
		f[1] != node { next }
		{ s = $0; done = 0; nb = 0; prev = -1; out = ""
		  while (match(s, /\033\[[0-9;]*m[█▒▓░·]/)) {
			at = done + RSTART
			if (at != prev + 1) nb++              # not adjacent: the next bar
			if (nb == k) out = out (out == "" ? "" : " ") substr(s, RSTART + 2, RLENGTH - 4) ":" substr(s, RSTART + RLENGTH - 1, 1)
			prev = done + RSTART + RLENGTH - 1; done = prev
			s = substr(s, RSTART + RLENGTH)
		  }
		  print out; exit }' "$OUT"
}
bar_kinds() { bar_of "$1" "$2" | tr ' ' '\n' | sort -u | paste -sd' '; }   # its distinct cells
bar_kinds_are() { [ "$(bar_kinds "$1" "$2")" = "$3" ]; }
# mem_bar_kinds NODE: the distinct glyphs of the MEM bar on NODE's line, the
# run of bar glyphs after " cpu " (plain text: one glyph per cell)
mem_bar_kinds() {
	plain | LC_ALL=$utf8 gawk -v n="$1" '$1 == n { s = $0; sub(/^.* cpu +/, "", s)
		if (match(s, /^[█▒▓░·]+/)) { s = substr(s, 1, RLENGTH); while (s != "") { k[substr(s, 1, 1)]; s = substr(s, 2) } }
		for (g in k) o = o g; print o; exit }'
}
# E4: the dim line naming the fields sinfo gave no usable figure for
node_caption() { plain | grep -E '^ *↳ sinfo gave no usable figure for ' | sed -E 's/^ +//'; }
c_bars_edges() {
	T_TITLE="bars: a draining node in the down hue, zero totals, the 85% boundary, a load that is no number"
	sq_run bars-edges -- --full --color
	need "rc 0, nothing on stderr" eval 'rc_is 0 && err_empty'
	need "draining: CPU bar █ 31, ▒ 2;31, ░ 2" bar_kinds_are drn01 1 "2:░ 2;31:▒ 31:█"
	need "draining: memory bar, allocated, █ 31, ░ 2" bar_kinds_are drn01 2 "2:░ 31:█"
	need "0 CPUs, 0 memory: CPU bar all ░, MEM bar all · (Memory 0 is unknown), Memory named in the caption" eval '
		bar_kinds_are zero01 1 "2:░" && bar_kinds_are zero01 2 "2:·" && mem_part_is zero01 "················ -% 0/- mem idle" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for Memory (2 nodes), CPUsLoad (1 node): shown as unknown" ]'
	need "0 CPUs, 0 memory, use N/A: both bars all ·" eval 'bar_kinds_are zero02 1 "2:·" && bar_kinds_are zero02 2 "2:·"'
	need "85% allocated: CPU bar green" bar_kinds_are pct85 1 "2:░ 32:█"
	need "86% allocated: CPU bar yellow" bar_kinds_are pct86 1 "2:░ 33:█"
	need "load '0.10-0.46': not known, ▒ then ·" bar_kinds_are ldrange 1 "2:· 2;32:▒"
}
# Bars that start collapsed (too narrow for BAR_MIN) and then grow to the
# shared right edge must bring back the gap they collapsed: they did not, and
# the node line ran one column past the screen (array fixtures at 50-53).
# Narrower than the line with its bars collapsed no layout fits, so the bound
# is the screen or that line, whichever is wider.  Where the bars are drawn
# they end the node block on the shared right edge, the queue header's, not
# short of it: the widest node line, as the state column is left-aligned.
node_width() { cplain | LC_ALL=$utf8 gawk '/ cpu .* mem / { if (length($0) > m) m = length($0) } END { print m+0 }'; }
# node_edge: "NODE HEADER BARS DRAWN": the widest node line, the queue header
# (0 without one), "ok" when every node line draws no bar or two of 2 cells at
# least (else "small"), and 1 when some node line draws bars (else 0)
node_edge() {
	cplain | LC_ALL=$utf8 gawk 'hw == "" && /^ *[A-Z][A-Z\/_()]*( +[A-Z][A-Z\/_()]*)* *$/ { hw = length($0) }
		/ cpu .* mem / { if (length($0) > nw) nw = length($0); s = $0; n = 0
			while (match(s, /[█▒▓░·]+/)) { n++; if (RLENGTH < 2) bad = 1; s = substr(s, RSTART + RLENGTH) }
			if (n != 0 && n != 2) bad = 1; if (n) drawn = 1 }
		END { print nw + 0, hw + 0, bad ? "small" : "ok", drawn + 0 }'
}
# one series of the sweep, in a subshell of its own, as the 12 series run at
# once: its T_DIR and run counter its own, what it found and its T_FAIL and
# T_CALLS into FILE for the case to take back
sweep_series() {   # sweep_series FIXTURE MODE FILE
	local fx=$1 mode=$2 res=$3 w nmin nw hw bars any over= short= small= shade= drawn=0 bare=0 ok21=0 nd
	T_DIR=$T_DIR/s-$fx$mode run_n=0 T_FAIL=() T_CALLS=0; mkdir -p "$T_DIR"
	sq_run "$fx" SQ_WIDTH=21 -- "$mode"
	nmin=$(node_width)
	# WHOLE (H2): a COMPACT node line too wide for its figures takes a form
	# without them (the name and the state), which whole_monotone checks
	rc_is 0 && { [ "$nmin" -gt 0 ] || [ "$mode" = --compact ]; } && ok21=1
	for w in $(seq 21 140); do
		sq_run "$fx" SQ_WIDTH="$w" -- "$mode"
		read -r nw hw bars any <<< "$(node_edge)"
		[ "$nw" -le $(( w > nmin ? w : nmin )) ] || over="$over $w"
		[ "$bars" = ok ] || small="$small $w"
		case $fx in bars-*|membar-*)        # E2: memory in use is a fill, never ▓
			for nd in $(lines_matching " cpu .* mem " | gawk '{ print $1 }'); do
				case $(mem_bar_kinds "$nd") in *▓*) shade="$shade $w"; break ;; esac
			done ;;
		esac
		if [ "$any" = 1 ]; then drawn=$((drawn + 1)); else bare=$((bare + 1)); fi
		[ "$nw" -le "$w" ] || continue          # past the screen: the bar-less line, checked above
		[ "$nw" -gt 0 ] || [ "$mode" != --compact ] || continue   # no figures (H2): no line to measure
		[ "$nw" = $(( hw <= w ? hw : w )) ] || short="$short $w($nw/$hw)"
	done
	local s_fail=("${T_FAIL[@]}") s_calls=$T_CALLS
	declare -p ok21 over short small shade drawn bare s_fail s_calls > "$res"
}
c_bars_width_sweep() {
	T_TITLE="FULL and COMPACT at every width 21..140: no node line wider than the screen (or than with its bars collapsed), no bar of 1-3 cells, and the node lines end on the queue header's edge (the screen's where the table is wider), bars or none; no ▓ in a MEM bar of the bars and membar fixtures, CR_CORE's too (E2)"
	local fx mode pids=() ok21 over short small shade drawn bare s_fail s_calls
	local fixtures_swept="array-running busy24 bars-busy mix30 membar-busy bars-over membar-crcore"
	for fx in $fixtures_swept; do
		for mode in --full --compact; do sweep_series "$fx" "$mode" "$T_DIR/res$fx$mode" & pids+=($!); done
	done
	wait "${pids[@]}"
	for fx in $fixtures_swept; do
		for mode in --full --compact; do
			if ! [ -s "$T_DIR/res$fx$mode" ] || ! . "$T_DIR/res$fx$mode"; then T_FAIL+=("$fx $mode: the series left no result"); continue; fi
			T_FAIL+=("${s_fail[@]}"); T_CALLS=$((T_CALLS + s_calls))
			need "$fx $mode at 21: rc 0, node lines drawn (FULL: with their figures)" test "$ok21" = 1
			need "$fx $mode: no node line past the screen (past it at W =${over:- none})" test -z "$over"
			need "$fx $mode: every bar 0 or at least 2 cells (not at W =${small:- none})" test -z "$small"
			need "$fx $mode: bars drawn at some width, none at some other" eval '[ "$drawn" -gt 0 ] && [ "$bare" -gt 0 ]'
			need "$fx $mode: node lines end on the queue header's edge, or the screen's (not at W =${short:- none})" test -z "$short"
			case $fx in bars-*|membar-*) need "$fx $mode: no ▓ in a MEM bar (at W =${shade:- none})" test -z "$shade" ;; esac
		done
	done
}
# ---- the memory bar: allocated where Slurm schedules memory (MEMBAR v1/v2) ----
# fixtures/membar-{idle,busy,crcore,down} are bioserver after Stage B
# (RealMemory 1031000/80000, MemSpecLimit 31000/3200 in their scontrol-node):
# idle, busy with memory scheduled, the same jobs under CR_CORE, and busy with
# fb2-bioinf-0 not responding.  Their <mode>.{txt,ansi} are the variant-A screens
# Franz accepted on 2026-10-21 (drawn on host FranzGB); CR_CORE's are DISPLAY-v4
# E2's (memory in use drawn as the fill █, not ▓), re-pinned from its build;
# busy's and crcore's full-w80 are DISPLAY-v4 F3's (JOBID's blank column goes
# to NODE/REASON: fb2-bioi…).
membar_modes="full-w120:120:50:--full full-w80:80:50:--full compact-w120x12:120:12:--compact compact-w120x4:120:4:--compact"
c_membar_screens() {
	T_TITLE="the memory bar: the accepted variant-A screens byte for byte, clock aside, idle, busy and down, CR_CORE as re-pinned for DISPLAY-v4 E2 (in use as a fill); FULL at 120 and 80, COMPACT 120x12 and 120x4"
	local c m name w h flag ext
	for c in idle busy crcore down; do
		for m in $membar_modes; do
			IFS=: read -r name w h flag <<< "$m"
			for ext in txt ansi; do
				sq_run "membar-$c" SQSTUB_HOST=FranzGB SQ_WIDTH="$w" SQ_HEIGHT="$h" -- "$flag" "$([ $ext = ansi ] && echo --color || echo --no-color)"
				need "$c $name $ext: rc 0, stderr empty, the accepted screen" eval '
					rc_is 0 && err_empty && cmp -s <(without_clock "$fixtures/membar-$c/$name.$ext") <(without_clock "$OUT")'
			done
		done
	done
}
# the memory part of NODE's line, spaces squeezed: its bar, %, figure, "mem" and state
mem_part() { plain | gawk -v n="$1" '$1 == n { sub(/.* cpu +/, ""); gsub(/ +/, " "); print; exit }'; }
mem_part_is() { [ "$(mem_part "$1")" = "$2" ]; }
digest_line() { plain | grep -E '^ *nodes: ' | sed -E 's/^ +//'; }
c_membar_detect() {
	T_TITLE="memory scheduled (some node has AllocMem): allocated against RealMemory less MemSpecLimit; CR_CORE (none has, CPUs are allocated): memory in use against RealMemory, as a fill; nothing allocated: the allocated view, 0"
	sq_run membar-busy -- --full
	need "scheduled: 265 of 977G and 70 of 75G allocated, █ then ░" eval '
		rc_is 0 && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed" &&
		mem_part_is fb2-bioinf-0 "███████████████░ 93% 70/75G mem allocated"'
	sq_run membar-busy SQ_HEIGHT=4 -- --compact
	need "... the summary line adds allocated/schedulable memory" eval 'rc_is 0 && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/1052G mem" ]'
	sq_run membar-crcore -- --full
	need "CR_CORE: memory in use of RealMemory, drawn as the fill █ (E2)" eval '
		rc_is 0 && mem_part_is fb2-bioinf "████████░░░░░░░░ 48% 493/1007G mem mixed" &&
		mem_part_is fb2-bioinf-0 "████████████████ 97% 76/78G mem allocated"'
	sq_run membar-crcore -- --full --color
	need "... in the hue of its percentage: fb2-bioinf green and ░, fb2-bioinf-0 (97 %) bold red" eval '
		rc_is 0 && bar_kinds_are fb2-bioinf 2 "2:░ 32:█" && bar_kinds_are fb2-bioinf-0 2 "1;31:█"'
	sq_run membar-crcore SQ_HEIGHT=4 -- --compact
	need "... the summary line counts no memory" eval 'rc_is 0 && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu" ]'
	sq_run membar-idle -- --full
	need "nothing allocated: 0 of 977G and of 75G, all ░, not the 228G of page cache and OS" eval '
		rc_is 0 && mem_part_is fb2-bioinf "░░░░░░░░░░░░░░░░ 0% 0/977G mem idle" &&
		mem_part_is fb2-bioinf-0 "░░░░░░░░░░░░░░░░ 0% 0/75G mem idle"'
}
# ---- E1 (DISPLAY-v4): the digest fitted to the screen by whole parts --------
# digest_series FIXTURE FILE: the COMPACT 4-line digest at every width 21..120
# and the whole one (at 400), "W<TAB>line" (the line as cplain cellifies it,
# margin and all) into FILE, in a subshell of its own as the series run at once
digest_series() {
	local fx=$1 res=$2 w
	T_DIR=$T_DIR/d-$fx run_n=0 T_FAIL=() T_CALLS=0; mkdir -p "$T_DIR"
	: > "$res.part"
	for w in 400 $(seq 21 120); do
		sq_run "$fx" SQ_WIDTH="$w" SQ_HEIGHT=4 -- --compact --no-color
		rc_is 0 || T_FAIL+=("$fx W=$w: rc $RC")
		printf '%s\t%s\n' "$w" "$(cplain | grep -E '^ *nodes: ' | head -n 1)" >> "$res.part"
	done
	printf '%s\n' "${T_FAIL[@]}" > "$res.fail"; echo "$T_CALLS" > "$res.calls"
	mv "$res.part" "$res"
}
# digest_check FILE: what breaks E1 in a series (one line each, none if it
# holds): the width, a "…" that is no item of its own, a part that is no whole
# part of the whole digest or out of its order, a part at W missing at W+1,
# and the order the parts drop in (the healthy states from the last, then the
# memory figure, then the CPU figure, then the fault states from the last).  A
# fault: a word of the red bar (down drain fail inval unk) or a "*" suffix
digest_check() {
	WHOLE_SHORT=$whole_short LC_ALL=$utf8 gawk -F'\t' '
	function parse(d, P,   segs, ns, i, it, ni, k) {
		delete P; P["ok"] = 1
		if (d !~ /^nodes: /) { P["ok"] = 0; return }
		ns = split(substr(d, 8), segs, / · /)
		ni = split(segs[1], it, /, /)
		for (i = 1; i <= ni; i++) {
			if (it[i] == "…") { if (i != ni) P["bad"] = "a … that is not the last state item"; P["sell"] = 1; continue }
			if (index(it[i], "…")) P["bad"] = "a … glued to " it[i]
			P["s", ++k] = it[i]
		}
		P["ns"] = k + 0; k = 0
		for (i = 2; i <= ns; i++) {
			if (segs[i] == "…") { if (i != ns) P["bad"] = "a … that is not the last figure"; P["fell"] = 1; continue }
			if (index(segs[i], "…")) P["bad"] = "a … glued to " segs[i]
			P["f", ++k] = segs[i]
		}
		P["nf"] = k + 0
	}
	function fault(st) { sub(/^[0-9]+ /, "", st); return st ~ /down|drain|fail|inval|unk/ || st ~ /[*]$/ }
	# WHOLE H3: a state by the short name of sinfo stands for its long one
	function long_of(x,   c, b, sf) {
		c = x; sub(/ .*/, "", c); b = substr(x, length(c) + 2); sf = b; sub(/^[a-z_]+/, "", sf); b = substr(b, 1, length(b) - length(sf))
		return (b in LONG) ? c " " LONG[b] sf : x
	}
	function has_short(x,   b) { b = x; sub(/^[0-9]+ /, "", b); sub(/[^a-z_]+$/, "", b); return b in SHORT }   # a long name that has a short one
	BEGIN { n = split(ENVIRON["WHOLE_SHORT"], S, " "); for (i = 1; i < n; i += 2) { LONG[S[i+1]] = S[i]; SHORT[S[i]] } }
	$1 == 400 { whole = $2; sub(/^ +/, "", whole); parse(whole, A)
		for (i = 1; i <= A["ns"]; i++) { if (fault(A["s", i])) nfault++; else nheal++; AT[A["s", i]] = i }
		for (i = 1; i <= A["nf"]; i++) AF[A["f", i]] = i
		next }
	{ w = $1; line = $2; d = line; sub(/^ +/, "", d)
	  if (d == "") { print "W=" w ": no digest"; next }
	  if (length(line) > w) print "W=" w ": " length(line) " columns: " d
	  parse(d, P)
	  if (!P["ok"]) { print "W=" w ": not a digest: " d; next }
	  if ("bad" in P) print "W=" w ": " P["bad"] ": " d
	  if (P["sell"] != (P["ns"] < A["ns"])) print "W=" w ": the states end in … " (P["sell"] ? "with none dropped" : "missing") ": " d
	  if (P["fell"] != (P["nf"] < A["nf"])) print "W=" w ": the figures end in … " (P["fell"] ? "with none dropped" : "missing") ": " d
	  prev = 0; sf = sh = nshort = 0; delete SHOWN
	  for (i = 1; i <= P["ns"]; i++) {
		x = P["s", i]
		if (!(x in AT) && (long_of(x) in AT)) { x = long_of(x); nshort++ }
		if (!(x in AT)) { print "W=" w ": " x " is no state of the whole digest"; continue }
		if (AT[x] <= prev) print "W=" w ": " x " out of sinfo order"
		prev = AT[x]; SHOWN["s" x]
		if (fault(x)) sf++; else sh++
	  }
	  prev = 0
	  for (i = 1; i <= P["nf"]; i++) {
		x = P["f", i]
		if (!(x in AF)) { print "W=" w ": " x " is no figure of the whole digest"; continue }
		if (AF[x] <= prev) print "W=" w ": " x " out of order"
		prev = AF[x]; SHOWN["f" x]
	  }
	  # dropped from the last within each kind: the kept ones are the first of their kind
	  k = 0; for (i = 1; i <= A["ns"]; i++) if (fault(A["s", i])) { k++; if (k <= sf && !(("s" A["s", i]) in SHOWN)) print "W=" w ": fault state " A["s", i] " dropped before a later one" }
	  k = 0; for (i = 1; i <= A["ns"]; i++) if (!fault(A["s", i])) { k++; if (k <= sh && !(("s" A["s", i]) in SHOWN)) print "W=" w ": healthy state " A["s", i] " dropped before a later one" }
	  if ((P["nf"] > 0 || sh > 0) && sf < nfault) print "W=" w ": a fault state missing while a figure or a healthy state shows: " d
	  # H3: one state outlasts the figures (a healthy one where no fault is), the
	  # short names come after the figures, all at once
	  if (P["nf"] < A["nf"] && (sh > 1 || sh > 0 && nfault > 0)) print "W=" w ": a figure missing while a healthy state shows: " d
	  if (nshort && P["nf"] > 0) print "W=" w ": a short state name while a figure shows: " d
	  for (i = 1; i <= P["ns"]; i++) if (nshort && has_short(P["s", i])) print "W=" w ": short names and long mixed: " d
	  if (P["nf"] > 0 && !(("f" A["f", 1]) in SHOWN)) print "W=" w ": the CPU figure missing while the memory figure shows: " d
	  # a wider screen only adds parts
	  if (w > 21) for (x in LAST) if (!(x in SHOWN)) print "W=" w ": " substr(x, 2) " shown at W=" w - 1 " but not here"
	  delete LAST; for (x in SHOWN) LAST[x]
	}' "$1"
}
digest_at() { gawk -F'\t' -v w="$2" '$1 == w { sub(/^ +/, "", $2); print $2 }' "$1"; }   # digest_at FILE W
c_digest_fit() {   # DISPLAY-v4 E AC 1
	T_TITLE="E1 with WHOLE's H3: the COMPACT digest at every width 21..120 fits the screen by whole parts, the fault states (a red-bar word or a * suffix, not ~ ^ \$ @) kept longest, one state outlasting the figures, then the CPU figure, then memory, then the short names of sinfo, the states in sinfo order, a cut list ending in a … of its own; the pins; ! red and alone in colour; the ! and ? cases"
	local fx pids=() bad pin got want
	local swept="big40 scfail scfail-downlast membar-busy noacct bars-busy bars-down wide-text big40faults"
	for fx in $swept; do digest_series "$fx" "$T_DIR/dig-$fx" & pids+=($!); done
	wait "${pids[@]}"
	for fx in $swept; do
		if ! [ -s "$T_DIR/dig-$fx" ]; then T_FAIL+=("$fx: the series left no result"); continue; fi
		while IFS= read -r bad; do [ -z "$bad" ] || T_FAIL+=("$fx: $bad"); done < "$T_DIR/dig-$fx.fail"
		T_CALLS=$((T_CALLS + $(cat "$T_DIR/dig-$fx.calls")))
		bad=$(digest_check "$T_DIR/dig-$fx" | head -n 5 | paste -sd ';')
		need "$fx: every W 21..120 by E1${bad:+ ($bad)}" test -z "$bad"
	done
	for pin in "scfail-downlast:25:nodes: 1 down*, … · …" \
	           "scfail-downlast:36:nodes: 1 down*, … · 58/152 cpu · …" \
	           "scfail-downlast:49:nodes: 1 down*, … · 58/152 cpu · 265/!1085G mem" \
	           "scfail-downlast:55:nodes: 1 mixed, 1 down* · 58/152 cpu · 265/!1085G mem" \
	           "big40:25:nodes: 3 down*, … · …" \
	           "big40:80:nodes: 3 down*, 2 drained, 2 draining, … · 1020/2560 cpu · 3135/!10240G mem" \
	           "big40:87:nodes: 12 mixed, 3 down*, 2 drained, 2 draining, … · 1020/2560 cpu · 3135/!10240G mem" \
	           "big40:107:nodes: 12 mixed, 10 allocated, 11 idle, 3 down*, 2 drained, 2 draining · 1020/2560 cpu · 3135/!10240G mem" \
	           "scfail:21:nodes: 1 mix, … · …" "scfail:27:nodes: 1 mixed, … · …" \
	           "scfail:40:nodes: 1 mixed, … · 82/152 cpu · …" "scfail:49:nodes: 1 mixed, … · 82/152 cpu · 335/!1085G mem" \
	           "scfail:59:nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/!1085G mem" \
	           "noacct:59:nodes: 1 allocated, 1 down* · 128/256 cpu · 443/1006G mem" \
	           "noacct:49:nodes: 1 down*, … · 128/256 cpu · 443/1006G mem" \
	           "noacct:37:nodes: 1 down*, … · 128/256 cpu · …" "noacct:23:nodes: 1 down*, … · …" \
	           "big40faults:25:nodes: 1 idle*, … · …" \
	           "big40faults:55:nodes: 1 idle*, 1 down~, 1 powered_dn, … · …" \
	           "big40faults:85:nodes: 1 idle*, 1 down~, 1 powered_down, 1 drained~, 1 maint*, … · 90/768 cpu · …" \
	           "big40faults:115:nodes: 1 mixed, 1 idle~, 1 idle*, 1 down~, 1 powered_down, 1 drained~, 1 maint*, … · 90/768 cpu · 293/!3072G mem"; do
		fx=${pin%%:*} pin=${pin#*:}; want=${pin#*:} pin=${pin%%:*}
		got=$(digest_at "$T_DIR/dig-$fx" "$pin")
		need "$fx W=$pin: '$want'${got:+ (has '$got')}" test "$got" = "$want"
	done
	# --color: the ! of a total red and alone; a state's own ! (idle!) is no mark
	for fx in scfail scfail-idlebang; do
		sq_run "$fx" SQ_HEIGHT=4 -- --compact --color
		need "$fx --color: only the ! after the / is coloured, ESC[31m!ESC[0m, nothing else in the line" eval '
			rc_is 0 && [ "$(grep -F "nodes: " "$OUT" | LC_ALL=C grep -o "$ESC\[[0-9;]*m" | paste -sd " " | tr -d "$ESC")" = "[31m [0m" ] &&
			grep -F "nodes: " "$OUT" | grep -qF "/$ESC[31m!$ESC[0m"'
	done
	need "scfail-idlebang: idle! is a healthy state, its ! no mark" eval 'plain | grep -qE "^ +nodes: 1 mixed, 1 idle! · 58/152 cpu · 265/!1085G mem$"'
	# the ! cases: scontrol fine, a total unknown, CR_CORE, a node scontrol did not list
	for pin in "membar-busy:nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/1052G mem" \
	           "scfail-memempty:nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/?G mem" \
	           "crcore-scfail:nodes: 1 mixed, 1 allocated · 82/152 cpu" \
	           "scnolist:nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/!1055G mem"; do
		fx=${pin%%:*} want=${pin#*:}
		sq_run "$fx" SQ_HEIGHT=4 -- --compact
		need "$fx: '$want'" eval 'rc_is 0 && [ "$(digest_line)" = "$want" ]'
	done
}
# ---- E3-E5 (DISPLAY-v4): readable node figures, the caption, which view -----
# the dim lines under the nodes in their order: R (a node reason), S (the
# skipped rows), U (E4's caption), M (the MEMNOTE place, NODES' text)
node_notes() {
	plain | gawk '/^ *↳ [0-9]+ unreadable node row/ { printf "S"; next } /^ *↳ sinfo gave no usable figure/ { printf "U"; next }
		/^ *↳ memory counts RealMemory/ { printf "M"; next } / cpu .* mem / { n = 1; next } n && /^ +↳ / { printf "R" } END { print "" }'
}
node_caption_dim() { grep -F "↳ sinfo gave no usable figure" "$OUT" | grep -qF "$ESC[2m↳ sinfo gave no usable figure"; }
c_node_figures() {   # DISPLAY-v4 E AC 3, 4, 5
	T_TITLE="E3-E5: a figure sinfo gives no usable value for (none, a word, Memory 0 or 1, AllocMem or Memory N/A) reads -, · and ? and is named in a dim caption under the nodes, in a fixed order; FreeMem and CPUsLoad N/A stay quiet; AllocMem above Memory as Slurm says; the in-use view only on evidence"
	local h want got bad=
	# E3, one field and form each (fxE), figures exact
	sq_run freemem-empty -- --full
	need "FreeMem empty, scheduled: fb2-bioinf-0 allocated, its use unknown (▒ then ·), FreeMem named" eval '
		rc_is 0 && err_empty && mem_part_is fb2-bioinf-0 "▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒· 93% 70/75G mem allocated" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for FreeMem (1 node): shown as unknown" ]'
	sq_run crcore-freemem-empty -- --full
	need "FreeMem empty, CR_CORE: fb2-bioinf-0 -% -/78G, all ·" eval '
		rc_is 0 && mem_part_is fb2-bioinf-0 "················ -% -/78G mem allocated" && mem_part_is fb2-bioinf "████████░░░░░░░░ 48% 493/1007G mem mixed" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for FreeMem (1 node): shown as unknown" ]'
	sq_run memory-empty -- --full
	need "Memory empty: fb2-bioinf -% 265/- mem, all ·, Memory named" eval '
		rc_is 0 && mem_part_is fb2-bioinf "················ -% 265/- mem mixed" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for Memory (1 node): shown as unknown" ]'
	sq_run memory-empty SQ_HEIGHT=4 -- --compact
	need "... digest 335/?G mem" eval 'rc_is 0 && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/?G mem" ]'
	sq_run allocmem-garbage -- --full
	need "AllocMem n/a: fb2-bioinf -% -/977G, all ·, AllocMem named" eval '
		rc_is 0 && mem_part_is fb2-bioinf "················ -% -/977G mem mixed" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for AllocMem (1 node): shown as unknown" ]'
	sq_run allocmem-garbage SQ_HEIGHT=4 -- --compact
	need "... digest ?/1052G mem" eval 'rc_is 0 && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu · ?/1052G mem" ]'
	sq_run cpusload-garbage -- --full
	need "CPUsLoad empty and x: the CPU bar as with N/A, ▒ then ·, CPUsLoad named" eval '
		rc_is 0 && plain | grep -qE "^ +fb2-bioinf +▒{7}·{9} +45% " &&
		plain | grep -qE "^ +fb2-bioinf-0 +▒{16} +100% " &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for CPUsLoad (2 nodes): shown as unknown" ]'
	sq_run noalloc-triage -- --full
	need "several fields: named in the fixed order AllocMem, Memory, FreeMem, CPUsLoad, with node counts" eval '
		rc_is 0 && [ "$(node_caption)" = "↳ sinfo gave no usable figure for AllocMem (2 nodes), FreeMem (1 node): shown as unknown" ]'
	sq_run bars-edges -- --full
	need "bars-edges: the order holds across fields (Memory before CPUsLoad); zero02 -% 0/- mem, all ·" eval '
		rc_is 0 && [ "$(node_caption)" = "↳ sinfo gave no usable figure for Memory (2 nodes), CPUsLoad (1 node): shown as unknown" ] &&
		mem_part_is zero02 "················ -% 0/- mem idle"'
	# Memory 1 (RealMemory not configured) and 0 are unknown totals
	sq_run mem1-crcore -- --full
	need "mem1-crcore (Memory=1): both nodes -% -/- mem, all ·, Memory (2 nodes)" eval '
		rc_is 0 && mem_part_is fb2-bioinf "················ -% -/- mem mixed" && mem_part_is fb2-bioinf-0 "················ -% -/- mem allocated" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for Memory (2 nodes): shown as unknown" ]'
	sq_run mem1-busy SQ_HEIGHT=4 -- --compact
	need "mem1-busy: digest 0/?G mem" eval 'rc_is 0 && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu · 0/?G mem" ]'
	sq_run mem0 -- --full
	need "mem0 (Memory=0): fb2-bioinf-0 -% 70/- mem, all ·" eval 'rc_is 0 && mem_part_is fb2-bioinf-0 "················ -% 70/- mem allocated"'
	sq_run mem0 SQ_HEIGHT=4 -- --compact
	need "... digest 335/?G mem" eval 'rc_is 0 && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/?G mem" ]'
	sq_run alloc-gt-mem -- --full --color
	need "AllocMem above Memory: as Slurm says, 11718% 8789/75G, the bar full █" eval '
		rc_is 0 && mem_part_is fb2-bioinf-0 "████████████████ 11718% 8789/75G mem allocated" && [ "$(mem_bar_kinds fb2-bioinf-0)" = "█" ] && [ -z "$(node_caption)" ]'
	sq_run allocNA-both -- --full
	need "AllocMem N/A on both: -/977G and -/75G, all ·, AllocMem (2 nodes)" eval '
		rc_is 0 && mem_part_is fb2-bioinf "················ -% -/977G mem mixed" && mem_part_is fb2-bioinf-0 "················ -% -/75G mem allocated" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for AllocMem (2 nodes): shown as unknown" ]'
	# FreeMem and CPUsLoad N/A: quiet, the node line as before
	sq_run membar-down -- --full
	need "membar-down (FreeMem, CPUsLoad N/A on a down node): ··· 0% 0/75G, no caption" eval '
		rc_is 0 && mem_part_is fb2-bioinf-0 "················ 0% 0/75G mem down*" && [ -z "$(node_caption)" ]'
	sq_run busy24 -- --full
	need "busy24 (FreeMem N/A on node02): its line as before, no caption" eval '
		rc_is 0 && plain | grep -qE "^ +node02 +░+ +0% +0/128 cpu +·+ +0% +0/503G mem +down\*$" && [ -z "$(node_caption)" ]'
	sq_run bars-edges -- --full
	need "bars-edges: zero02s CPUsLoad N/A is not named (its 1 CPUsLoad is ldrange, a range)" eval '
		rc_is 0 && [ "$(LC_ALL=$utf8 gawk "/^ *ldrange /" <(plain) | grep -c .)" = 1 ] && node_caption | grep -qF "CPUsLoad (1 node)"'
	sq_run membar-busy -- --full
	need "every value readable: no caption" eval 'rc_is 0 && [ -z "$(node_caption)" ]'
	# both unknown on one busy node: every cell ·, the fields in E4's order
	sq_run allocmem-memory-unknown -- --full --color
	need "AllocMem N/A and Memory 0 on fb2-bioinf: -% -/- mem, every cell · (no ▒), AllocMem before Memory in the caption" eval '
		rc_is 0 && mem_part_is fb2-bioinf "················ -% -/- mem mixed" && bar_kinds_are fb2-bioinf 2 "2:·" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for AllocMem (1 node), Memory (1 node): shown as unknown" ]'
	sq_run allocmem-memory-unknown SQ_HEIGHT=4 -- --compact
	need "... digest ?/?G mem" eval 'rc_is 0 && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu · ?/?G mem" ]'
	sq_run memory-na -- --full
	need "Memory N/A (never Slurm 23.11 output): -% 265/- mem, all ·, Memory named" eval '
		rc_is 0 && mem_part_is fb2-bioinf "················ -% 265/- mem mixed" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for Memory (1 node): shown as unknown" ]'
	sq_run figure-digits -- --full
	need "1 to 12 digits: a 12-digit AllocMem counts (97656250/977G), a 13-digit Memory is unknown (70/-, all ·), Memory named" eval '
		rc_is 0 && mem_part_is fb2-bioinf "████████████████ 10000000% 97656250/977G mem mixed" &&
		mem_part_is fb2-bioinf-0 "················ -% 70/- mem allocated" &&
		[ "$(node_caption)" = "↳ sinfo gave no usable figure for Memory (1 node): shown as unknown" ]'
	sq_run scfail-plus SQ_HEIGHT=4 -- --compact
	need "AllocMem unknown while scontrol fails: ?/!1085G mem, the unknown sum and the RealMemory total both marked" eval '
		rc_is 0 && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu · ?/!1085G mem" ]'
	sq_run down-stale-crcore -- --full --color
	need "E2 in use on a down node (CR_CORE): its fill red, 31:█ then ░" eval '
		rc_is 0 && mem_part_is fb2-bioinf-0 "████████████████ 97% 76/78G mem down*" && bar_kinds_are fb2-bioinf-0 2 "31:█"'
	# E4: where, dim, cut at the block's width, within COMPACT's height
	sq_run notes3 -- --full --color
	need "notes3: the skipped-rows note, the caption, the scontrol note, in that order, the caption dim" eval '
		rc_is 0 && [ "$(node_notes)" = SUM ] && node_caption_dim'
	sq_run bars-edges -- --full
	need "bars-edges: a node reason, then the caption, last under the nodes" eval 'rc_is 0 && [ "$(node_notes)" = RU ]'
	sq_run bars-edges SQ_WIDTH=60 -- --full
	need "bars-edges at 60: the caption cut with … at the node block's width" eval '
		rc_is 0 && node_caption | grep -q "…$" && [ "$(node_caption | LC_ALL=$utf8 gawk "{ print length(\$0) + 2 }")" -le "$(node_width)" ]'
	for h in 6 8 10 11 12 13 14; do
		sq_run notes3 SQ_HEIGHT=$h -- --compact
		got=$(plain | wc -l)
		{ rc_is 0 && lines_within "$h" && footer_last 5 5 0 0 && [[ SUM == *"$(node_notes)"* ]]; } || bad="$bad $h"
		# 6 at 6: the blanks with the digest (WHOLE H11, E-L9)
		case $h in 6) want=6 ;; 8) want=8 ;; 10) want=10 ;; 12) want=11 ;; 14) want=14 ;; *) want=$got ;; esac
		[ "$got" = "$want" ] || bad="$bad $h($got)"
	done
	need "notes3 COMPACT 120 x H 6..14: within H, the footer last, the notes in E4's order; 6, 8, 10, 11, 14 lines at H 6, 8, 10, 12, 14 (not at H =${bad:- none})" test -z "$bad"
	sq_run notes3 SQ_HEIGHT=12 -- --compact
	need "notes3 at 120x12: the node block in full with all three notes" eval 'rc_is 0 && [ "$(node_notes)" = SUM ] && [ "$(lines_matching " cpu .* mem " | grep -c .)" = 2 ]'
	sq_run allocNA-both SQ_HEIGHT=12 -- --compact
	need "allocNA-both at 120x12 with the caption: within 12 lines, the footer last, the caption shown" eval 'rc_is 0 && lines_within 12 && footer_last 5 5 0 0 && [ "$(node_notes)" = U ]'
	# E5: which view
	for c in allocmem-empty allocNA-both; do
		sq_run $c -- --full
		need "$c: the allocated view, no in-use figure (493, 76) anywhere" eval 'rc_is 0 && ! plain | grep -qE "(^| )(493|76)/" && mem_part fb2-bioinf | grep -qF " -/977G mem "'
	done
	sq_run crcore-idle -- --full
	need "crcore-idle (nothing allocated, CR_CORE-shaped): the allocated view, 0/1007G" eval 'rc_is 0 && mem_part_is fb2-bioinf "░░░░░░░░░░░░░░░░ 0% 0/1007G mem idle"'
	sq_run crcore-idle SQ_HEIGHT=4 -- --compact
	need "... digest 0/1085G mem" eval 'rc_is 0 && [ "$(digest_line)" = "nodes: 2 idle · 0/152 cpu · 0/1085G mem" ]'
	sq_run not-utf8 -- --full
	need "not-utf8 (CPUs allocated, AllocMem 0): the in-use view" eval 'rc_is 0 && plain | grep -qE " cpu +█░+ +6% +8/125G mem +idle$"'
	sq_run allocmem-onebusy-empty -- --full
	need "one busy node AllocMem 271360, the other unknown: the allocated view, the unknown one - and ·" eval '
		rc_is 0 && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed" && mem_part_is fb2-bioinf-0 "················ -% -/75G mem allocated"'
}
# E1 and E4 with NODES' N10: a node scontrol listed twice, did not list, gave a
# garbled, a -1 or a too large MemSpecLimit for counts RealMemory, so the
# digest marks its total with !; the caption and N10's line together
c_digest_n10() {   # DISPLAY-v4 E AC 1 (N10's cases) and E AC 4 (with NODES)
	T_TITLE="E1/M3 with NODES' N10: each per-node case (twice, not listed, garbled, -1, at or above RealMemory) marks the digest's total with !, on --json as on -o; a MemSpecLimit of 0 none; E4's caption and N10's line together within COMPACT 120x12"
	local d dj kind how fx env want
	nodes_lines
	for kind in twice nolist garbled minus big zero; do
		case $kind in
			twice)   d=$(dash_copy "n-$kind" "scontrol-node=$mb_big Comment=x\\n$mb_big"$'\n'"$mb_small")
			         dj=$(json_fx membar-busy '{ print } /^    \{$/ && !s { s = 1 } s == 1 { buf = buf $0 "\n" } /^    \},$/ && s == 1 { s = 2; printf "%s", buf }') ;;
			nolist)  d=$(dash_copy "n-$kind" "scontrol-node=$mb_small"); dj=$d ;;
			garbled) d=$(dash_copy "n-$kind" "scontrol-node=$(line_with "$mb_big" "OS=Linux" 'OS=Linux RealMemory\x3d1 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1')"$'\n'"$mb_small")
			         dj=$(json_fx membar-busy "$json_add" NODE=fb2-bioinf KEY=specialized_memory J=0) ;;
			minus)   d=$(dash_copy "n-$kind" "scontrol-node=$(line_with "$mb_big" "MemSpecLimit=31000" "MemSpecLimit=-1")"$'\n'"$mb_small")
			         dj=$(json_fx membar-busy '{ sub(/"specialized_memory": 31000,/, "\"specialized_memory\": -1,"); print }') ;;
			big)     d=$(dash_copy "n-$kind" "scontrol-node=$(line_with "$mb_big" "MemSpecLimit=31000" "MemSpecLimit=1031000")"$'\n'"$mb_small"); dj=$d ;;
			zero)    d=$(dash_copy "n-$kind" "scontrol-node=$(line_with "$mb_big" "MemSpecLimit=31000" "MemSpecLimit=0")"$'\n'"$mb_small"); dj=$d ;;
		esac
		case $kind in
			nolist) want="nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/!1082G mem" ;;
			zero)   want="nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/1082G mem" ;;
			*)      want="nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/!1082G mem" ;;
		esac
		for how in json nojson; do
			if [ $how = json ]; then fx=$dj env=; else fx=$d env=SQSTUB_NOJSON=1; fi
			sq_run "$fx" $env SQ_HEIGHT=4 -- --compact --no-color
			need "$kind, $how: '$want'" eval 'rc_is 0 && err_empty && [ "$(digest_line)" = "$want" ]'
		done
	done
	# E4's caption and N10's line together, after a skipped row, within 12 lines
	d=$(dash_copy n-notes "scontrol-node=$mb_small" "sinfo=CPUsState=58/70/0/128; NodeList=fb2-bioinf; FreeMem=526168; Memory=1031000; StateLong=mixed; Reason=none; TimeStamp=Unknown; CPUsLoad=x; AllocMem=271360
CPUsState=24/0/0/24; NodeList=fb2-bioinf-0; FreeMem=2176; Memory=80000; StateLong=allocated; Reason=none; TimeStamp=Unknown; CPUsLoad=23.81; AllocMem=71680
CPUsState=garbage; NodeList=fb2-bioinf-1; FreeMem=2176; Memory=80000; StateLong=allocated; Reason=none; TimeStamp=Unknown; CPUsLoad=1.00; AllocMem=1")
	for how in json nojson; do
		if [ $how = json ]; then env=; else env=SQSTUB_NOJSON=1; fi
		sq_run "$d" $env SQ_HEIGHT=12 -- --compact --no-color
		need "skipped row, CPUsLoad x and fb2-bioinf not listed, $how, 120x12: within 12 lines, the node block in full with the three notes in order, the footer last" eval '
			rc_is 0 && err_empty && lines_within 12 && footer_last 5 5 0 0 && [ "$(node_notes)" = SUM ] &&
			[ "$(node_caption)" = "↳ sinfo gave no usable figure for CPUsLoad (1 node): shown as unknown" ] &&
			[ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bioinf: scontrol did not list it" ]'
	done
}

# ---- F (DISPLAY-v4): the JOBID and EXIT cells ---------------------------------
# id_series NAME FILE FIXTURE [sq args]: FULL at 400 and at every width
# 21..130, each screen as cplain cellifies it after a line "@@W <width>", into
# FILE, in a subshell of its own as the series run at once
id_series() {
	local name=$1 res=$2 fx=$3 w; shift 3
	T_DIR=$T_DIR/i-$name run_n=0 T_FAIL=() T_CALLS=0; mkdir -p "$T_DIR"
	: > "$res.part"
	for w in 400 $(seq 21 130); do
		sq_run "$fx" SQ_WIDTH="$w" -- --full --no-color "$@"
		rc_is 0 || T_FAIL+=("$name W=$w: rc $RC")
		{ printf '@@W %s\n' "$w"; cplain; } >> "$res.part"
	done
	printf '%s\n' "${T_FAIL[@]}" > "$res.fail"; echo "$T_CALLS" > "$res.calls"
	mv "$res.part" "$res"
}
# id_check FILE: what breaks F2-F3 in a series, one line each.  Both tables
# are read by their header (a column starts where its header word does; gaps
# are 1 wherever a column is cut), rows by their place.  F2: a cell whose id
# has a bracket (BASE_[TERMS]SUFFIX at 400) is one of its six forms (whole,
# without its throttle %n, whole leading terms then …, BASE_[…] ×N, BASE_…
# ×N, BASE_…), one without a bracket is whole, else it is a plain cut (a
# start of the id then …), which only a screen where every other column of
# that table is at its minimum may show (5 in the queue, 4 in the finished
# table).  F2/F5: within one ladder level (the table's STATE cells) and one
# EXIT form (the rows whose canceller is whole), a narrower JOBID column
# never shows a term, a throttle or a ×N a wider one hides.  F3: where some
# other column of the table is cut (its header, or a cell whole at 400 that
# ends in …; JOBID and EXIT have forms of their own), JOBID (and the finished
# EXIT) are as wide as their widest cell, or their header if wider (F3's
# blanks that stay are where nothing else is cut: shrink-finished at 43, 44, 60)
id_check() {
	LC_ALL=$utf8 gawk '
	function trim(s) { gsub(/\356\200\200/, "", s); sub(/^ +/, "", s); sub(/ +$/, "", s); return s }
	function flush(   t) { if (W != "") for (t in TABS) table(t); delete TABS; delete TL; delete TN }
	/^@@W / { flush(); W = $2; sect = "queue"; cur = ""; next }
	/recently finished/ { sect = "finished"; cur = ""; next }
	/^ *JOBID / { cur = sect; TN[cur] = 0; TL[cur, 0] = $0; TABS[cur] = 1; next }
	/^ *$/ || /^ *\+[0-9]+ more$/ || /^ *… / { cur = ""; next }
	cur != "" { TL[cur, ++TN[cur]] = $0 }
	END { flush() }
	function table(t,   h, i, n, S, CW, nc, x, r, cell, j, key, st, ex, idw, ew, cutother, wid) {
		h = TL[t, 0]; nc = 0; x = h
		while (match(x, /[^ ]+/)) { S[++nc] = RSTART + (length(h) - length(x)); HD[nc] = substr(x, RSTART, RLENGTH); x = substr(x, RSTART + RLENGTH) }
		maxlen = 0; for (r = 1; r <= TN[t]; r++) if (length(TL[t, r]) > maxlen) maxlen = length(TL[t, r])
		for (i = 1; i <= nc; i++) CW[i] = (i < nc ? S[i + 1] - 1 : maxlen + 1) - S[i]
		st = 0; ex = (t == "finished") ? 4 : 0
		for (i = 1; i <= nc; i++) if (HD[i] ~ /^ST/) { st = i; break }
		if (W == 400) { NROW[t] = TN[t]
			for (r = 1; r <= TN[t]; r++) for (i = 1; i <= nc; i++) { cell = trim(substr(TL[t, r], S[i], i < nc ? S[i + 1] - S[i] : 9999)); if (i == 1) FULLID[t, r] = cell; WHOLE[t, r, i] = cell }
			for (i = 1; i <= nc; i++) HD0[t, i] = HD[i]
			NCOL[t] = nc; return }
		if (TN[t] != NROW[t] || nc != NCOL[t]) { bad(t, "rows or columns differ from W=400"); return }
		key = ""; idw = 0; ew = 0; cutother = 0; allmin = 1
		for (i = 2; i <= nc; i++) {          # cut: its header, or a cell that is whole at 400 ends in …
			if (CW[i] > (t == "queue" ? 5 : 4)) allmin = 0
			if (i == ex) continue                # EXIT has forms of its own (F4), as JOBID has
			if (HD[i] != HD0[t, i]) cutother = 1
			for (r = 1; r <= TN[t]; r++) { cell = trim(substr(TL[t, r], S[i], i < nc ? S[i + 1] - S[i] : 9999)); if (cell ~ /…$/ && cell != WHOLE[t, r, i]) cutother = 1 }
		}
		for (r = 1; r <= TN[t]; r++) {
			if (st) key = key "|" trim(substr(TL[t, r], S[st], st < nc ? S[st + 1] - S[st] : 9999))
			if (ex) { cell = trim(substr(TL[t, r], S[ex], S[ex + 1] - S[ex])); if (length(cell) > ew) ew = length(cell)
			          if (cell ~ / by / && cell !~ /…/) key = key "|w" r }
			cell = trim(substr(TL[t, r], S[1], S[2] - S[1])); CELL[r] = cell; if (length(cell) > idw) idw = length(cell)
		}
		for (r = 1; r <= TN[t]; r++) form(t, r, CELL[r], FULLID[t, r], allmin, CW[1], key)
		if (cutother) {
			if (CW[1] != (idw > 5 ? idw : (CW[1] < 5 ? CW[1] : 5))) bad(t, "JOBID " CW[1] " wide, its widest cell " idw)
			if (ex && CW[ex] != (ew > 4 ? ew : (CW[ex] < 4 ? CW[ex] : 4))) bad(t, "EXIT " CW[ex] " wide, its widest cell " ew)
		}
	}
	function bad(t, m) { if (++NB <= 8) print t " W=" W ": " m }
	function terms(c, T,   n, A, i, k) { delete T; n = split(c, A, ","); for (i = 1; i <= n; i++) if (A[i] != "…" && A[i] != "") T[A[i]]; return n }
	function form(t, r, c, full, allmin, cw, key,   m, base, cont, suf, thr, okf, sh, x, prev, K) {
		if (c == full) okf = 1
		else if (match(full, /^([0-9]+_)\[([^]]*)\](( ×[0-9]+)?)$/, m)) {
			base = m[1]; cont = m[2]; suf = m[3]; thr = ""
			if (match(cont, /%[0-9]+$/)) { thr = substr(cont, RSTART); cont = substr(cont, 1, RSTART - 1) }
			if (c == base "[" cont "]" suf || c == base "[…]" suf || c == base "…" suf || c == base "…") okf = 1
			else if (substr(c, 1, length(base) + 1) == base "[" && substr(c, length(c) - length(suf) - 2) == ",…]" suf) {
				x = substr(c, length(base) + 2, length(c) - length(base) - length(suf) - 4)   # the leading terms kept
				if (index(cont ",", x ",") == 1) okf = 1
			}
		}
		if (!okf) {
			if (c ~ /…$/ && index(full, substr(c, 1, length(c) - 1)) == 1) { if (!allmin) bad(t, "row " r ": " c " cut while another column can give (id " full ")") ; return }
			bad(t, "row " r ": " c " is no form of " full); return
		}
		# monotonic: what this cell shows, against every other width of the same key
		sh = shows(c, full)
		K = t SUBSEP r SUBSEP key
		for (prev in SEEN) {
			split(prev, P, SUBSEP)
			if (P[1] SUBSEP P[2] SUBSEP P[3] != K) continue
			if (P[4] + 0 < cw && !subset(SEEN[prev], sh)) bad(t, "row " r ": " SEENC[prev] " in " P[4] " shows more than " c " in " cw)
			if (P[4] + 0 > cw && !subset(sh, SEEN[prev])) bad(t, "row " r ": " c " in " cw " shows more than " SEENC[prev] " in " P[4])
		}
		SEEN[K SUBSEP cw] = sh; SEENC[K SUBSEP cw] = c
	}
	function shows(c, full,   m, o, n, A, i) {
		if (!match(c, /^[0-9]+_\[([^]]*)\]( ×[0-9]+)?$/, m)) return (c ~ / ×[0-9]+$/) ? "×" : ""
		n = split(m[1], A, ","); for (i = 1; i <= n; i++) if (A[i] != "…") { if (A[i] ~ /%[0-9]+$/) { o = o " %"; sub(/%[0-9]+$/, "", A[i]) } o = o " t" A[i] }
		return o (m[2] != "" ? " ×" : "")
	}
	function subset(a, b,   n, A, i) { n = split(a, A, " "); for (i = 1; i <= n; i++) if (index(" " b " ", " " A[i] " ") == 0) return 0; return 1 }
	' "$1"
}
c_id_cells() {   # DISPLAY-v4 F AC 2, 3, 4
	T_TITLE="F2-F3 at every width 21..130, FULL, both tables: a bracketed id cell is one of its six forms, an id without one whole, a plain cut only where every other column is at its minimum; a narrower JOBID never shows more at one ladder level and EXIT form; JOBID and EXIT as wide as their widest cell where another column is cut"
	local spec name fx args pids=() bad
	local swept="shrink-finished:shrink-finished fallback-throttled:fallback-throttled shrink-pending:shrink-pending throttled:throttled
		array-running:array-running array-running-x:array-running:-x array-split:array-split pending-strided:pending-strided
		pending-range:pending-range memalloc-r:memalloc-r jobmem-outcomes:jobmem-outcomes longplain:longplain sf-alice:sf-alice
		oddarr:oddarr oddfin:oddfin ft-32:ft-32 sp-longname:sp-longname"
	for spec in $swept; do
		IFS=: read -r name fx args <<< "$spec"
		id_series "$name" "$T_DIR/id-$name" "$fx" $args & pids+=($!)
	done
	wait "${pids[@]}"
	for spec in $swept; do
		IFS=: read -r name fx args <<< "$spec"
		if ! [ -s "$T_DIR/id-$name" ]; then T_FAIL+=("$name: the series left no result"); continue; fi
		while IFS= read -r bad; do [ -z "$bad" ] || T_FAIL+=("$name: $bad"); done < "$T_DIR/id-$name.fail"
		T_CALLS=$((T_CALLS + $(cat "$T_DIR/id-$name.calls")))
		bad=$(id_check "$T_DIR/id-$name" | head -n 5 | paste -sd ';')
		need "$name: F2-F3 at every W 21..130${bad:+ ($bad)}" test -z "$bad"
	done
}
# F AC 6: the F cells are ASCII and sq's glyphs, so measured by columns
# (WIDE: a byte above 127 in the records) and under gawk in C (no UTF-8
# locale) the tables are the ones of an ASCII caller under UTF-8
c_id_cells_wide_c() {   # DISPLAY-v4 F AC 6
	T_TITLE="F under WIDE and C: shrink-finished with one job name made wide (é) at every width 21..130 is its ASCII screen byte for byte, é aside; shrink-finished, sf-alice, oddarr and oddfin under gawk in C are the UTF-8 screens byte for byte"
	local d=$T_DIR/fx-wide nobin=$T_DIR/nobin w spec fx want f bad=
	mkdir -p "$d" "$nobin"
	for f in sinfo squeue passwd; do printf '@include %s\n' "$fixtures/shrink-finished/$f" > "$d/$f"; done
	sed 's/JobName=single;/JobName=singlé;/' "$fixtures/shrink-finished/sacct" | sed "s#^@include \.\./#@include $fixtures/#" > "$d/sacct"
	for w in $(seq 21 130); do
		sq_run shrink-finished SQ_WIDTH=$w -- --full --no-color
		want=$RUN/ascii; without_clock "$OUT" > "$want"
		sq_run "$d" SQ_WIDTH=$w -- --full --no-color
		rc_is 0 && cmp -s "$want" <(without_clock "$OUT" | sed 's/singlé/single/') || bad="$bad $w"
	done
	need "shrink-finished, a name with é (WIDE): the ASCII screen at every W 21..130 (not at W =${bad:- none})" test -z "$bad"
	no_utf8_locale "$nobin"
	for spec in shrink-finished:40 shrink-finished:44 shrink-finished:46 shrink-finished:60 sf-alice:44 sf-alice:46 \
	            oddarr:57 oddarr:80 oddfin:38 oddfin:56 oddfin:58 oddfin:59 oddfin:60; do
		IFS=: read -r fx w <<< "$spec"
		sq_run "$fx" SQ_WIDTH=$w -- --full --color
		want=$RUN/utf8; without_clock "$OUT" > "$want"
		sq_run "$fx" SQ_WIDTH=$w LC_ALL=C "PATH=$nobin:$here/bin:$PATH" -- --full --color
		need "$fx W=$w under gawk in C: rc 0, stderr empty, the UTF-8 screen" eval 'rc_is 0 && err_empty && cmp -s "$want" <(without_clock "$OUT")'
	done
}
# table_has queue|recent TEXT: some row of that table holds TEXT, runs of blanks
# read as one on both sides
table_has() { rows "$1" | T=$2 gawk 'BEGIN { t = ENVIRON["T"]; gsub(/  +/, " ", t) } { gsub(/  +/, " ") } index($0, t) { f = 1 } END { exit !f }'; }
# the width of a table's JOBID column: up to its second header word
jobid_width() { section "$1" | gawk '/^ *JOBID / { match($0, /JOBID +/); print RLENGTH - 1; exit }'; }
c_id_pins() {   # DISPLAY-v4 F AC 1-5, the pins
	T_TITLE="F1-F5 pinned: the throttle goes first (7002_[0-9] ×10, 8000_[2-9] ×8), the JOBID floor (11920_…, 9876543210_…, 123456789, 11899, 4005_1, 1234_0), the spare (600_… ×67 sweep-irr…, (Resources), 0 by mall…), sf-both's NAME, the canceller (0 by 1025, 0 by…, 0), oddfin's cliff; WHOLE re-pinned the narrow FULL widths (R-M3: the finished table keeps its long state, H4: JOBID keeps ×N until the text floors)"
	local w got bad= c
	# F1
	sq_run fallback-throttled SQ_WIDTH=50 -- --full --no-color
	need "fallback-throttled W=50: 7002_[0-9] ×10" eval 'rc_is 0 && table_has recent "7002_[0-9] ×10"'
	# WHOLE re-pins (R-M3, H6): FULL keeps the long state in the finished table,
	# so at the narrow widths below JOBID, NAME and EXIT take their narrower forms
	sq_run fallback-throttled SQ_WIDTH=46 -- --full --no-color
	need "fallback-throttled W=46: 7002_… ×10 beside CANCELLED (WHOLE R-M3)" eval 'rc_is 0 && table_has recent "7002_… ×10 sweep CANCELLED"'
	for w in 66 67; do
		sq_run throttled SQ_WIDTH=$w -- --full --no-color
		need "throttled W=$w: the pending row 8000_[2-9] ×8" eval 'rc_is 0 && row_cell queue "8000_[2-9] ×8"'
	done
	sq_run throttled SQ_WIDTH=68 -- --full --no-color
	need "throttled W=68: 8000_[2-9%2] ×8" eval 'rc_is 0 && row_cell queue "8000_[2-9%2] ×8"'
	sq_run throttled SQ_WIDTH=64 -- --full --no-color
	need "throttled W=64: 8000_[…] ×8" eval 'rc_is 0 && row_cell queue "8000_[…] ×8"'
	sq_run throttled SQ_WIDTH=80 -- --full --no-color
	need "throttled W=80: %2 kept" eval 'rc_is 0 && rows queue | grep -qF "%2]"'
	sq_run fallback-throttled SQ_WIDTH=80 -- --full --no-color
	need "fallback-throttled W=80: %3 kept" eval 'rc_is 0 && rows recent | grep -qF "%3]"'
	for w in $(seq 40 120); do
		sq_run fallback-throttled SQ_WIDTH=$w -- --full --no-color
		if table_has recent "7002_[…] ×10" && [ "$(jobid_width recent)" -ge 14 ]; then bad="$bad $w"; fi
	done
	need "fallback-throttled W 40..120: never 7002_[…] ×10 in a column of 14 or more (at W =${bad:- none})" test -z "$bad"
	# F2: the floor
	for c in "memalloc-r:60:queue:11920_…" "oddarr:57:queue:9876543210_…" "oddarr:57:queue:11950_… ×11" "oddfin:38:recent:9876543210_…" \
	         "longplain:54:queue:123456789" "longplain:54:queue:123456790" "memalloc-r:33:recent:11899" "memalloc-r:33:recent:11897" \
	         "memalloc-r:33:recent:11893" "jobmem-outcomes:54:queue:4005_1" "jobmem-outcomes:54:queue:4005_0" "array-running:52:queue:1234_0:-x" \
	         "shrink-finished:44:recent:600_… sweep CANCELLED" "shrink-finished:48:recent:600_… ×67 sweep CANCELLED" \
	         "sf-longname:46:recent:600_… sweep-ir… CANCELLED" "shrink-pending:60:queue:600_[…] ×67 sweep" "shrink-pending:60:queue:(Res…" \
	         "throttled:60:queue:(JobA…" "sf-alice:44:recent:600_… sweep CANCELLED 0 by…" \
	         "sf-both:42:recent:sweep… CANCELLED" "sf-both:43:recent:sweep… CANCELLED" "sf-both:44:recent:sweep-… CANCELLED" "sf-both:45:recent:sweep… CANCELLED" \
	         "sf-both:46:recent:sweep-… CANCELLED" "sf-both:47:recent:sweep-i… CANCELLED" "sf-both:48:recent:600_… sweep-i… CANCELLED" \
	         "sf-alice:42:recent:0 by…" "sf-alice:43:recent:0 by…" "sf-alice:45:recent:600_… sweep CANCELLED 0 by m…" \
	         "sf-alice:46:recent:600_… sweep CANCELLED 0 by ma…" "sf-alice:48:recent:600_… sweep CANCELLED 0 by mall…" \
	         "oddfin:62:recent:12345678_… ×100 hugeids CANCELLED 0 by…" "oddfin:63:recent:12345678_… hugeids CANCELLED 0 by 1234567890" \
	         "oddfin:64:recent:12345678_… ×100 hugeids CANCELLED 0 by 1234567890" \
	         "oddfin:56:recent:11950_[…] ×11" "oddfin:59:recent:11950_[…] ×11" "oddfin:56:recent:9876543210_… tenbase" "oddfin:59:recent:9876543210_… "; do
		IFS=: read -r fx w table want extra <<< "$c"
		sq_run "$fx" SQ_WIDTH=$w -- --full --no-color $extra
		need "$fx${extra:+ $extra} W=$w, $table: '$want'" eval 'rc_is 0 && table_has $table "$want"'
	done
	sq_run sf-alice SQ_WIDTH=44 -- --full --no-color
	need "sf-alice W=44: JOBID 6 wide" eval 'rc_is 0 && [ "$(jobid_width recent)" = 6 ]'
	# F1 with a throttle of two digits (ft-32, the fallback's 0-99%32): %32 goes first, alone
	sq_run ft-32 SQ_WIDTH=52 -- --full --no-color
	need "ft-32 W=52: 7002_[0-99] ×100, the throttle gone first" eval 'rc_is 0 && row_cell recent "7002_[0-99] ×100"'
	sq_run ft-32 SQ_WIDTH=54 -- --full --no-color
	need "ft-32 W=54: 7002_[0-99%32] ×100" eval 'rc_is 0 && row_cell recent "7002_[0-99%32] ×100"'
	# F3, only where a column gains: the blanks that stay, the header and the row as they are
	for c in "shrink-finished:43:JOBID  NAME   STATE     EXIT  ELAPSED AGO:600_…  sweep  CANCELLED 0 by…      0s 11h" \
	         "shrink-finished:44:JOBID  NAME   STATE     EXIT   ELAPSED AGO:600_…  sweep  CANCELLED  0 by…      0s 11h" \
	         "shrink-finished:60:JOBID               NAME   STATE     EXIT      ELAPSED AGO:5000_[0,2,4,…] ×30  sweep  FAILED            1   1m00s 12h" \
	         "finished-throttled:41:JOBID  NAME  STATE     EXIT  ELAPSE AGO:7002_… sweep CANCELLED 0 by…     0s 12h" \
	         "finished-throttled:43:JOBID  NAME  STATE     EXIT   ELAPSED AGO:7002_… sweep CANCELLED  0 by…      0s 12h"; do
		IFS=: read -r fx w hdr want <<< "$c"
		sq_run "$fx" SQ_WIDTH=$w -- --full --no-color
		need "$fx W=$w, F3's blank that stays: '$hdr' over '$want'" eval '
			rc_is 0 && section recent | sed -E "s/^ +//" | grep -qxF -- "$hdr" && section recent | sed -E "s/^ +//" | grep -qxF -- "$want"'
	done
	for w in 43 44 45 46 47; do
		sq_run sf-both SQ_WIDTH=$w -- --full --no-color
		need "sf-both W=$w: the canceller 0 by… or 0 by m… (WHOLE R-M3: beside CANCELLED)" eval 'rc_is 0 && rows recent | grep -qE " 0 by( m)?…( |$)"'
	done
	# F4: a uid is whole, by… or gone
	bad=
	for w in 40 41 42 43 44 45 46; do
		sq_run shrink-finished SQ_WIDTH=$w -- --full --no-color
		got=$(rows recent | gawk '$1 ~ /^600_/ { for (i = 2; i <= NF; i++) if ($i == "CA" || $i == "CANCELLED") { x = $(i + 1); if ($(i + 2) ~ /^by/) x = x " " $(i + 2); if ($(i + 2) == "by") x = x " " $(i + 3); print x; exit } }')
		case $got in "0 by 1025"|"0 by…"|0) ;; *) bad="$bad $w($got)" ;; esac
	done
	need "shrink-finished W 40..46: the 600 row's EXIT 0 by 1025, 0 by… or 0, never a cut uid (not at W =${bad:- none})" test -z "$bad"
}
# scontrol_clean: scontrol was called, and no call of it saw an SCONTROL_* or SLURM_JSON
scontrol_clean() {
	gawk -F'\t' '$1 == "CALL" && $2 == "scontrol" { n++; if (/SCONTROL_/ || !/\tSLURM_JSON\(unset\)/) f = 1 } END { exit !(n && !f) }' "$LOG"
}
c_membar_call() {
	T_TITLE="scontrol --json show node once whenever sinfo answered, under CR_CORE too, no SCONTROL_* or SLURM_JSON reaching it, nor the -o fallback; none when sinfo did not answer"
	local c
	for c in idle busy crcore down; do
		sq_run "membar-$c" SCONTROL_ALL=1 SCONTROL_FEDERATION=1 SLURM_JSON=compact -- --full
		need "$c, a caller's SCONTROL_* and SLURM_JSON=compact: rc 0, stderr empty, scontrol --json show node once, without them" eval '
			rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && argv_has scontrol --json show node && scontrol_clean'
	done
	sq_run membar-busy SCONTROL_ALL=1 SLURM_JSON=compact SQSTUB_NOJSON=1 -- --full
	need "Slurm without --json: --json, then -o show node, neither seeing them" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && argv_has scontrol --json show node && argv_has scontrol -o show node && scontrol_clean'
	sq_run empty -- --full
	need "a node without MemSpecLimit: RealMemory counts" eval '
		rc_is 0 && [ "$(calls scontrol)" = 1 ] && mem_part_is node01 "░░░░░░░░░░░░░░░░ 0% 0/125G mem idle"'
	sq_run sinfo-fails -- --full
	need "sinfo failing: no scontrol call" eval '[ "$(calls sinfo)" = 1 ] && [ "$(calls scontrol)" = 0 ]'
}
membar_note() { plain | grep -E '^ *↳ memory counts RealMemory' | sed -E 's/^ +//'; }
c_membar_fail() {
	T_TITLE="scontrol failing or silent: RealMemory counts and one dim line under the nodes says why, cut to the width; none under CR_CORE; COMPACT makes room for it, and its summary line counts RealMemory without it"
	local d why='slurm_load_node error: Unable to contact slurm controller (connect failure)'
	d=$(mem_fixture membar-busy scontrol-node "@stderr $why\n@exit 1")
	sq_run "$d" -- --full --color
	need "failing: rc 0, stderr empty, 265 of 1007G and 70 of 78G" eval '
		rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" &&
		mem_part_is fb2-bioinf-0 "██████████████░░ 89% 70/78G mem allocated"'
	need "... the line right under the nodes, dim, naming the error of the -o call that followed, cut with … to the node lines' width" eval '
		[ "$(calls scontrol)" = 2 ] && plain | sed -n 5p | grep -q "^  ↳ memory counts RealMemory: scontrol failed (slurm_load_node error: Unable to .*…\$" &&
		sed -n 5p "$OUT" | grep -q "^  $ESC\[2m↳ .*…$ESC\[0m\$" && [ "$(cplain | sed -n 5p | LC_ALL=$utf8 gawk "{ print length(\$0) }")" -le "$(node_width)" ]'
	sq_run "$d" SQ_WIDTH=80 -- --full
	need "... at 80 columns too" eval 'rc_is 0 && membar_note | grep -q "…\$" && [ "$(width)" -le 80 ]'
	d=$(mem_fixture membar-busy scontrol-node "@exit 1")
	sq_run "$d" -- --full
	need "failing with nothing on stderr: the line whole, naming the exit status" eval '
		rc_is 0 && [ "$(membar_note)" = "↳ memory counts RealMemory: scontrol failed (exit 1)" ]'
	d=$(mem_fixture membar-busy scontrol-node "@stderr $why\n@exit 1")
	sq_run "$d" SQ_HEIGHT=12 -- --compact
	need "... COMPACT at 12 lines: the nodes with the line, within 12 lines, the footer last" eval '
		rc_is 0 && [ -n "$(membar_note)" ] && [ "$(plain | wc -l)" -le 12 ] && plain | tail -n 1 | grep -qE "^ +5 jobs "'
	sq_run "$d" SQ_HEIGHT=4 -- --compact
	need "... the summary line: allocated of RealMemory, its total marked ! (DISPLAY-v4 E1), no line for it" eval '
		rc_is 0 && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/!1085G mem" ] && [ -z "$(membar_note)" ]'
	d=$(mem_fixture membar-busy scontrol-node "@hang 10")
	sq_run "$d" -- --full
	need "silent: the same, after SQ_TIMEOUT, and no -o call after it" eval '
		rc_is 0 && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" && [ "$(calls scontrol)" = 1 ] &&
		[ "$(membar_note)" = "↳ memory counts RealMemory: scontrol failed (no response after 3s)" ]'
	d=$(mem_fixture membar-crcore scontrol-node "@stderr $why\n@exit 1")
	sq_run "$d" SQSTUB_HOST=FranzGB -- --full --no-color
	need "CR_CORE: no line, the screen as accepted" eval '
		rc_is 0 && [ -z "$(membar_note)" ] && cmp -s <(without_clock "$fixtures/membar-crcore/full-w120.txt") <(without_clock "$OUT")'
}
# A failing scontrol may have printed some nodes before it failed (a dump cut
# off, a controller lost mid-answer): what it printed is no answer, so the
# bars count RealMemory as for a failure with nothing printed, and no
# MemSpecLimit of the half answer is taken (fb2-bioinf's 31000 would make it
# 265/977G)
c_membar_partial() {
	T_TITLE="scontrol printing a node, then failing: no figure of it used, the screen of a failure that printed nothing"
	local d why='slurm_load_node error: Unable to contact slurm controller (connect failure)' first want
	first=$(grep -m1 '^NodeName=fb2-bioinf ' "$fixtures/membar-busy/scontrol-node")
	d=$(mem_fixture membar-busy scontrol-node "@stderr $why\n@exit 1")
	sq_run "$d" -- --full --color; want=$RUN/screen; without_clock "$OUT" > "$want"
	d=$(mem_fixture membar-busy scontrol-node "$first\n@stderr $why\n@exit 1")
	sq_run "$d" -- --full --color
	need "a node printed, then exit 1: rc 0, 265 of 1007G, the screen of the silent failure byte for byte" eval '
		rc_is 0 && [ "$(calls scontrol)" = 2 ] && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" && cmp -s "$want" <(without_clock "$OUT")'
	d=$(mem_fixture membar-busy scontrol-node "$first\n@stderr $why\n@exit 1")
	sq_run "$d" SQSTUB_NOJSON=1 -- --full --color
	need "... the same where --json is refused and only -o printed the node" eval '
		rc_is 0 && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" && cmp -s "$want" <(without_clock "$OUT")'
}
c_membar_over() {
	T_TITLE="allocated beyond what jobs can be given (RealMemory less MemSpecLimit): the bar full, the figure as it is, yellow, never bold red"
	local d
	d=$(mem_fixture membar-busy sinfo 'CPUsState=58/70/0/128; NodeList=fb2-bioinf; FreeMem=526168; Memory=1031000; StateLong=mixed; Reason=none; TimeStamp=Unknown; CPUsLoad=51.20; AllocMem=1024000
CPUsState=24/0/0/24; NodeList=fb2-bioinf-0; FreeMem=2176; Memory=80000; StateLong=allocated; Reason=none; TimeStamp=Unknown; CPUsLoad=23.81; AllocMem=71680')
	sq_run "$d" -- --full --color
	need "1000 of 977G: rc 0, 102 %, every cell █ in yellow, the figure bold" eval '
		rc_is 0 && err_empty && mem_part_is fb2-bioinf "████████████████ 102% 1000/977G mem mixed" &&
		bar_kinds_are fb2-bioinf 2 "33:█" && plain_has_sgr fb2-bioinf "$ESC[1m1000$ESC[0m/977G"'
}
plain_has_sgr() { grep -E "^ +$ESC\[1m$1( |$ESC)" "$OUT" | grep -qF -- "$2"; }   # plain_has_sgr NODE TEXT: NODE's coloured line holds TEXT
c_membar_down() {
	T_TITLE="a down node shows its allocated memory in the CPU bar's red: ▒ where its use is not known, █ where it is (draining), ░ or · for the rest"
	local d
	d=$(mem_fixture membar-down sinfo 'CPUsState=58/70/0/128; NodeList=fb2-bioinf; FreeMem=526168; Memory=1031000; StateLong=draining; Reason=disk; TimeStamp=2026-10-20T21:14:03; CPUsLoad=51.20; AllocMem=271360
CPUsState=8/0/16/24; NodeList=fb2-bioinf-0; FreeMem=N/A; Memory=80000; StateLong=down*; Reason=Not responding; TimeStamp=2026-10-20T21:14:03; CPUsLoad=N/A; AllocMem=40960')
	sq_run "$d" -- --full --color
	need "down*, 40G allocated, use not known: rc 0, 53 % of 75G, ▒ in dim red then ·, as its CPU bar" eval '
		rc_is 0 && err_empty && mem_part_is fb2-bioinf-0 "▒▒▒▒▒▒▒▒▒······· 53% 40/75G mem down*" &&
		bar_kinds_are fb2-bioinf-0 2 "2:· 2;31:▒" && bar_kinds_are fb2-bioinf-0 1 "2:· 2;31:▒"'
	need "draining, use known: █ in red, then ░" eval '
		mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem draining" && bar_kinds_are fb2-bioinf 2 "2:░ 31:█"'
}
c_membar_forged() {
	T_TITLE="MemSpecLimit only where Slurm prints it (--json; where Slurm has none, -o's one between the memory run and State): free text naming one, a forged line, a figure at or above RealMemory and a node scontrol does not list count none, and the caption says so"
	local d big small nojson forged
	big=$(grep '^NodeName=fb2-bioinf ' "$fixtures/membar-busy/scontrol-node")
	small=$(grep '^NodeName=fb2-bioinf-0 ' "$fixtures/membar-busy/scontrol-node")
	for nojson in "" SQSTUB_NOJSON=1; do
		d=$(mem_fixture membar-busy scontrol-node "${big/ MemSpecLimit=31000/} Reason=checking MemSpecLimit=500000 [root@2026-10-21T10:00:00]\n$small")
		sq_run "$d" $nojson -- --full
		need "${nojson:+no --json: }a Reason naming MemSpecLimit=, none before it: fb2-bioinf counts RealMemory, fb2-bioinf-0 its own, no line" eval '
			rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" &&
			mem_part_is fb2-bioinf-0 "███████████████░ 93% 70/75G mem allocated" && [ -z "$(membar_note)" ]'
		d=$(mem_fixture membar-busy scontrol-node "$big Reason=checking MemSpecLimit=500000 [root@2026-10-21T10:00:00]\n$small")
		sq_run "$d" $nojson -- --full
		need "${nojson:+no --json: }... and one before it: that one counts" eval 'rc_is 0 && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed"'
		if [ -n "$nojson" ]; then
			# written inside a value (stub.sh): MCS_label, before the free text,
			# its "=" as \x3d, so neither the record nor the made --json gets a key
			forged=' MCS_label=x\\nNodeName\\x3dfb2-bioinf RealMemory\\x3d1031000 AllocMem\\x3d0 MemSpecLimit\\x3d900000 State\\x3dIDLE'
			d=$(mem_fixture membar-busy scontrol-node "${big%% MCS_label=N/A*}$forged${big#* MCS_label=N/A}\n$small")
			sq_run "$d" $nojson -- --full
			need "no --json: an MCS_label whose newline starts a second NodeName=fb2-bioinf line: RealMemory counts" eval '
				rc_is 0 && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed"'
		else   # --json prints that Comment as one string, its newline escaped
			d=$(json_fx membar-busy "$json_add" NODE=fb2-bioinf KEY=comment V=$'x\nNodeName=fb2-bioinf RealMemory=1031000 AllocMem=0 MemSpecLimit=900000 State=IDLE')
			sq_run "$d" -- --full
			need "--json: a comment string holding a newline (escaped) and a NodeName=fb2-bioinf line: one node, its own MemSpecLimit, not the forged one" eval '
				rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed"'
		fi
		d=$(mem_fixture membar-busy scontrol-node "$big Extra=MemSpecLimit=0\n$small")
		sq_run "$d" $nojson -- --full
		need "${nojson:+no --json: }an Extra= at the end naming MemSpecLimit=0: ignored" eval 'rc_is 0 && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed"'
		d=$(mem_fixture membar-busy scontrol-node "${big/ MemSpecLimit=31000/ MemSpecLimit=1031000}\n${small/ MemSpecLimit=3200/ MemSpecLimit=lots}")
		sq_run "$d" $nojson -- --full
		need "${nojson:+no --json: }MemSpecLimit as large as RealMemory, or no number: RealMemory counts, the caption names both (N10)" eval '
			rc_is 0 && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" && mem_part_is fb2-bioinf-0 "██████████████░░ 89% 70/78G mem allocated" &&
			membar_note | grep -qxE "↳ memory counts RealMemory on fb2-bioinf and 1 more node: scontrol gave no usable MemSpecLimit( for them| ?…)"'
		d=$(mem_fixture membar-busy scontrol-node "$small")
		sq_run "$d" $nojson -- --full
		need "${nojson:+no --json: }fb2-bioinf not listed: RealMemory for it, fb2-bioinf-0 its own, the caption names it (N10)" eval '
			rc_is 0 && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" &&
			mem_part_is fb2-bioinf-0 "███████████████░ 93% 70/75G mem allocated" &&
			[ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bioinf: scontrol did not list it" ]'
		# one record whose Comment holds a newline and a line of its own: -o
		# prints two lines, a node listed twice; --json keeps it in a string
		d=$(mem_fixture membar-busy scontrol-node "$big Comment=x\\\\nNodeName=fb2-bioinf RealMemory=1031000 AllocMem=0 MemSpecLimit=900000 State=IDLE\n$small")
		sq_run "$d" $nojson -- --full
		if [ -n "$nojson" ]; then
			need "no --json: a Comment of one record holding a newline and a NodeName=fb2-bioinf line: that node unknown, RealMemory counts" eval '
				rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed"'
		else
			need "--json: the same record: the Comment a string, fb2-bioinf its own MemSpecLimit" eval '
				rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed"'
		fi
	done
}

# ---- scontrol --json show node: the line reader (node_json_read) -------------
# json_fx FROM PROGRAM [VAR=value...]: a copy of fixture FROM (every file an
# @include of the original) whose scontrol --json answer, scontrol-node.json,
# is the stub's own document for FROM run through the gawk PROGRAM (LC_ALL=C,
# json.awk's jstr at hand, each VAR=value in ENVIRON); prints its directory
json_fx() {
	local from=$1 prog=$2 d=$T_DIR/fx-json-$RANDOM f; shift 2
	[[ $from == /* ]] || from=$fixtures/$from
	mkdir -p "$d"
	for f in "$from"/*; do [ -f "$f" ] && printf '@include %s\n' "$f" > "$d/${f##*/}"; done
	rm -f "$d/scontrol-node.json"
	SQSTUB_LOG=$d/.stublog SQSTUB_FIXTURE=$from "$here/bin/scontrol" --json show node |
		env "$@" LC_ALL=C gawk -f "$here/lib/json.awk" -e "$prog" > "$d/scontrol-node.json"
	printf '%s' "$d"
}
# gawk programs for json_fx: a member KEY with ENVIRON["V"] as its string,
# or the raw JSON ENVIRON["J"], right after NODE's name; NODE's name line
# replaced by ENVIRON["J"]
json_add='{ print } $0 ~ "^ *\"name\": \"" ENVIRON["NODE"] "\",$" { ind = $0; sub(/".*/, "", ind)
	print ind "\"" ENVIRON["KEY"] "\": " (("J" in ENVIRON) ? ENVIRON["J"] : jstr(ENVIRON["V"])) "," }'
json_name='$0 ~ "^ *\"name\": \"" ENVIRON["NODE"] "\",$" { ind = $0; sub(/".*/, "", ind); print ind "\"name\": " ENVIRON["J"] ","; next } { print }'
# the accepted screen of membar-busy, FULL at 120 without colour
membar_busy_is() { cmp -s <(without_clock "$fixtures/membar-busy/full-w120.txt") <(without_clock "$OUT"); }
membar_real() {   # MemSpecLimit counting for neither node: both at RealMemory
	mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" && mem_part_is fb2-bioinf-0 "██████████████░░ 89% 70/78G mem allocated"
}
c_membar_json() {
	T_TITLE="scontrol --json read line by line: the accepted screen in every json-c layout, a figure no free text (reason, comment, os, architecture: quotes, backslash runs, forged members and nodes, every byte, invalid UTF-8, 128 KB runs) can reach, no gawk warning; a member or name twice, numbers that are none, no specialized_memory, escapes in a name, no nodes; 1000 nodes within 10 s"
	local d v k
	for v in 0.17 0.16 0.13; do
		sq_run membar-busy SQSTUB_JSONC=$v SQSTUB_HOST=FranzGB -- --full --no-color
		need "json-c $v's layout: rc 0, stderr empty, one call, the accepted screen" eval 'rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && membar_busy_is'
	done
	# free text: whatever a string holds stays in it
	for k in reason comment operating_system architecture; do
		for v in 'a"b\"c\\' 'trailing\\\\\\' $'\n      "specialized_memory": 999999,\n    },\n    {\n      "name": "ghost",\n      "real_memory": 1,' \
			"$(printf '%b' "$(printf '\\%03o' $(seq 1 255))")" $'ok\xff\xfe\xc3(\xe2\x82' '"nodes": [], "errors": ["x"], }'; do
			d=$(json_fx membar-busy "$json_add" NODE=fb2-bioinf KEY=$k V="$v")
			sq_run "$d" SQSTUB_HOST=FranzGB -- --full --no-color
			need "$k $(printf '%q' "$v" | cut -c1-40): rc 0, stderr empty (no gawk warning), one call, the accepted screen" eval '
				rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && membar_busy_is'
		done
	done
	d=$(json_fx membar-busy '{ print } /^ *"name": "fb2-bioinf",$/ { s = "\\\\"; q = "\\\""; while (length(s) < 131072) { s = s s; q = q q }
		print "      \"reason\": \"" s "\","; print "      \"comment\": \"" q "\","; print "      \"operating_system\": \"" s "x" q "\\\\\"," }')
	local start; start=$(date +%s%N)
	sq_run "$d" SQSTUB_HOST=FranzGB SQ_TIMEOUT=10 -- --full --no-color
	need "128 KB runs of backslashes and quotes: rc 0 within 10 s, stderr empty, the accepted screen" eval '
		rc_is 0 && err_empty && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 10000 ] && membar_busy_is'
	# invalid UTF-8 in a name and in partitions: read, kept, no warning
	d=$(json_fx membar-busy '/^ *"small"$/ { sub(/small/, "x\377\303y") } { print }
		/^    },$/ && !n++ { print "    {"; print "      \"name\": \"n\377\376\303(\","; print "      \"cpus\": 1"; print "    }," }')
	sq_run "$d" SQSTUB_HOST=FranzGB -- --full --no-color
	need "invalid UTF-8 in a name and in partitions: stderr empty, the accepted screen" eval 'rc_is 0 && err_empty && membar_busy_is'
	# a node unknown: specialized_memory twice, or named twice
	d=$(json_fx membar-busy "$json_add" NODE=fb2-bioinf KEY=specialized_memory J=0)
	sq_run "$d" -- --full
	need "specialized_memory twice: fb2-bioinf unknown, its RealMemory counts, fb2-bioinf-0 its own, the caption names it (N10)" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" &&
		mem_part_is fb2-bioinf-0 "███████████████░ 93% 70/75G mem allocated" &&
		[ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bioinf: scontrol gave no usable MemSpecLimit" ]'
	d=$(json_fx membar-busy "$json_name" NODE=fb2-bioinf-0 J='"fb2-bioinf"')
	sq_run "$d" -- --full
	need "a name in two nodes: both RealMemory (fb2-bioinf unknown, fb2-bioinf-0 not listed)" eval 'rc_is 0 && err_empty && membar_real'
	# numbers: only digits are one
	for v in null -1 -2 '"31000"' 31000.0 NaN Infinity 1e4 '{}'; do
		d=$(json_fx membar-busy '{ if ($0 ~ /^ *"specialized_memory": / && !n++) { sub(/: .*/, ": " ENVIRON["J"] ","); print } else print }' J="$v")
		sq_run "$d" -- --full
		need "specialized_memory $v: none, RealMemory counts for fb2-bioinf" eval '
			rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed"'
	done
	d=$(json_fx membar-busy '!/^ *"specialized_memory": / { print }')
	sq_run "$d" -- --full
	need "no specialized_memory: RealMemory counts for both" eval 'rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && membar_real'
	# escapes in a name: decoded before it is matched with sinfo's
	local u; u=$(printf '\134u')     # a backslash and u
	d=$(json_fx membar-busy "$json_name" NODE=fb2-bioinf J="\"fb2${u}002dbio${u}0069nf\"")
	sq_run "$d" SQSTUB_HOST=FranzGB -- --full --no-color
	need "a name written with \\u escapes: decoded, the accepted screen" eval 'rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && membar_busy_is'
	# no nodes at all: an answer, every node at RealMemory, the caption says so (N10)
	d=$(json_fx membar-busy '/^  "nodes": \[$/ { print "  \"nodes\": [],"; skip = 1; next } skip && /^  \],$/ { skip = 0; next } !skip { print }')
	sq_run "$d" -- --full
	need "an empty nodes array: one call, RealMemory for both, the caption naming the first" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && membar_real &&
		[ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bioinf and 1 more node: scontrol did not list them" ]'
	# 1000 nodes of 3 KB each (bioserver's are 3.5 KB), the first one padded
	# and copied, then the two of the fixture
	d=$(json_fx membar-busy 'n < 2 { L[++nl] = $0 } /^    [{}],?$/ && ++n == 2 { pad = "      \"energy\": {"; for (i = 1; i <= 40; i++) pad = pad "\n        \"e" i "\": {\"set\": true,\n          \"number\": " i "\n        },"; pad = pad "\n        \"last\": 0\n      },"
			for (k = 1; k <= 1000; k++) { print "    {"; print pad; print "      \"name\": \"big" k "\","; for (i = 2; i < nl - 1; i++) if (L[i] !~ /"name":/) print L[i]; print L[nl - 1]; print "    }," } }
		/^  "nodes": \[$/ { print; next } n >= 0 { print }')
	start=$(date +%s%N)
	sq_run "$d" SQSTUB_HOST=FranzGB SQ_TIMEOUT=10 -- --full --no-color
	need "1000 more nodes ($(( $(wc -c < "$d/scontrol-node.json") / 1024 )) KB): rc 0 within 10 s, stderr empty, the accepted screen" eval '
		rc_is 0 && err_empty && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 10000 ] && membar_busy_is'
}
# json_unusable PROGRAM WHAT: scontrol --json answering, exit 0, membar-busy's
# document run through the json_fx PROGRAM, unusable for WHAT: -o read
# instead, and nothing of the part read kept when -o fails too
json_unusable() {
	local d; d=$(json_fx membar-busy "$1")
	sq_run "$d" SQSTUB_HOST=FranzGB -- --full --no-color
	need "exit 0, unusable ($2): --json, then -o, the accepted screen" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && argv_has scontrol -o show node && membar_busy_is'
	printf '@stderr scontrol: error: down\n@exit 1\n' > "$d/scontrol-node"
	sq_run "$d" -- --full
	need "... -o failing too: nothing from the part read, its reason" eval '
		rc_is 0 && err_empty && membar_real && [ "$(membar_note)" = "↳ memory counts RealMemory: scontrol failed (scontrol: error: down)" ]'
}
# Node names pass the same rule in sinfo's answer and in scontrol's, so they
# join as they read: a name in Latin-1 lost its MemSpecLimit under -o, where
# gawk cut it on one side only.  Names that differ only in a broken byte or a
# bidi control are one name once decoded (Franz, 2026-10-24, "Accept the
# merge"): the node block shows the first of the two; scontrol then lists the
# name twice, so its memory bar counts RealMemory; array tasks named so fold.
# names_fx NAME A B: membar-busy, its nodes fb2-bioinf and fb2-bioinf-0 renamed
# A and B (fixture escapes) in sinfo and scontrol-node; prints its directory
names_fx() {
	local d=$T_DIR/fx-$1 f
	mkdir -p "$d"
	for f in sacct squeue; do printf '@include %s\n' "$fixtures/membar-busy/$f" > "$d/$f"; done
	for f in sinfo scontrol-node; do
		sed -e 's/fb2-bioinf-0/@B@/g' -e 's/fb2-bioinf/@A@/g' -e "s/@A@/$2/g" -e "s/@B@/$3/g" "$fixtures/membar-busy/$f" > "$d/$f"
	done
	printf '%s' "$d"
}
c_nodes_not_utf8() {
	T_TITLE="node names in Latin-1 join sinfo and scontrol (--json and -o): MemSpecLimit counts; names alike once decoded (n\\xe9x, n\\xe8x; fb2-bioinf and fb2-bioinf+U+202E) are one: one row, the first node's figures, RealMemory; array tasks named so fold"
	local d how fx name a b shown
	d=$(names_fx join 'fb2-bio\\xe9nf' fb2-bioinf-0)
	for how in json -o; do
		if [ $how = json ]; then sq_run "$d" SQSTUB_HOST=FranzGB -- --full --no-color; else sq_run "$d" SQSTUB_HOST=FranzGB SQSTUB_NOJSON=1 -- --full --no-color; fi
		need "fb2-bio␚nf, $how: rc 0, stderr empty, both nodes at RealMemory less MemSpecLimit" eval '
			rc_is 0 && err_empty && mem_part_is "fb2-bio␚nf" "████░░░░░░░░░░░░ 27% 265/977G mem mixed" &&
			mem_part_is fb2-bioinf-0 "███████████████░ 93% 70/75G mem allocated"'
	done
	for fx in 'twobad:n\\xe9x:n\\xe8x:n␚x' 'rlo:fb2-bioinf:fb2-bioinf\\xe2\\x80\\xae:fb2-bioinf'; do
		IFS=: read -r name a b shown <<< "$fx"
		d=$(names_fx "$name" "$a" "$b")
		for how in json -o; do
			if [ $how = json ]; then sq_run "$d" SQSTUB_HOST=FranzGB -- --full --no-color; else sq_run "$d" SQSTUB_HOST=FranzGB SQSTUB_NOJSON=1 -- --full --no-color; fi
			need "$name, $how: rc 0, stderr empty, one row $shown, the first node's CPUs, its memory at RealMemory" eval '
				rc_is 0 && err_empty && [ "$(plain | grep -cE "^ +$shown ")" = 1 ] && ! matches "^ +$shown .* 24/24 +cpu" &&
				matches "^ +$shown .* 58/128 +cpu" && mem_part_is "$shown" "████░░░░░░░░░░░░ 26% 265/1007G mem mixed"'
		done
	done
	d=$T_DIR/fx-fold; mkdir -p "$d"
	printf '@include %s\n' "$fixtures/_common/sinfo-two-idle" > "$d/sinfo"
	printf '@include %s\n' "$fixtures/_common/empty" > "$d/sacct"
	printf '@include %s\ni=5200_0; j=r\\xe9n\ni=5200_1; j=r\\xe8n\ni=5300_0; j=x\\xe2\\x80\\xaey\ni=5300_1; j=xy\n' "$fixtures/_common/squeue-defaults" > "$d/squeue"
	sq_run "$d" --
	need "tasks named r\\xe9n and r\\xe8n fold into one row r␚n, x+U+202E+y and xy into one xy" eval '
		rc_is 0 && err_empty && rows queue | grep -qE "^ +5200_\[0-1\] ×2 +r␚n " && rows queue | grep -qE "^ +5300_\[0-1\] ×2 +xy " && [ "$(nrows queue)" = 2 ]'
}

# A locale tool that knows no UTF-8 locale, first on PATH in DIR: gawk then runs
# in the caller's locale, C, as on a host with none installed (glibc's builtin
# C.UTF-8 makes LOCPATH no way to hide one)
no_utf8_locale() {   # no_utf8_locale DIR
	mkdir -p "$1"
	printf '#!/bin/sh\ncase "$1" in -a) printf "C\\nPOSIX\\n" ;; *) echo ANSI_X3.4-1968 ;; esac\n' > "$1/locale"; chmod +x "$1/locale"
}
# scontrol -o names, states and partitions take the tables' control rule, as
# the --json answer's do (json_str): a node name holding a control character
# joins its MemSpecLimit under -o too, and two names alike once the rule has
# read them are one, "listed twice", on either path.  Each run under -o draws
# the screen the --json path draws: under C.UTF-8, under a gawk forced to C
# (LC_ALL=C, no UTF-8 locale known) and with no locale set at all on such a host.
ctl_run() {   # ctl_run FIXTURE utf8|C|none [VAR=value...]: the dashboard, FULL, no colour
	local fx=$1 how=$2; shift 2
	case $how in
		utf8) sq_run "$fx" SQSTUB_HOST=FranzGB "$@" -- --full --no-color ;;
		C)    sq_run "$fx" SQSTUB_HOST=FranzGB LC_ALL=C PATH="$T_DIR/nobin:$here/bin:$PATH" "$@" -- --full --no-color ;;
		none) sq_run "$fx" SQSTUB_HOST=FranzGB -LC_ALL PATH="$T_DIR/nobin:$here/bin:$PATH" "$@" -- --full --no-color ;;
	esac
}
c_nodes_ctl_o() {
	T_TITLE="a node name with \\001 or \\302\\201: --json joins its MemSpecLimit; -o cannot ask scontrol by it (N5), so it reads RealMemory with the caption, the other node its own; node\\001 beside node? is 'twice' under --json, under -o node? its own; under C.UTF-8, a gawk forced to C and a host with no UTF-8 locale"
	local d how fx name a
	no_utf8_locale "$T_DIR/nobin"
	for fx in 'c0:fb2-bio\\x01nf' 'c1:fb2-bio\\xc2\\x81nf'; do
		IFS=: read -r name a <<< "$fx"
		d=$(names_fx "ctl-$name" "$a" fb2-bioinf-0)
		for how in utf8 C none; do
			ctl_run "$d" $how
			need "$name in the name, $how, --json: rc 0, stderr empty, fb2-bio?nf at RealMemory less MemSpecLimit (265/977G), no caption" eval '
				rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && matches "^ +fb2-bio\\?nf .* 265/977G +mem" && matches "^ +fb2-bioinf-0 .* 70/75G +mem" &&
				[ -z "$(membar_note)" ]'
			ctl_run "$d" $how SQSTUB_NOJSON=1
			need "$name in the name, $how, -o: rc 0, stderr empty, not asked about (only fb2-bioinf-0), fb2-bio?nf at RealMemory (265/1007G) with the caption, fb2-bioinf-0 its own" eval '
				rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && argv_has scontrol -o show node fb2-bioinf-0 &&
				matches "^ +fb2-bio\\?nf .* 265/1007G +mem" && matches "^ +fb2-bioinf-0 .* 70/75G +mem" &&
				[ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bio?nf: scontrol did not list it" ]'
		done
	done
	d=$(names_fx ctl-pair 'fb2-bio\\x01nf' 'fb2-bio?nf')
	for how in utf8 C none; do
		ctl_run "$d" $how
		need "fb2-bio\\x01nf beside fb2-bio?nf, $how, --json: two rows fb2-bio?nf at RealMemory (listed twice)" eval '
			rc_is 0 && err_empty && [ "$(plain | grep -cE "^ +fb2-bio\\?nf ")" = 2 ] && matches "^ +fb2-bio\\?nf .* 265/1007G +mem" &&
			matches "^ +fb2-bio\\?nf .* 70/78G +mem" && [ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bio?nf and 1 more node: scontrol listed them twice" ]'
		ctl_run "$d" $how SQSTUB_NOJSON=1
		need "fb2-bio\\x01nf beside fb2-bio?nf, $how, -o: asked about fb2-bio?nf alone; the first at RealMemory with the caption, fb2-bio?nf its own" eval '
			rc_is 0 && err_empty && [ "$(plain | grep -cE "^ +fb2-bio\\?nf ")" = 2 ] && argv_has scontrol -o show node "fb2-bio?nf" &&
			matches "^ +fb2-bio\\?nf .* 265/1007G +mem" && matches "^ +fb2-bio\\?nf .* 70/75G +mem" &&
			[ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bio?nf: scontrol did not list it" ]'
	done
}

c_membar_fallback() {
	T_TITLE="scontrol --json unusable (no --json, exit 0 but unreadable: empty, garbage, compact, cut, two documents, a BOM, trailing text, errors, no errors, a name not decodable; in an otherwise whole document an errors element, a closer of the wrong kind, a nodes element no object, a raw quote in a name): -o once more, read by node_read, nothing kept from the part read; a timeout asks no more; the -o call gets what is left of the bound; the last call's reason, FULL and COMPACT"
	local d p why='slurm_load_node error: Unable to contact slurm controller (connect failure)' start v i
	sq_run membar-busy SQSTUB_NOJSON=1 SQSTUB_HOST=FranzGB -- --full --no-color
	need "Slurm 22.05 (no --json): --json, then -o, the accepted screen" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && argv_has scontrol -o show node && membar_busy_is'
	for p in 'END { }' '{ } END { print "<html>not json</html>" }' '{ sub(/^ +/, ""); printf "%s", $0 } END { print "" }' \
		'{ print } /^    },$/ { exit }' '{ print; a[NR] = $0 } END { for (i = 1; i <= NR; i++) print a[i] }' \
		'NR == 1 { printf "\357\273\277" } { print }' '{ print } END { print "x" }' \
		'/^    },$/ && !n++ { print "    }"; skip = 1; next } skip && /^  \],$/ { skip = 0 } skip { next }
		 /^  "errors": \[\],$/ { print "  \"errors\": ["; print "    {"; print "      \"error_number\": 1"; print "    }"; print "  ],"; next } { print }' \
		'!/^  "errors": / { print }' '/"name": "fb2-bioinf-0"/ { sub(/-0/, "\\q") } { print }'; do
		json_unusable "$p" "$(printf '%s' "$p" | head -c 40)…"
	done
	# each a single flaw in a document otherwise whole and balanced
	local -a flaw=(
		'an errors array holding a string'
		'/^  "errors": \[\],$/ { print "  \"errors\": ["; print "    \"x\""; print "  ],"; next } { print }'
		'the nodes array closed by }'
		'/^  \],$/ { print "  },"; next } { print }'
		'the first node closed by ]'
		'/^    },$/ && !n++ { print "    ],"; next } { print }'
		'a string element of nodes'
		'{ print } /^  "nodes": \[$/ { print "    \"fb2-bioinf\"," }'
		'a raw quote in a name'
		'/"name": "fb2-bioinf-0"/ { sub(/-0/, "-\"0") } { print }'
	)
	for ((i = 0; i < ${#flaw[@]}; i += 2)); do json_unusable "${flaw[i + 1]}" "${flaw[i]}"; done
	d=$(json_fx membar-busy '{ print } END { print ""; print "  \t" }')
	sq_run "$d" SQSTUB_HOST=FranzGB -- --full --no-color
	need "blank lines after the document: read, one call" eval 'rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && membar_busy_is'
	# both failing: the -o call's reason, whatever --json said
	d=$(mem_fixture membar-busy scontrol-node "@stderr $why\n@exit 1")
	sq_run "$d" SQSTUB_NOJSON=1 SQ_HEIGHT=12 -- --compact
	need "no --json, -o failing: COMPACT names the -o call's reason" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && membar_note | grep -q "^↳ memory counts RealMemory: scontrol failed (slurm_load_node error: "'
	d=$(mem_fixture membar-busy scontrol-node "@exit 1")
	printf '@stderr scontrol: error: something else\n@exit 1\n' > "$d/scontrol-node.json"
	sq_run "$d" SQ_HEIGHT=12 -- --compact
	need "--json failing with a reason, -o with none: COMPACT's line whole, naming -o's exit status" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && [ "$(membar_note)" = "↳ memory counts RealMemory: scontrol failed (exit 1)" ]'
	d=$(mem_fixture membar-busy scontrol-node "@signal 9")
	printf '@exit 1\n' > "$d/scontrol-node.json"
	sq_run "$d" -- --full
	need "-o killed: signal 9" eval 'rc_is 0 && [ "$(membar_note)" = "↳ memory counts RealMemory: scontrol failed (signal 9)" ]'
	# -o with no record: asked for both, scontrol says neither is found, exit
	# 1 with nothing on stderr: an answer (N4), the caption says so (N10)
	d=$(mem_fixture membar-busy scontrol-node "# no node")
	printf 'garbage\n' > "$d/scontrol-node.json"
	sq_run "$d" -- --full
	need "-o finding no node asked for: used, RealMemory for both, the caption naming the first" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && membar_real &&
		[ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bioinf and 1 more node: scontrol did not list them" ]'
	# the -o call within what the --json call left of SQ_TIMEOUT, its
	# timeout named by the first bound
	d=$(mem_fixture membar-busy scontrol-node "@hang 10")
	printf '@hang 1\n@exit 1\n' > "$d/scontrol-node.json"
	start=$(date +%s%N)
	sq_run "$d" "$(timeout_as)" SQSTUB_TIMEOUT=log SQ_TIMEOUT=3 -- --full
	need "--json failing after 1 s, -o hanging: -o bounded by about 2 s, done within 4.5 s, 'no response after 3s'" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && [ "$(timeout_of scontrol)" = 3 ] && v=$(timeout_of scontrol 2) &&
		[ "${v%%.*}" -ge 1 ] && [ "${v%%.*}" -lt 2 ] && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 4500 ] &&
		[ "$(membar_note)" = "↳ memory counts RealMemory: scontrol failed (no response after 3s)" ]'
	sq_run "$d" "$(timeout_as)" SQSTUB_TIMEOUT=log SQ_TIMEOUT=2.5 -- --full
	need "... SQ_TIMEOUT=2.5: named as given" eval 'rc_is 0 && [ "$(membar_note)" = "↳ memory counts RealMemory: scontrol failed (no response after 2.5s)" ]'
}

# ============================================================================
# memory use of the caller's own running jobs (JOBMEM-v4)
# ============================================================================
# The jobmem fixtures are bioserver's as fsill (uid 1041) sees it; mem_run
# runs sq as fsill, on bioserver's host name and in the zone of the accepted
# screens: TZ=CEST-2 prints "CEST" all year and has no DST hour that mktime
# could read back wrong, which is why the other cases use UTC.
mem_run() {   # mem_run FIXTURE [VAR=value | -VAR]... -- [sq args]: sq_run as fsill
	local fx=$1; shift
	sq_run "$fx" SQSTUB_UID=1041 TZ=CEST-2 SQSTUB_HOST=fb2-bioinf "$@"
}
row_raw() {   # row_raw ID: the queue row whose JOBID is ID, as printed
	ID=$1 LC_ALL=$utf8 gawk '{ t = $0; gsub(/\033\[[0-9;]*m/, "", t); gsub(/\r/, "", t); split(t, f, " ") }
		f[1] == ENVIRON["ID"] && t ~ / (RUNNING|PENDING) / { print; exit }' "$OUT"
}
row_has() { [[ "$(row_raw "$1")" == *"$2"* ]]; }        # row_has ID TEXT (escapes as $ESC[..m)
row_sgr() { row_raw "$1" | LC_ALL=C grep -o "$ESC\[[0-9;]*m" | paste -sd' '; }   # its escapes
mem_of() {    # mem_of ID: the MEM cell of row ID, plain (default columns: the one before NODE/REASON)
	rows queue | ID=$1 gawk '$1 == ENVIRON["ID"] { print $(NF-1); exit }'
}
epoch_now() { printf '%(%s)T' -1; }
mem_fixture() {   # mem_fixture FROM FILE TEXT: a copy of fixture FROM whose FILE is TEXT (fixture escapes)
	local d=$T_DIR/fx-$2-$RANDOM f; mkdir -p "$d"
	for f in sinfo sacct squeue squeue-alloc squeue-tres sstat squeue-all scontrol-node; do
		[ -f "$fixtures/$1/$f" ] && printf '@include %s\n' "$fixtures/$1/$f" > "$d/$f"
	done
	printf '%b\n' "$3" > "$d/$2"
	printf '%s' "$d"
}
c_jobmem_screens() {
	T_TITLE="the accepted JOBMEM screens byte for byte, clock aside: b in a pipe, a on a narrow screen with colour, COMPACT keeping the jobs at risk"
	local fx=$fixtures/jobmem n
	mem_run jobmem SQ_WIDTH=110 SQ_HEIGHT=30 -- --color --full
	need "b, FULL at 110 in a pipe: rc 0, stderr empty" eval 'rc_is 0 && err_empty'
	need "b, FULL at 110: the accepted screen" eval 'cmp -s <(without_clock "$fx/b__full-w110-h30.ansi") <(without_clock "$OUT")'
	need "one allocation call, squeue -h -u 1041, unfiltered" eval '[ "$(calls alloc)" -eq 1 ] && argv_has squeue -h -u 1041'
	n=$(env_of squeue 2 SQ_NONCE)
	need "its format in SQUEUE_FORMAT2, framed by the queue nonce, which stays off every command line" eval '
		[ "$(env_of squeue 2 SQUEUE_FORMAT2)" = "JobID:$n,StateCompact:$n,tres-alloc:$n,NumNodes:$n" ] &&
		[ "$(env_of squeue 2 SQUEUE_FORMAT)" = "(unset)" ] && ! grep "^CALL" "$LOG" | cut -f3 | grep -qF "$n"'
	need "one sstat call for the 8 running jobs with an allocation, in the order of the allocation call" eval '
		[ "$(calls sstat)" -eq 1 ] && argv_has sstat -n -p -a --noconvert -j 11895,11898,11902,11903,11904,11905,11906,11908 -o JobID,TRESUsageInTot'
	mem_run jobmem SQ_WIDTH=80 SQ_HEIGHT=30 COLUMNS=80 LINES=30 -- --color --full
	need "a, FULL at 80 on a screen: rc 0, stderr empty, the accepted screen" eval '
		rc_is 0 && err_empty && cmp -s <(without_clock "$fx/a-fallback__full-w80-h30.ansi") <(without_clock "$OUT")'
	mem_run jobmem SQ_WIDTH=100 SQ_HEIGHT=16 COLUMNS=100 LINES=16 -- --color --compact
	need "b, COMPACT at 100x16: rc 0, stderr empty, the accepted screen" eval '
		rc_is 0 && err_empty && cmp -s <(without_clock "$fx/b__compact-w100-h16.ansi") <(without_clock "$OUT")'
}
c_jobmem_gates() {
	T_TITLE="no allocation call and no sstat without an own running row, under a cluster selection, or without MEM; other rows keep MEM as it is"
	local args base d=$T_DIR/fx-pending f
	for args in "" "-M bioinf" "--clusters=bioinf" "--federation" "--sibling" "-o i,j,u,T,M,L,C,R"; do
		mem_run jobmem SQSTUB_UID=4242 SQ_WIDTH=110 -- --color $args
		base=$RUN/base; without_clock "$OUT" > "$base"
		need "${args:-no args} as nobody of the queue: rc 0, no allocation call, no sstat" \
			eval 'rc_is 0 && [ "$(calls alloc)" -eq 0 ] && [ "$(calls sstat)" -eq 0 ]'
		[ -n "$args" ] || continue
		mem_run jobmem SQ_WIDTH=110 -- --color $args
		need "$args as fsill: rc 0, stderr empty, no allocation call, no sstat, the screen nobody gets" \
			eval 'rc_is 0 && err_empty && [ "$(calls alloc)" -eq 0 ] && [ "$(calls sstat)" -eq 0 ] && cmp -s "$base" <(without_clock "$OUT")'
	done
	need "MEM not shown: no %A %U asked for either" eval '! env_of squeue 1 SQUEUE_FORMAT | grep -qE "%[AU]"'
	mem_run jobmem SQSTUB_UID=4242 SQ_WIDTH=110 SLURM_CLUSTERS=bioinf -- --color
	base=$RUN/base; without_clock "$OUT" > "$base"
	mem_run jobmem SQ_WIDTH=110 SLURM_CLUSTERS=bioinf -- --color
	need "SLURM_CLUSTERS=bioinf, as fsill: rc 0, no allocation call, no sstat, the screen nobody gets, sacct -M bioinf" \
		eval 'rc_is 0 && [ "$(calls alloc)" -eq 0 ] && [ "$(calls sstat)" -eq 0 ] && cmp -s "$base" <(without_clock "$OUT") && argv_has sacct -M bioinf'
	# empty: squeue would fail ("No cluster '' known by database."), so sq
	# refuses it (OPTS-v4 D10)
	mem_run jobmem SQ_WIDTH=110 SLURM_CLUSTERS= -- --color
	need "SLURM_CLUSTERS='': rc 2, no call" eval 'rc_is 2 && out_empty && no_slurm_call &&
		err_is "sq: SLURM_CLUSTERS is set but holds no cluster name; unset it, or set one, e.g. SLURM_CLUSTERS=mycluster"'
	# an option's value is no option: a job named --federation selects no cluster
	mem_run jobmem SQ_WIDTH=110 -- --color -n --federation
	need "-n --federation (a job name): rc 0, the allocation call and sstat once each" eval 'rc_is 0 && [ "$(calls alloc)" -eq 1 ] && [ "$(calls sstat)" -eq 1 ]'
	# the screen's filters never reach the allocation call, nor narrow what sstat asks
	mem_run jobmem SQ_WIDTH=110 -- --color -p main -j 11895 -u fsill -n flye
	need "filters on the screen: the allocation call is still squeue -h -u 1041 and nothing else, sstat still asks for all 8" eval '
		rc_is 0 && [ "$(gawk -F"\t" "\$1 == \"CALL\" && \$2 == \"squeue\" && /tres-alloc/ && /StateCompact/ { print \$3 }" "$LOG")" = "-h -u 1041 " ] &&
		argv_has sstat -j 11895,11898,11902,11903,11904,11905,11906,11908'
	# ... nor do the filters a caller exports, which the screen's calls take as
	# their flags (OPTS-v4 N4), in squeue's order, the variables unset
	local filters="SQUEUE_PARTITION SQUEUE_STATES SQUEUE_ACCOUNT SQUEUE_QOS SQUEUE_NAMES" v
	mem_run jobmem SQ_WIDTH=110 SQUEUE_PARTITION=main SQUEUE_STATES=R,PD SQUEUE_ACCOUNT=bio SQUEUE_QOS=normal SQUEUE_NAMES=flye -- --color
	need "SQUEUE_* filters exported: rc 0, the allocation call once, its SQUEUE_FORMAT2 sq's" eval '
		rc_is 0 && [ "$(calls alloc)" -eq 1 ] && gawk -F"\t" "\$1 == \"CALL\" && /tres-alloc/ && /StateCompact/ && /\tSQUEUE_FORMAT2=JobID/ { f = 1 } END { exit !f }" "$LOG"'
	for v in $filters; do
		need "$v: in no squeue call's environment" eval '
			gawk -F"\t" -v v='"$v"' "\$1 == \"CALL\" && \$2 == \"squeue\" { for (i = 4; i <= NF; i++) if (index(\$i, v \"=\") == 1) has = 1 }
				END { exit has }" "$LOG"'
	done
	need "the queue call and the MEM totals' call: their pairs in argv, -A bio -n flye -p main -q normal -t R,PD; the allocation call none" eval '
		argv_has squeue -h -S t,i -A bio -n flye -p main -q normal -t R,PD && argv_has squeue -h -A bio -n flye -p main -q normal -t R,PD &&
		[ "$(gawk -F"\t" "\$1 == \"CALL\" && \$2 == \"squeue\" && /tres-alloc/ && /StateCompact/ { print \$3 }" "$LOG")" = "-h -u 1041 " ]'
	# fsill with a pending job only: no call
	mkdir -p "$d"
	for f in sinfo sacct; do printf '@include %s\n' "$fixtures/jobmem/$f" > "$d/$f"; done
	{ printf '@include %s\n' "$fixtures/_common/squeue-defaults"; grep -E '^i=(11912|11880|11889);' "$fixtures/jobmem/squeue"; } > "$d/squeue"
	mem_run "$d" SQSTUB_UID=4242 SQ_WIDTH=110 -- --color
	base=$RUN/base; without_clock "$OUT" > "$base"
	mem_run "$d" SQ_WIDTH=110 -- --color
	need "fsill pending only: rc 0, no allocation call, no sstat, the screen nobody gets" \
		eval 'rc_is 0 && [ "$(calls alloc)" -eq 0 ] && [ "$(calls sstat)" -eq 0 ] && cmp -s "$base" <(without_clock "$OUT")'
	need "... and no state written" eval '[ ! -e "$RUN/home/.cache" ]'
	# the feature on: other users' rows and fsill's pending one keep their
	# colours, and MEM is their total (MEMALLOC: no longer %m, which reads 2G for
	# cellranger, --mem-per-cpu=2G -c 16), whoever is looking
	local sgr=() id i=0 total=(48G 100G 32G)
	mem_run jobmem SQSTUB_UID=4242 SQ_WIDTH=110 -- --color
	for id in 11912 11880 11889; do sgr+=("$(row_sgr $id)"); done
	mem_run jobmem SQ_WIDTH=110 -- --color
	need "as fsill: rc 0, the allocation call and sstat once each" eval 'rc_is 0 && [ "$(calls alloc)" -eq 1 ] && [ "$(calls sstat)" -eq 1 ]'
	for id in 11912 11880 11889; do
		need "$id (not an own running job): MEM its total, ${total[$i]}, the row coloured as without the feature" \
			eval '[ "$(row_sgr '"$id"')" = "${sgr['"$i"']}" ] && [ "$(mem_of '"$id"')" = "${total['"$i"']}" ]'
		i=$((i + 1))
	done
}
c_jobmem_throttle() {
	T_TITLE="sstat at most every 30 s: a fresh snapshot is reused; one 30 s old by sq's clock, older, future, missing or garbled calls again; renamed into place; a job started since reads ?; no usable state dir (or memuse no file) calls every run"
	local cache=$T_DIR/cache first want=$T_DIR/memuse.want snap now bad
	snap=$cache/sq/memuse
	# The clock may step a second or two between this shell reading it and sq
	# reading it (WSL steps back about 1.5 s every 30 s), so a snapshot is dated
	# well inside or outside the 30 s, never near an edge: 10 s old is fresh,
	# 40 s old is stale.  snap_age AGE rewrites the epoch, keeping the job lines.
	snap_age() { sed -i "1s/.*/$(( $(epoch_now) - $1 ))/" "$snap" 2>/dev/null; }
	printf '%s\t%s\t%s\n' 11895 ok 89335316480 11898 ok 33260224512 11902 ok 8123781120 11903 ok 8227962880 \
		11904 ok 17884241920 11905 ok 7911325696 11906 ok 50989846528 11908 none 0 > "$want"
	now=$(epoch_now)
	mkdir -p "$cache/sq"            # so a sq that writes no snapshot fails the needs, not the shell
	mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
	need "first run: rc 0, stderr empty, one sstat call" eval 'rc_is 0 && err_empty && [ "$(calls sstat)" -eq 1 ]'
	need "the snapshot: the epoch of the call, then id, outcome and bytes of each job asked" \
		eval 'e=$(head -n 1 "$snap" 2>/dev/null) && [ "$e" -ge "$((now - 5))" ] && [ "$e" -le "$(( $(epoch_now) + 5 ))" ] && cmp -s <(tail -n +2 "$snap") "$want"'
	need "nothing else in the state dir: the temp renamed, no bell state" eval '[ "$(ls -A "$cache/sq")" = memuse ]'
	first=$RUN/first; without_clock "$OUT" > "$first"
	snap_age 10
	mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
	need "10 s old: rc 0, no sstat, the allocation asked again, the same screen" \
		eval 'rc_is 0 && [ "$(calls sstat)" -eq 0 ] && [ "$(calls alloc)" -eq 1 ] && cmp -s "$first" <(without_clock "$OUT")'
	snap_age 40
	mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
	need "a snapshot 40 s old: rc 0, sstat called, the snapshot renewed, the same screen" \
		eval 'rc_is 0 && [ "$(calls sstat)" -eq 1 ] && [ "$(head -n 1 "$snap" 2>/dev/null)" -ge "$(( $(epoch_now) - 10 ))" ] && cmp -s "$first" <(without_clock "$OUT")'
	snap_age -60
	mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
	need "a snapshot from the future: rc 0, sstat called" eval 'rc_is 0 && [ "$(calls sstat)" -eq 1 ]'
	# a job started since the snapshot: a dim ?, and no call for it
	grep -v '^11904	' "$want" | sed '1i\0' > "$snap"; snap_age 10
	mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
	need "megahit not in a fresh snapshot: rc 0, no sstat, a dim ? before its allocation, the others read" \
		eval 'rc_is 0 && [ "$(calls sstat)" -eq 0 ] && row_has 11904 "$ESC[2m?$ESC[0m/16G" && row_has 11898 "$ESC[31m  31/32G$ESC[0m"'
	for bad in "garbage" "$(epoch_now)\n11895\tok\tlots" "$(epoch_now)\n11895 ok 89335316480" "" "$(epoch_now)\n11895\tmaybe\t0"; do
		printf "$bad" > "$snap"
		mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
		need "a garbled snapshot ('${bad//\\/\\\\}'): rc 0, stderr empty, sstat called, the readings shown" \
			eval 'rc_is 0 && err_empty && [ "$(calls sstat)" -eq 1 ] && cmp -s "$first" <(without_clock "$OUT")'
	done
	# Exactly 30 s old is a call (>= 30, not > 30).  Only sq's own clock can
	# tell a snapshot's age, and only a call shows it (the new snapshot's
	# epoch).  So each try dates the snapshot 30 s before the second sq is
	# expected to read, T, and counts as a hit only when sq called AND read T.
	# A try that missed T says nothing either way and corrects the guess: a
	# call shows the second sq read, no call means sq read before T.  A sq
	# that wants more than 30 s never calls at T, so it never hits; a clock
	# step only costs a try.  Each try is cheap (no finished block).
	local tries=0 hit=0 lag=0 at target got
	while [ $tries -lt 20 ] && [ $hit = 0 ]; do
		tries=$((tries + 1)); at=$(epoch_now); target=$((at + lag))
		{ echo $((target - 30)); cat "$want"; } > "$snap"
		mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --no-recent
		if [ "$(calls sstat)" -eq 1 ]; then
			got=$(head -n 1 "$snap" 2>/dev/null)
			if [ "$got" = "$target" ]; then hit=1; else lag=$(( got - at )); fi
		else
			lag=$((lag - 1)); [ $lag -ge -2 ] || lag=0
		fi
	done
	need "a snapshot exactly 30 s old by sq's clock: sstat called (hit at try $tries of at most 20)" test $hit = 1
	# replaced by a rename: a hard link to the old snapshot keeps it intact
	snap_age 40
	rm -f "$T_DIR/old"; ln "$snap" "$T_DIR/old" 2>/dev/null; cp "$snap" "$T_DIR/old.want" 2>/dev/null
	mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
	need "a new snapshot is renamed into place: the old file, held by a hard link, is untouched, no temp is left" \
		eval 'rc_is 0 && [ "$(calls sstat)" -eq 1 ] && cmp -s "$T_DIR/old" "$T_DIR/old.want" && ! [ "$snap" -ef "$T_DIR/old" ] && [ "$(ls -A "$cache/sq")" = memuse ]'
	# memuse that is no regular file: unusable state, silently; nothing put into it
	rm -f "$snap"; mkdir "$snap"
	for f in 1 2; do
		mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
		need "memuse a directory, run $f: rc 0, stderr empty, sstat called, the readings shown, nothing put into it or beside it" \
			eval 'rc_is 0 && err_empty && [ "$(calls sstat)" -eq 1 ] && cmp -s "$first" <(without_clock "$OUT") && [ -z "$(ls -A "$snap")" ] && [ "$(ls -A "$cache/sq")" = memuse ]'
	done
	rmdir "$snap"
	mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
	need "no snapshot: rc 0, sstat called" eval 'rc_is 0 && [ "$(calls sstat)" -eq 1 ]'
	# no usable state dir: a call every run, silently, readings shown all the same
	: > "$T_DIR/afile"
	for f in 1 2; do
		mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME="$T_DIR/afile" -- --color
		need "state dir under a file, run $f: rc 0, stderr empty, sstat called, the readings shown" \
			eval 'rc_is 0 && err_empty && [ "$(calls sstat)" -eq 1 ] && cmp -s "$first" <(without_clock "$OUT")'
	done
	mem_run jobmem SQ_WIDTH=110 XDG_CACHE_HOME=relcache -- --color
	need "a relative XDG_CACHE_HOME is not used: the snapshot under HOME/.cache" eval 'rc_is 0 && [ -s "$RUN/home/.cache/sq/memuse" ]'
}
c_jobmem_outcomes() {
	T_TITLE="each outcome: ok, a step error, no steps, no mem= (vmem= alone too), array steps once, two nodes, gone, own by uid alone; a stderr line naming two jobs; sstat timing out, the allocation call failing, unreadable or cut off; colour off"
	local d t0 ms id cache=$T_DIR/cache
	mem_run jobmem-outcomes -- --color
	need "rc 0, stderr empty, sstat asked for the eight measured jobs" eval 'rc_is 0 && err_empty && argv_has sstat -j 4001,4002,4003,4004,4005,4006,4011,4012'
	need "ok: 1/4G, green; lines naming no job or another job leave it so" row_has 4001 "$ESC[32m  1/4G$ESC[0m"
	need "a step named on stderr: a red ! on that job" row_has 4002 "$ESC[31m!$ESC[0m/4G"
	need "'No steps running': a dim ?" row_has 4003 "$ESC[2m?$ESC[0m/4G"
	need "rows without mem=: a red !" row_has 4004 "$ESC[31m!$ESC[0m/4G"
	need "a row with vmem= but no mem=: a red !" row_has 4011 "$ESC[31m!$ESC[0m/4G"
	need "the task holding the array's id: its own step, 0.5/4G" row_has 4005_1 "$ESC[32m0.5/4G$ESC[0m"
	need "a step that came twice counts once: 1.5/4G, green, not 3/4G" row_has 4005_0 "$ESC[32m1.5/4G$ESC[0m"
	need "two nodes, not measured: a dim ? before the allocation" row_has 4007 "$ESC[2m?$ESC[0m/8G"
	need "gone from the allocation call: a dim ? before MEM as it was, no slash" row_has 4008 "$ESC[2m?$ESC[0m4G "
	need "another user's row and an own pending one: MEM as it is, uncoloured" eval 'row_has 4009 " 4G " && row_has 4010 " 4G "'
	need "own is the uid: measured though %u names another login, not measured though it names fsill" \
		eval 'row_has 4012 "$ESC[32m  1/4G$ESC[0m" && row_has 4013 " 4G "'
	d=$(mem_fixture jobmem-outcomes squeue "@include $fixtures/jobmem-outcomes/squeue\ni=4014; A=4014; j=mylogin; M=47:00; U=1012; u=$(id -un)")
	mem_run "$d" -- --color
	need "a row whose %u is the login running the suite, under another uid: MEM as it is" eval 'rc_is 0 && row_has 4014 " 4G " && row_has 4001 "$ESC[32m  1/4G$ESC[0m"'
	# one stderr line naming two jobs fails both
	d=$(mem_fixture jobmem-outcomes sstat "@include $fixtures/jobmem-outcomes/sstat\n@stderr sstat: error: problem getting step_layout for StepId=4001.0 and for job 4012: Communication connection failure")
	mem_run "$d" -- --color
	need "a stderr line naming two jobs: a red ! on both, the others as they were" \
		eval 'rc_is 0 && row_has 4001 "$ESC[31m!$ESC[0m/4G" && row_has 4012 "$ESC[31m!$ESC[0m/4G" && row_has 4005_0 "$ESC[32m1.5/4G$ESC[0m"'
	mem_run jobmem-outcomes -- --no-color
	need "colour off: rc 0, no escapes, plain ! and ?" eval 'rc_is 0 && [ "$(escapes)" -eq 0 ] &&
		[ "$(mem_of 4001) $(mem_of 4002) $(mem_of 4003) $(mem_of 4004) $(mem_of 4007) $(mem_of 4008)" = "1/4G !/4G ?/4G !/4G ?/8G ?4G" ]'
	# sstat silent past its budget, min(SQ_TIMEOUT, 2) s
	d=$(mem_fixture jobmem-outcomes sstat '@hang 8')
	t0=$(date +%s%N)
	mem_run "$d" SQ_TIMEOUT=6 XDG_CACHE_HOME="$cache" -- --color
	ms=$(( ($(date +%s%N) - t0) / 1000000 ))
	need "sstat silent (SQ_TIMEOUT=6): rc 0, stderr empty, cut at 2 s, so done within 5 s (took ${ms}ms)" eval 'rc_is 0 && err_empty && [ "$ms" -lt 5000 ]'
	for id in 4001 4002 4003 4004 4005_1 4005_0 4011 4012; do
		need "timeout: $id a red !" row_has $id "$ESC[31m!$ESC[0m/4G"
	done
	need "timeout: the unmeasured keep their dim ?" eval 'row_has 4007 "$ESC[2m?$ESC[0m/8G" && row_has 4008 "$ESC[2m?$ESC[0m4G "'
	need "timeout: no banner, nothing else changes" eval 'lacks "unreachable" && footer_is 13 12 1 0 && row_has 4013 " 4G "'
	sed -i "1s/.*/$(( $(epoch_now) - 10 ))/" "$cache/sq/memuse" 2>/dev/null   # 10 s old: clear of any clock step
	mem_run "$d" SQ_TIMEOUT=6 XDG_CACHE_HOME="$cache" -- --color
	need "the failure is kept: a run within 30 s shows it again without asking" eval 'rc_is 0 && [ "$(calls sstat)" -eq 0 ] && row_has 4002 "$ESC[31m!$ESC[0m/4G" && row_has 4001 "$ESC[31m!$ESC[0m/4G"'
	# the allocation call failing, or answering what cannot be read: every own
	# running row a red !, MEM as it was
	for how in "exit 1" "unreadable, exit 0" "cut off, exit 0"; do
		case $how in
			exit*)       d=$(mem_fixture jobmem-outcomes squeue-alloc '@stderr squeue: error: Socket timed out on send/recv operation\n@exit 1') ;;
			unreadable*) d=$(mem_fixture jobmem-outcomes squeue-alloc "@include $fixtures/jobmem-outcomes/squeue-alloc\n@raw not a record") ;;
			# the last record whole but for its closing separator and newline
			cut*)        d=$(mem_fixture jobmem-outcomes squeue-alloc "@include $fixtures/jobmem-outcomes/squeue-alloc\n@cut\nJobID=4099") ;;
		esac
		mem_run "$d" -- --color
		need "allocation call $how: rc 0, stderr empty, no sstat, no banner" eval 'rc_is 0 && err_empty && [ "$(calls sstat)" -eq 0 ] && lacks "unreachable"'
		for id in 4001 4002 4003 4004 4005_1 4005_0 4008 4011 4012; do
			need "allocation call $how: $id a red ! before MEM as it was" row_has $id "$ESC[31m!$ESC[0m4G "
		done
		need "allocation call $how: two nodes too, others unchanged" eval 'row_has 4007 "$ESC[31m!$ESC[0m8G " && row_has 4009 " 4G " && row_has 4010 " 4G " && row_has 4013 " 4G "'
	done
}
c_jobmem_forms() {
	T_TITLE="form b: units M, G, T, decimal allocations, the guard, a width set by the allocations; on a screen whole numbers, then form a with colour; a pipe stays decimal"
	local d head
	mem_run jobmem-forms -- --color
	need "rc 0, stderr empty" eval 'rc_is 0 && err_empty'
	need "512M: in M, 200/512M" row_has 5001 "$ESC[32m  200/512M$ESC[0m"
	need "1000M: in G already, cut to 0.9G, never rounded up" row_has 5002 "$ESC[32m 0.5/0.9G$ESC[0m"
	need "2T: in T, 1.2/2T" row_has 5003 "$ESC[32m1.2/2T$ESC[0m"
	need "15.97 of 16G: one step below, 15.9/16G, red, never 16/16G" row_has 5004 "$ESC[31m15.9/16G$ESC[0m"
	need "16.2 of 16G: 16/16G, bold red" row_has 5005 "$ESC[1;31m  16/16G$ESC[0m"
	need "1.50G: 0.6/1.5G" row_has 5006 "$ESC[32m 0.6/1.5G$ESC[0m"
	need "98.5 % of 15600M: the allocation with its decimal, 15.0/15.2G" row_has 5007 "$ESC[31m 15.0/15.2G$ESC[0m"
	need "99.9 % of 15600M: one step below the allocation, 15.1/15.2G" row_has 5008 "$ESC[31m 15.1/15.2G$ESC[0m"
	need "99.2 % of 1280M: 1.25 cut to 1.2, the use one step below, 1.1/1.2G" row_has 5009 "$ESC[31m 1.1/1.2G$ESC[0m"
	need "100.5 % of 15600M: 15.3/15.2G, bold red" row_has 5010 "$ESC[1;31m 15.3/15.2G$ESC[0m"
	head=$(section queue | head -n 1)
	d=$(mem_fixture jobmem-forms sstat '@defaults TRESUsageInTot=cpu=00:01:00,energy=0,fs/disk=0,mem=1,pages=0,vmem=0\nJobID=5001.batch\nJobID=5002.batch\nJobID=5003.batch\nJobID=5004.batch\nJobID=5005.batch\nJobID=5006.batch\nJobID=5007.batch\nJobID=5008.batch\nJobID=5009.batch\nJobID=5010.batch')
	mem_run "$d" -- --color
	need "other readings, the same allocations: rc 0, the same column widths" eval '
		rc_is 0 && [ "$(section queue | head -n 1)" = "$head" ] && row_has 5004 "$ESC[32m   0/16G$ESC[0m" && row_has 5007 "$ESC[32m  0.0/15.2G$ESC[0m"'
	mem_run jobmem-forms SQ_WIDTH=70 -- --color
	need "70 columns in a pipe: still the decimal form, NODE/REASON shaved" eval 'rc_is 0 && row_has 5007 "$ESC[31m 15.0/15.2G$ESC[0m" && section queue | head -n 1 | grep -q "NODE/REASO$"'
	mem_run jobmem-forms SQ_WIDTH=70 COLUMNS=70 LINES=30 -- --color
	need "70 columns on a screen: whole numbers, cut, no guard: 15/15G at 98.5, 99.9 and 100.5 %" eval '
		rc_is 0 && row_has 5007 "$ESC[31m  15/15G$ESC[0m" && row_has 5008 "$ESC[31m  15/15G$ESC[0m" && row_has 5010 "$ESC[1;31m  15/15G$ESC[0m" && ! rows queue | grep -q "…"'
	need "70 columns on a screen: every use whole, also of a whole allocation (15/16G) and under one (0/0.9G); below 10 the allocation keeps its decimal (1/1.2G)" eval '
		row_has 5004 "$ESC[31m  15/16G$ESC[0m" && row_has 5005 "$ESC[1;31m  16/16G$ESC[0m" && row_has 5002 "$ESC[32m   0/0.9G$ESC[0m" &&
		row_has 5009 "$ESC[31m   1/1.2G$ESC[0m" && row_has 5006 "$ESC[32m   0/1.5G$ESC[0m" && row_has 5003 "$ESC[32m  1/2T$ESC[0m" && row_has 5001 "$ESC[32m  200/512M$ESC[0m"'
	mem_run jobmem-forms SQ_WIDTH=70 COLUMNS=70 LINES=30 -- --no-color
	need "70 columns on a screen without colour: whole numbers as well" eval 'rc_is 0 && [ "$(mem_of 5007)" = 15/15G ]'
	mem_run jobmem-forms SQ_WIDTH=64 COLUMNS=64 LINES=30 -- --color
	need "64 columns on a screen with colour, whole numbers still too wide: form a, the allocation in the whole form of the unit rule" eval '
		rc_is 0 && row_has 5006 "$ESC[32m1.5G$ESC[0m" && row_has 5001 "$ESC[32m512M$ESC[0m" && row_has 5004 "$ESC[31m16G$ESC[0m" && row_has 5007 "$ESC[31m15G$ESC[0m"'
	mem_run jobmem-forms SQ_WIDTH=64 COLUMNS=64 LINES=30 -- --no-color
	need "64 columns on a screen without colour: whole numbers, others shaved" eval 'rc_is 0 && [ "$(mem_of 5007)" = 15/15G ] && rows queue | grep -q "…"'
	mem_run jobmem SQ_WIDTH=80 -- --color --full
	need "80 columns in a pipe, colour on: b, and the b cell whole while NODE/REASON is cut" eval '
		rc_is 0 && row_has 11895 "$ESC[33m   83/100G$ESC[0m" && row_has 11903 "$ESC[32m  7.7/15.2G$ESC[0m" && rows queue | grep -q "…$"'
	mem_run jobmem SQ_WIDTH=80 COLUMNS=80 LINES=30 -- --no-color --full
	need "80 columns on a screen, colour off: b in whole numbers" eval 'rc_is 0 && [ "$(mem_of 11895)" = 83/100G ] && [ "$(mem_of 11903)" = 7/15G ] && [ "$(mem_of 11902)" = 7/64G ] && [ "$(mem_of 11908)" = "?/4G" ]'
	PTY=1 PTY_ROWS=30 PTY_COLS=80 mem_run jobmem TERM=xterm-256color -SQ_WIDTH -SQ_HEIGHT -- --full
	need "an 80-column terminal: rc 0, coloured, form a" eval 'rc_is 0 && [ "$(escapes)" -gt 0 ] && [ "$(mem_of 11895)" = 100G ] && [ "$(mem_of 11903)" = 15G ]'
}
c_jobmem_compact_arrays() {
	T_TITLE="COMPACT keeps own rows at risk (>= 90 %, then >= 70 %) in squeue's order; a folded own array sums its readings, coloured by its fullest task"
	mem_run jobmem SQSTUB_UID=4242 SQ_WIDTH=100 SQ_HEIGHT=16 -- --color --compact
	need "COMPACT 100x16 as nobody: kraken2, megahit, busco hidden, as the longest-running stay" eval '
		rc_is 0 && [ "$(row_first_fields queue | grep -v "^…" | paste -sd" ")" = "11912 11880 11889 11895 11906" ]'
	mem_run jobmem SQ_WIDTH=100 SQ_HEIGHT=16 -- --color --compact
	need "as fsill: kraken2 97 %, megahit 104 %, busco 92 %, then flye 83 %, in squeue order" eval '
		rc_is 0 && [ "$(row_first_fields queue | grep -v "^…" | paste -sd" ")" = "11912 11895 11898 11904 11905" ]'
	mem_run jobmem-arrays -- --color
	need "rc 0, stderr empty, each task asked once" eval 'rc_is 0 && err_empty && argv_has sstat -j 6001,6002,6000,6101,6100,6201,6200'
	need "the readings of 6000's tasks summed (1G + 3.8G of 4G + 4G), red for its 95 % task" row_has "6000_[0-2]" "$ESC[31m4.8/8G$ESC[0m"
	need "6100 without a reading: a dim ? before both tasks' allocations" row_has "6100_[0-1]" "$ESC[2m?$ESC[0m/8G"
	need "6200, a task failed and none read: a red !" row_has "6200_[0-1]" "$ESC[31m!$ESC[0m/8G"
	mem_run jobmem-arrays -- --color -x
	need "-x: each task its own reading" eval 'rc_is 0 && row_has 6000_0 "$ESC[32m  1/4G$ESC[0m" && row_has 6000_1 "$ESC[31m3.8/4G$ESC[0m" && row_has 6000_2 "$ESC[2m?$ESC[0m/4G"'
}

# ============================================================================
# every job's total memory in MEM (MEMALLOC-v3)
# ============================================================================
# The memalloc fixtures are a realistic bioserver queue (memalloc/squeue says
# who asked for what, memalloc/squeue-tres what the mirror call answers);
# mem_run runs sq as fsill, SQSTUB_UID=4242 as nobody of the queue.  Its
# pinned screens are the ones Franz accepted on 2026-10-20, with folded arrays
# as the sum he chose: S0 and S1 (fsill, nobody: FULL at 110 in a pipe), S2
# (the mirror call failing), S3 (whole for all: nobody at 80 on a screen) and
# S4 (own form a in the unit rule: fsill at 80 on a screen).  S3's and S4's
# JOBID cells are DISPLAY-v4 F2's (11920_… ×16 where they read 11920_[4-1…),
# re-pinned from its build, which renders them as the design's prototype does.
# mirror_at: which squeue call of the run the mirror call was, for env_of
mirror_at() { gawk -F'\t' '$1 == "CALL" && $2 == "squeue" { c++ } $1 == "CALL" && $2 == "squeue" && /tres-alloc/ && !/StateCompact/ { print c; exit }' "$LOG"; }
# The caller's own job ids reach sstat in lists of at most 64 KiB (R2): an id
# reads "failed" only when its own list's call failed, and every call shares
# one budget, min(SQ_TIMEOUT, 2) s from the first, the lists it does not reach
# reading "failed" as a call that timed out.  memalloc as fsill with 9 000 more
# own running jobs ahead of fsill's: two lists, flye, salmon and multiqc in the
# second
jobmem_lists_fx() {   # jobmem_lists_fx NAME SSTAT-STEP-1: the fixture's directory
	local d=$T_DIR/fx-$1 f
	mkdir -p "$d"
	for f in "$fixtures"/memalloc/*; do [ -f "$f" ] && sed "s|^@include \.\./|@include $fixtures/|" "$f" > "$d/${f##*/}"; done
	gawk '{ print } /^@defaults / { for (i = 1; i <= 9000; i++) printf "JobID=%d; tres_alloc=cpu=1,mem=1G,node=1,billing=1\n", 2000000 + i }' \
		"$fixtures/memalloc/squeue-alloc" > "$d/squeue-alloc"
	{ printf '@step 1\n%s\n@step 2\n' "$2"; grep -v '^#' "$fixtures/memalloc/sstat"; } > "$d/sstat"
	printf '%s' "$d"
}
jobmem_lists_mem() { rows queue | gawk '$1 == "11895" || $1 == "11903" || $1 == "11908" { print $(NF - 1) }' | paste -sd' '; }   # flye's, salmon's, multiqc's MEM
c_jobmem_lists() {
	T_TITLE="sstat in lists: the first of two calls failing fails only its own ids (flye, salmon, multiqc in the second read 83/100G 7.7/15.2G ?/4G); the first hanging takes the whole budget (SQ_TIMEOUT=3: 2 s) and the second list is not asked, its ids failed"
	local d start
	d=$(jobmem_lists_fx fail '@exit 1')
	sq_run "$d" SQSTUB_UID=1041 SQ_WIDTH=110 SQ_HEIGHT=30 -- --full --no-color
	need "the first call failing: two sstat calls, flye, salmon, multiqc '83/100G 7.7/15.2G ?/4G' (got: $(jobmem_lists_mem))" eval '
		rc_is 0 && err_empty && [ "$(calls sstat)" = 2 ] && [ "$(jobmem_lists_mem)" = "83/100G 7.7/15.2G ?/4G" ]'
	d=$(jobmem_lists_fx hang '@hang 30')
	start=$(date +%s%N)
	sq_run "$d" SQSTUB_UID=1041 SQ_TIMEOUT=3 SQ_WIDTH=110 SQ_HEIGHT=30 -- --full --no-color
	need "the first call hanging: one sstat call, the second list not asked, its ids failed: '!/100G !/15.2G !/4G' (got: $(jobmem_lists_mem))" eval '
		rc_is 0 && err_empty && [ "$(calls sstat)" = 1 ] && [ "$(jobmem_lists_mem)" = "!/100G !/15.2G !/4G" ]'
	need "... sq ends within 6 s of its start (the budget, not 2 s a list)" eval '[ $(( ($(date +%s%N) - start) / 1000000 )) -lt 6000 ]'
}
c_memalloc_screens() {
	T_TITLE="the accepted MEMALLOC screens byte for byte, clock aside: totals as fsill and as nobody in a pipe, a failed call marked, whole numbers for all and own form a in the unit rule on an 80-column screen"
	local fx=$fixtures/memalloc
	mem_run memalloc SQ_WIDTH=110 SQ_HEIGHT=30 -- --color --full
	need "S0/S1 as fsill, FULL at 110 in a pipe: rc 0, stderr empty, the accepted screen" eval '
		rc_is 0 && err_empty && cmp -s <(without_clock "$fx/fsill__full-w110-h30.ansi") <(without_clock "$OUT")'
	need "... busco (per CPU, -c16) 121.8G, not 7800M; --mem=0 pending 1006.8G, not 0; hal's ×4 60.9G; own flye still 83/100G" eval '
		[ "$(mem_of 11890)" = 121.8G ] && [ "$(mem_of 11948)" = 1006.8G ] && [ "$(mem_of "11920_[0-3]")" = 60.9G ] && [ "$(mem_of 11895)" = 83/100G ]'
	mem_run memalloc SQSTUB_UID=4242 SQ_WIDTH=110 SQ_HEIGHT=30 -- --color --full
	need "S0/S1 as nobody, FULL at 110 in a pipe: rc 0, stderr empty, the accepted screen; fsill's rows are totals too" eval '
		rc_is 0 && err_empty && cmp -s <(without_clock "$fx/nobody__full-w110-h30.ansi") <(without_clock "$OUT") &&
		[ "$(mem_of 11903)" = 15.2G ] && [ "$(mem_of "11930_[0-2]")" = 12G ]'
	mem_run memalloc-tresfail SQ_WIDTH=110 SQ_HEIGHT=30 -- --color --full
	need "S2, the mirror call failing, as fsill at 110: rc 0, stderr empty, the accepted screen" eval '
		rc_is 0 && err_empty && cmp -s <(without_clock "$fixtures/memalloc-tresfail/fsill__full-w110-h30.ansi") <(without_clock "$OUT")'
	mem_run memalloc SQSTUB_UID=4242 SQ_WIDTH=80 SQ_HEIGHT=30 COLUMNS=80 LINES=30 -- --color --full
	need "S3 as nobody at 80 on a screen: rc 0, stderr empty, the accepted screen, every total whole" eval '
		rc_is 0 && err_empty && cmp -s <(without_clock "$fx/nobody__full-w80-h30.ansi") <(without_clock "$OUT") &&
		[ "$(mem_of 11948)" = 1006G ] && [ "$(mem_of 11890)" = 121G ] && [ "$(mem_of 11926)" = 0.9G ]'
	# no screen, so no whole form: the other columns give way, MEM never
	mem_run memalloc SQSTUB_UID=4242 SQ_WIDTH=60 -- --full --no-recent
	# WHOLE (R-H4): FULL cuts no state and no duration either; the line wraps
	need "nobody at 60 in a pipe: rc 0, every MEM cell whole and decimal (1006.8G, not 1006.…), others shaved, STATE whole" eval '
		rc_is 0 && [ "$(mem_of 11948) $(mem_of 11890) $(mem_of 11926)" = "1006.8G 121.8G 0.9G" ] &&
		! rows queue | gawk "{ print \$(NF-1) }" | grep -q "…" && rows queue | grep -q "…" && ! rows queue | grep -q "PEND…"'
	mem_run memalloc SQ_WIDTH=80 SQ_HEIGHT=30 COLUMNS=80 LINES=30 -- --color --full
	need "S4 as fsill at 80 on a screen: rc 0, stderr empty, the accepted screen; own form a in the unit rule (salmon 15G, fastqc 8G, multiqc ?4G) beside whole totals" eval '
		rc_is 0 && err_empty && cmp -s <(without_clock "$fx/fsill__full-w80-h30.ansi") <(without_clock "$OUT") &&
		row_has 11903 "$ESC[32m15G$ESC[0m" && row_has "11930_[…]" "$ESC[31m8G$ESC[0m" && row_has 11908 "$ESC[2m?$ESC[0m4G" && [ "$(mem_of 11909)" = 15G ]'
}
# MEM under -M too (the feature off, MEM is %m): a screen narrower than
# every column at its floor keeps MEM whole (WHOLE R-L5; it was cut to 5),
# the text columns at 5, and FULL wraps
c_memalloc_floor_M() {
	T_TITLE="-M at 21 and 30 in a pipe: the text columns at their floor of 5, MEM whole (1023.9G; WHOLE R-L5: never cut), FULL wrapping the rest"
	local d q w
	q=$(sed 's/^\(i=11890;.*\) m=7800M;/\1 m=1048575M;/' "$fixtures/memalloc/squeue" | sed "s|^@include \.\./|@include $fixtures/|")
	d=$(mem_fixture memalloc sinfo "@include $fixtures/_common/sinfo-two-idle")
	printf '%s\n' "$q" > "$d/squeue"
	for w in 21 30; do
		mem_run "$d" SQ_WIDTH=$w -- --full --no-recent -M bioinf
		need "-M at $w: rc 0, no mirror call, the text at its floor, busco's MEM whole" eval '
			rc_is 0 && [ "$(calls mirror)" -eq 0 ] && [ "$(section queue | head -n 1)" = "  JOBID   NAME  USER  STATE   TIME       LEFT       CPU MEM     NODE/" ] && [ "$(mem_of 11890)" = "1023.9G" ]'
	done
}
c_memalloc_narrow() {
	T_TITLE="MEM is never cut (WHOLE R-L5; MEMALLOC cut it last, down to 5): whole while any other column can give, also under -M where it is the widest, so COMPACT keeps its height on a screen just wide enough; %m in the unit rule, decimal or whole, own ?%m and !%m cells too"
	local d1 d2 q
	d1=$(mem_fixture memalloc-tresfail sinfo "@include $fixtures/_common/sinfo-two-idle")
	# busco's %m as if it were per node: 124800M, wider than any other MEM cell
	q=$(sed 's/^\(i=11890;.*\) m=7800M;/\1 m=124800M;/' "$fixtures/memalloc/squeue" | sed "s|^@include \.\./|@include $fixtures/|")
	d2=$(mem_fixture memalloc sinfo "@include $fixtures/_common/sinfo-two-idle")
	printf '%s\n' "$q" > "$d2/squeue"
	mem_run "$d1" SQ_WIDTH=53 SQ_HEIGHT=16 COLUMNS=53 LINES=16 -- --color --compact
	need "the mirror call failing, COMPACT 53x16 on a screen: rc 0, at most 16 lines, none wider than 53, MEM whole where shown (WHOLE R-L5)" eval '
		rc_is 0 && [ "$(wc -l < "$OUT")" -le 16 ] && [ "$(width)" -le 53 ] && ! plain | grep -qE "[0-9]…|!…"'
	mem_run "$d2" SQ_WIDTH=53 SQ_HEIGHT=16 COLUMNS=53 LINES=16 -- --color --compact -M bioinf
	need "-M (no mirror call), COMPACT 53x16 on a screen: rc 0, at most 16 lines, none wider than 53" eval '
		rc_is 0 && [ "$(calls mirror)" -eq 0 ] && [ "$(wc -l < "$OUT")" -le 16 ] && [ "$(width)" -le 53 ]'
	# MEMALLOC off: %m keeps its meaning but takes the unit rule; 0 and what is
	# no size (cactus' 12345, no suffix) as squeue printed them
	q=$(printf '%s\n' "$q" | sed 's/^\(i=11947;.*\) m=7800M;/\1 m=12345;/')
	printf '%s\n' "$q" > "$d2/squeue"
	mem_run "$d2" SQ_WIDTH=110 -- --full --no-recent -M bioinf
	need "-M in a pipe: rc 0, %m in the unit rule: 124800M 121.8G, 7800M 7.6G, 3200M 3.1G, 1000M 0.9G, 100G 100G; 0 and 12345 as printed" eval '
		rc_is 0 && [ "$(mem_of 11890) $(mem_of 11945) $(mem_of 11911) $(mem_of 11926) $(mem_of 11880) $(mem_of 11948) $(mem_of 11947)" = "121.8G 7.6G 3.1G 0.9G 100G 0 12345" ]'
	mem_run "$d2" SQ_WIDTH=72 SQ_HEIGHT=30 COLUMNS=72 LINES=30 -- --full --no-recent -M bioinf
	need "-M on a 72-column screen: rc 0, the whole form for %m too: 121G, 7.6G and 0.9G keep their decimal" eval '
		rc_is 0 && [ "$(mem_of 11890) $(mem_of 11945) $(mem_of 11926)" = "121G 7.6G 0.9G" ]'
	mem_run "$d2" SQ_WIDTH=60 -- --full --no-recent -M bioinf
	need "-M at 60 in a pipe: rc 0, busco MEM whole (124800M in the unit rule) while other columns are cut" eval '
		rc_is 0 && [ "$(mem_of 11890)" = 121.8G ] && ! rows queue | gawk "{ print \$(NF-1) }" | grep -q "…" && rows queue | grep -q "…"'
	# busco at 1048575M, 1023.9G: MEM the widest column, which under -M would
	# be shaved first if MEM competed like any other
	q=$(printf '%s\n' "$q" | sed 's/^\(i=11890;.*\) m=124800M;/\1 m=1048575M;/')
	printf '%s\n' "$q" > "$d2/squeue"
	for w in 58 62; do
		mem_run "$d2" SQ_WIDTH=$w -- --full --no-recent -M bioinf
		need "-M at $w in a pipe, MEM the widest column: rc 0, busco 1023.9G whole, others cut" eval '
			rc_is 0 && [ "$(mem_of 11890)" = 1023.9G ] && rows queue | grep -q "…"'
	done
	# own b cells without colour in a pipe: no whole form, no form a.  WHOLE
	# (R-L5, R-H4): MEM is never cut, nor a state or a duration; the text
	# columns go to 5 and FULL wraps the rest
	d1=$(mem_fixture jobmem sinfo "@include $fixtures/_common/sinfo-two-idle")
	for w in 55 21; do
		mem_run "$d1" SQ_WIDTH=$w -- --full --no-recent --no-color
		need "own b cells, no colour, $w in a pipe: rc 0, the text columns at 5, STATE, the durations and MEM whole (7.7/15.2G)" eval '
			rc_is 0 && [ "$(section queue | head -n 1)" = "  JOBID NAME  USER  STATE   TIME       LEFT       CPU MEM         NODE/" ] &&
			[ "$(mem_of 11903)" = "7.7/15.2G" ]'
	done
	# own cells with no allocation known: the mark before %m, in the unit rule
	# and in the whole form like every other MEM cell.  gone (4008) is out of
	# the allocation call; at 124800M its %m reads 121.8G, whole 121G
	d1=$(mem_fixture jobmem-outcomes squeue "$(sed 's/^\(i=4008; .*M=53:00\)$/\1; m=124800M/' "$fixtures/jobmem-outcomes/squeue" | sed "s|^@include \.\./|@include $fixtures/|")")
	mem_run "$d1" -- --color --full --no-recent
	need "an own job gone from the allocation call: rc 0, a dim ? before its %m in the unit rule, 121.8G" row_has 4008 "$ESC[2m?$ESC[0m121.8G "
	mem_run "$d1" SQ_WIDTH=70 SQ_HEIGHT=40 COLUMNS=70 LINES=40 -- --no-color --full --no-recent
	need "... on a 70-column screen without colour: rc 0, the whole form, ?121G" eval 'rc_is 0 && [ "$(mem_of 4008)" = "?121G" ] && [ "$(mem_of 4001)" = 1/4G ]'
	printf '%b\n' '@stderr squeue: error: Socket timed out on send/recv operation\n@exit 1' > "$d1/squeue-alloc"
	mem_run "$d1" -- --color --full --no-recent
	need "the allocation call failing: rc 0, a red ! before each own %m in the unit rule, 121.8G and 4G" eval '
		rc_is 0 && row_has 4008 "$ESC[31m!$ESC[0m121.8G " && row_has 4001 "$ESC[31m!$ESC[0m4G "'
	mem_run "$d1" SQ_WIDTH=70 SQ_HEIGHT=40 COLUMNS=70 LINES=40 -- --no-color --full --no-recent
	need "... on a 70-column screen without colour: rc 0, the whole form, !121G" eval 'rc_is 0 && [ "$(mem_of 4008)" = "!121G" ]'
}
c_memalloc_call() {
	T_TITLE="the mirror call: the queue call's arguments and env pins without its sort, framed by the queue nonce; none with MEM hidden, a cluster selection (SQUEUE_FEDERATION, SQUEUE_SIB, SQUEUE_SIBLING too, empty or not, and no JOBMEM call then), a queue call failed (also after whole records), cut off or unreadable, or no row; nor JOBMEM's calls on a queue cut off"
	local main mirror at n args f d how
	mem_run memalloc SQ_WIDTH=110 -- --color -p main -n blastp,prokka --all -S i
	main=$(gawk -F'\t' '$1 == "CALL" && $2 == "squeue" { print $3; exit }' "$LOG")
	mirror=$(gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && /tres-alloc/ && !/StateCompact/ { print $3 }' "$LOG")
	at=$(mirror_at); n=$(env_of squeue 1 SQ_NONCE)
	need "rc 0, one mirror call, after the queue call and the allocation call" eval 'rc_is 0 && [ "$(calls mirror)" -eq 1 ] && [ "$at" = 3 ]'
	need "its argv: the queue call's without -S t,i, the filters (and their own -S) in the queue call's spelling" eval '
		[ "$main" = "$(printf "%q " -h -S t,i -p main -n blastp,prokka -a -S i)" ] && [ "$mirror" = "$(printf "%q " -h -p main -n blastp,prokka -a -S i)" ]'
	need "its env: the queue call's pins, SLURM_TIME_FORMAT=standard and SLURM_BITSTR_LEN=0" eval '
		[ "$(env_of squeue "$at" SLURM_TIME_FORMAT)" = standard ] && [ "$(env_of squeue 1 SLURM_TIME_FORMAT)" = standard ] &&
		[ "$(env_of squeue "$at" SLURM_BITSTR_LEN)" = 0 ] && [ "$(env_of squeue 1 SLURM_BITSTR_LEN)" = 0 ]'
	need "its format in SQUEUE_FORMAT2, JobID and tres-alloc framed by the queue nonce, which stays off every command line" eval '
		[ "$(env_of squeue "$at" SQUEUE_FORMAT2)" = "JobID:$n,tres-alloc:$n" ] && [ "$(env_of squeue "$at" SQUEUE_FORMAT)" = "(unset)" ] &&
		! grep "^CALL" "$LOG" | cut -f3 | grep -qF "$n"'
	# no call: MEM %m, in the unit rule (a cluster selection), or not shown at all
	for args in "-M bioinf" "--clusters=bioinf" "--federation" "--sibling"; do
		mem_run memalloc SQ_WIDTH=110 -- --color $args
		need "$args: rc 0, no mirror call, busco and hal's ×4 their %m (7800M per CPU), in the unit rule: 7.6G" eval '
			rc_is 0 && [ "$(calls mirror)" -eq 0 ] && [ "$(mem_of 11890)" = 7.6G ] && [ "$(mem_of "11920_[0-3]")" = 7.6G ]'
	done
	mem_run memalloc SQ_WIDTH=110 SLURM_CLUSTERS=bioinf -- --color
	need "SLURM_CLUSTERS=bioinf: rc 0, no mirror call, busco its %m in the unit rule, sacct -M bioinf" eval '
		rc_is 0 && [ "$(calls mirror)" -eq 0 ] && [ "$(mem_of 11890)" = 7.6G ] && argv_has sacct -M bioinf'
	mem_run memalloc SQ_WIDTH=110 SLURM_CLUSTERS= -- --color
	need "SLURM_CLUSTERS='': refused (OPTS-v4 D10), rc 2, no call" eval 'rc_is 2 && out_empty && no_slurm_call'
	# squeue's --federation and --sibling as settings, which squeue reads when
	# set at all: as fsill, whose fastqc runs, so JOBMEM's calls would come too
	mem_run memalloc SQ_WIDTH=110 -- --color
	need "none of them, as fsill: rc 0, the allocation call, sstat and the mirror call" eval '
		rc_is 0 && [ "$(calls alloc)" -eq 1 ] && [ "$(calls sstat)" -eq 1 ] && [ "$(calls mirror)" -eq 1 ]'
	for f in SQUEUE_FEDERATION=1 SQUEUE_FEDERATION= SQUEUE_SIB=1 SQUEUE_SIB= SQUEUE_SIBLING=1 SQUEUE_SIBLING=; do
		mem_run memalloc SQ_WIDTH=110 "$f" -- --color
		need "$f: rc 0, no allocation call, no sstat, no mirror call, busco its %m in the unit rule" eval '
			rc_is 0 && [ "$(calls alloc)" -eq 0 ] && [ "$(calls sstat)" -eq 0 ] && [ "$(calls mirror)" -eq 0 ] && [ "$(mem_of 11890)" = 7.6G ]'
	done
	mem_run memalloc SQ_WIDTH=110 -- --color -o i,j,u,T,M,L,C,R
	need "MEM not shown (-o without m): rc 0, no mirror call" eval 'rc_is 0 && [ "$(calls mirror)" -eq 0 ] && [ "$(calls queue)" -eq 1 ]'
	mem_run memalloc SQ_WIDTH=110 -- --color -o i,u,m
	need "-o i,u,m: rc 0, one mirror call, busco 121.8G" eval 'rc_is 0 && [ "$(calls mirror)" -eq 1 ] && rows queue | grep -qE "^ +11890 +koch +121.8G$"'
	mem_run memalloc SQ_WIDTH=110 -- --color -n --federation
	need "-n --federation (a job name, no cluster): rc 0, one mirror call, totals" eval 'rc_is 0 && [ "$(calls mirror)" -eq 1 ] && [ "$(mem_of 11890)" = 121.8G ]'
	for f in squeue-fails squeue-garbage empty; do
		mem_run "$f" -- --color
		need "$f (the queue call failed, unreadable, or no row): rc 0, no mirror call" eval 'rc_is 0 && [ "$(calls queue)" -eq 1 ] && [ "$(calls mirror)" -eq 0 ]'
	done
	# a queue stream that does not read whole: the table gives way to a
	# caption, so neither JOBMEM's calls nor the mirror call are made
	mem_run queue-cut -- --color
	need "queue-cut, its stream ending inside a record: rc 0, the caption, no mirror call" eval '
		rc_is 0 && has "queue output incomplete" && [ "$(calls queue)" -eq 1 ] && [ "$(calls mirror)" -eq 0 ]'
	for how in "a garbage line" "a record cut off"; do
		case $how in
			garbage*) d=$(mem_fixture jobmem squeue "@include $fixtures/jobmem/squeue\n@raw not a record") ;;
			*)        d=$(mem_fixture jobmem squeue "@include $fixtures/jobmem/squeue\n@cut\ni=11999; A=11999; j=extra") ;;
		esac
		mem_run "$d" -- --color
		need "fsill's queue, whole records, then $how: rc 0, the caption, no allocation call, no sstat, no mirror call" eval '
			rc_is 0 && has "queue output incomplete" && [ "$(calls queue)" -eq 1 ] && [ "$(calls alloc)" -eq 0 ] && [ "$(calls sstat)" -eq 0 ] && [ "$(calls mirror)" -eq 0 ]'
	done
	# whole records, but none with a job id the table takes (a forged one, a
	# bracket counting no task): "no readable rows", and no call for them
	d=$(mem_fixture jobmem squeue "@include $fixtures/_common/squeue-defaults\ni=x11895; A=11895; U=1041; u=fsill; j=flye\ni=11880_[3-1]; A=11880; U=1041; u=fsill; j=badrange")
	mem_run "$d" -- --color
	need "own running records whose ids all fail the anchor: rc 0, no readable rows, no allocation call, no sstat, no mirror call" eval '
		rc_is 0 && has "no readable rows" && [ "$(calls queue)" -eq 1 ] && [ "$(calls alloc)" -eq 0 ] && [ "$(calls sstat)" -eq 0 ] && [ "$(calls mirror)" -eq 0 ]'
	# a garbage line between records costs the record it runs into, not the table
	d=$(mem_fixture jobmem squeue "@include $fixtures/jobmem/squeue\n@raw not a record\ni=11999; A=11999; j=extra")
	mem_run "$d" -- --color
	need "a garbage line, then a record: rc 0, that record skipped, the table and every call as ever" eval '
		rc_is 0 && has "1 unreadable queue row skipped" && [ "$(mem_of 11889)" = 32G ] && [ "$(calls alloc)" -eq 1 ] && [ "$(calls sstat)" -eq 1 ] && [ "$(calls mirror)" -eq 1 ]'
	# a queue call that fails after printing whole records: they are no answer
	for how in "exit 1" "hang"; do
		case $how in
			exit*) d=$(mem_fixture memalloc squeue "@include $fixtures/memalloc/squeue\n@stderr squeue: error: Socket timed out on send/recv operation\n@exit 1") ;;
			hang)  d=$(mem_fixture memalloc squeue "@include $fixtures/memalloc/squeue\n@hang 8") ;;
		esac
		mem_run "$d" -- --color
		need "the queue call printing whole records, then $how: rc 0, the banner, no allocation call, no mirror call" \
			eval 'rc_is 0 && has "slurm unreachable" && [ "$(calls queue)" -eq 1 ] && [ "$(calls alloc)" -eq 0 ] && [ "$(calls mirror)" -eq 0 ]'
	done
}
c_memalloc_fail() {
	T_TITLE="the mirror call failing (exit 1, a timeout, unreadable, its last record cut off): a red ! before %m (in the unit rule) on every cell it would fill, own cells as JOBMEM draws them; no answer for a job, no mem= or N/A: %m, silently; a repeated id: the first stands"
	local how d id cell
	for how in "exit 1" "timeout" "unreadable" "cut off"; do
		case $how in
			exit*)      d=$fixtures/memalloc-tresfail ;;
			timeout)    d=$(mem_fixture memalloc squeue-tres '@hang 8') ;;
			unreadable) d=$(mem_fixture memalloc squeue-tres "@include $fixtures/memalloc/squeue-tres\n@raw not a record") ;;
			# the last record whole but for its closing separator and newline
			cut*)       d=$(mem_fixture memalloc squeue-tres "@include $fixtures/memalloc/squeue-tres\n@cut\nJobID=11999; tres_alloc=cpu=1,mem=1G") ;;
		esac
		mem_run "$d" SQ_WIDTH=110 -- --color --full
		need "mirror call $how: rc 0, stderr empty, no banner, one mirror call" eval 'rc_is 0 && err_empty && lacks unreachable && [ "$(calls mirror)" -eq 1 ]'
		for cell in "11912 48G" "11920_[4-19%4] 7.6G" "11948 0" "11880 100G" "11890 7.6G" "11920_[0-3] 7.6G" "11926 0.9G"; do
			id=${cell% *}
			need "mirror call $how: $id a red ! before its %m in the unit rule, ${cell#* }" row_has "$id" "$ESC[31m!$ESC[0m${cell#* } "
		done
		need "mirror call $how: own running rows as JOBMEM draws them" eval '
			row_has 11895 "$ESC[33m   83/100G$ESC[0m" && row_has 11908 "$ESC[2m?$ESC[0m/4G" && row_has "11930_[0-2]" "$ESC[31m4.8/8G$ESC[0m"'
	done
	mem_run memalloc-tresfail SQ_WIDTH=110 -- --no-color --full
	need "colour off: rc 0, no escapes, a plain ! before %m in the unit rule, 0 as printed" eval '
		rc_is 0 && [ "$(escapes)" -eq 0 ] && [ "$(mem_of 11890) $(mem_of 11948) $(mem_of 11912) $(mem_of 11895)" = "!7.6G !0 !48G 83/100G" ]'
	# a race (busco not in the answer), a running job without mem=, a pending
	# one with N/A, and alphafold a second time (-P), smaller: the first stands
	d=$(mem_fixture memalloc squeue-tres "$(grep -v '^JobID=11890;' "$fixtures/memalloc/squeue-tres" |
		sed -e 's/^JobID=11909;.*/JobID=11909; tres_alloc=cpu=2,node=1,billing=2/' -e 's|^JobID=11945;.*|JobID=11945; tres_alloc=N/A|')
JobID=11880; tres_alloc=cpu=1,mem=1G,node=1,billing=1")
	mem_run "$d" SQ_WIDTH=110 -- --color --full
	need "no answer for busco, none with mem= for 11909, N/A for 11945: rc 0, stderr empty, %m in the unit rule, uncoloured" eval '
		rc_is 0 && err_empty && row_has 11890 "  7.6G fb2" && row_has 11909 "  7.6G fb2" && row_has 11945 "  7.6G (Priority)"'
	need "... and the others totals, alphafold the first of its two records" eval '
		[ "$(mem_of 11880)" = 100G ] && [ "$(mem_of 11926)" = 0.9G ] && [ "$(mem_of 11947)" = 7.6G ]'
}
c_memalloc_fold() {
	T_TITLE="folded rows show the sum: a folded group of its tasks, a pending bracket ×N its per-task request times N (a throttle does not reduce it), the same with and without -r; a task without a total leaves the group %m; own groups keep used/alloc"
	local d cells
	mem_run memalloc SQSTUB_UID=4242 SQ_WIDTH=110 -- --color --full
	need "nobody: rc 0, hal's running ×4 60.9G (4 x 15600M), the pending ×16 bracket 121.8G (16 x 7800M, not 4), fsill's fastqc ×3 12G" eval '
		rc_is 0 && [ "$(mem_of "11920_[0-3]")" = 60.9G ] && [ "$(mem_of "11920_[4-19%4]")" = 121.8G ] && [ "$(mem_of "11930_[0-2]")" = 12G ]'
	cells=$(rows queue | gawk '{ print $(NF-1) }' | paste -sd' ')
	mem_run memalloc-r SQSTUB_UID=4242 SQ_WIDTH=110 -- --color --full
	need "nobody, the queue as squeue -r prints it: rc 0, the 16 pending tasks fold to one row of 121.8G, every MEM cell as without -r" eval '
		rc_is 0 && [ "$(mem_of "11920_[4-19]")" = 121.8G ] && [ "$(rows queue | gawk "{ print \$(NF-1) }" | paste -sd" ")" = "$cells" ]'
	mem_run memalloc SQ_WIDTH=110 -- --color --full
	cells=$(rows queue | gawk '{ print $(NF-1) }' | paste -sd' ')
	mem_run memalloc-r SQ_WIDTH=110 -- --color --full
	need "fsill, with and without -r: rc 0, every MEM cell the same, own fastqc still 4.8/8G" eval '
		rc_is 0 && [ "$(rows queue | gawk "{ print \$(NF-1) }" | paste -sd" ")" = "$cells" ] && row_has "11930_[0-2]" "$ESC[31m4.8/8G$ESC[0m"'
	mem_run memalloc-r SQSTUB_UID=4242 SQ_WIDTH=110 -- --color --full -x
	need "-x: each task its own total, a pending one 7.6G, a running one 15.2G" eval '
		rc_is 0 && [ "$(mem_of 11920_4) $(mem_of 11920_19) $(mem_of 11920_0) $(mem_of 11930_1)" = "7.6G 7.6G 15.2G 4G" ]'
	d=$(mem_fixture memalloc squeue-tres "$(grep -v '^JobID=11942;' "$fixtures/memalloc/squeue-tres")")
	mem_run "$d" SQSTUB_UID=4242 SQ_WIDTH=110 -- --color --full
	need "one of hal's running tasks without a total: rc 0, its group %m in the unit rule, uncoloured; the bracket still 121.8G" eval '
		rc_is 0 && row_has "11920_[0-3]" "  7.6G fb2" && [ "$(mem_of "11920_[4-19%4]")" = 121.8G ]'
}

# ============================================================================
# subcommands: where one stands, and the words sq cannot place (SUBCMD-v3)
# ============================================================================
# Franz (2026-10-20): "the subcommand is a good idea"; an alias with a value
# option before a subcommand is an error: "OK".  D1-D6 of sqlog-v3.md.
sub_refused() {   # sub_refused TEXT SQ-ARGS...: a usage error with exactly TEXT on stderr
	local text=$1; shift
	sq_run empty -- "$@"
	need "sq $*: rc 2, nothing on stdout, no Slurm call" eval 'rc_is 2 && out_empty && no_slurm_call'
	need "sq $*: says '$text'" eval '[ "$(cat "$ERR")" = "$text" ]'
}
c_sub_dispatch() {   # D1, D2, D4
	T_TITLE="a subcommand stands after valueless options only (an alias's --me too, one --), matched exactly; SQ_FMT is not the log's"
	local fx; fx=$(log_fx done <<'EOF'
StateCompact=CD
@file create wd/out_500.log done\n
EOF
)
	local -a flags=(-c -C -x --center --centre --center-all --centre-all --expand --no-recent --color --colour
	                --no-color --no-colour --compact --me --all --hide --array --noconvert --noheader --priority --local)
	sq_run "$fx" -- "${flags[@]}" log --no-follow 500
	need "every valueless flag before log (and the --no-bell sq_run adds): rc 0, the file" eval 'rc_is 0 && [ "$(cat "$OUT")" = done ]'
	need "... one squeue call, sq log's" eval '[ "$(calls squeue)" = 1 ] && argv_has squeue -h --jobs=500 -t all'
	sq_run "$fx" -- --full log --no-follow 500
	need "--full before log: dispatched" eval 'rc_is 0 && [ "$(cat "$OUT")" = done ]'
	sq_run "$fx" -- --me -- log --no-follow 500
	need "--me -- log: dispatched" eval 'rc_is 0 && [ "$(cat "$OUT")" = done ]'
	sq_run "$fx" SQ_FMT=bogus%% SQ_CENTER=x SQ_RECENT_MAX=-1 SQ_COMPACT=7 -- log --no-follow 500
	need "D4: a dashboard setting is neither applied nor validated" eval 'rc_is 0 && [ "$(cat "$OUT")" = done ] && err_is "sq log: job 500 ended: COMPLETED (exit code 0:0)"'
	sq_run "$fx" -- log -h
	need "sq log -h: rc 0, its help on stdout, no Slurm call" eval 'rc_is 0 && has "usage: sq log" && no_slurm_call'
	sq_run empty -- -h
	need "sq -h names the subcommand" has "sq log JOBID"
	sub_refused "sq: 'Log' is not a subcommand; sq -h lists them (did you mean sq log?)" Log 500
	# -h and a usage error need no tmp dir: an unusable TMPDIR changes nothing
	sq_run empty TMPDIR=/nonexistent/x -- -h
	need "TMPDIR unusable: sq -h, rc 0, the help" eval 'rc_is 0 && has "auto-fitting Slurm dashboard" && err_empty'
	sq_run empty TMPDIR=/nonexistent/x -- --bogus
	need "TMPDIR unusable: sq --bogus, rc 2, its own words" eval 'rc_is 2 && out_empty && err_is "sq: --bogus is not one of the long options sq forwards; sq -h lists them"'
	sq_run empty TMPDIR=/nonexistent/x -- log -h
	need "TMPDIR unusable: sq log -h, rc 0" eval 'rc_is 0 && has "usage: sq log" && err_empty'
	sq_run empty TMPDIR=/nonexistent/x -- log
	need "TMPDIR unusable: sq log, rc 2, its own words" eval 'rc_is 2 && out_empty && err_is "sq log: which job? e.g. sq log 12345"'
}
c_sub_stray() {   # D3, D6
	T_TITLE="a word sq cannot place is rc 2 with the hint that fits: subcommands first, the table's hints, clusters, empty words, -j N M"
	sub_refused "sq: subcommands come first, before any option that takes a value: sq log …" -p main log 500
	sub_refused "sq: subcommands come first, before any option that takes a value: sq log …" -u alice --all log 500
	sub_refused "sq: subcommands come first, before any option that takes a value: sq log …" -o i,j log 500
	sub_refused "sq: subcommands come first, before any option that takes a value: sq log …" --reserve 2 log 500
	sub_refused "sq: subcommands come first: sq log …" -Z log 500
	sq_run "$(log_fx done <<'EOF'
StateCompact=CD
@file create wd/out_500.log done\n
EOF
)" -- -a log --no-follow 500
	need "-a log 500: -a takes no value, so sq log runs (OPTS-v4 N8)" eval 'rc_is 0 && [ "$(cat "$OUT")" = done ]'
	sub_refused "sq: subcommands come first, before any option that takes a value: sq log …" -p main -- log 500
	sub_refused "sq log: job output files are read on this machine; drop -M" -M other log 500
	sub_refused "sq log: job output files are read on this machine; drop --clusters" --clusters=other log 500
	sub_refused "sq log: job output files are read on this machine; drop --federation" --federation log 500
	sub_refused "sq log: job output files are read on this machine; drop --sibling" --sibling -p main log 500
	sub_refused "sq: 'foo' is not a subcommand; sq -h lists them" foo
	sub_refused "sq: 'LOG' is not a subcommand; sq -h lists them (did you mean sq log?)" LOG 500
	sub_refused "sq: 'logs' is not a subcommand; sq -h lists them (did you mean sq log?)" logs 500
	sub_refused "sq: 'help' is not a subcommand; sq -h lists them (did you mean sq -h?)" help
	sub_refused "sq: 'me' is not a subcommand; sq -h lists them (did you mean sq --me?)" me
	sub_refused "sq: 'no-recent' is not a subcommand; sq -h lists them (did you mean sq --no-recent?)" --full no-recent
	# SQJOB-v3's D6 changes: a job id alone, and "jobs", now point at sq job
	sub_refused "sq: '123' is not a subcommand; sq -h lists them (did you mean sq job 123?)" 123
	sub_refused "sq: 'jobs' is not a subcommand; sq -h lists them (did you mean sq job?)" jobs 123
	sub_refused "sq: 'JOB' is not a subcommand; sq -h lists them (did you mean sq job?)" JOB 123
	sub_refused "sq: '123_4' is not a subcommand; sq -h lists them" 123_4
	sub_refused "sq: '6' is not a subcommand; sq -h lists them (did you mean sq -j 5,6?)" -j 5 6
	sub_refused "sq: '6' is not a subcommand; sq -h lists them (did you mean sq -j 5,6?)" --jobs=5 6
	sub_refused "sq: cannot tell what 'i' belongs to after '-ao'; write the options apart, e.g. -a -o i" -ao i
	sub_refused "sq: cannot tell what '5' belongs to after '-aj'; write the options apart, e.g. -a -j 5" -aj 5
	sub_refused "sq: cannot tell what 'log' belongs to after '-xn'; write the options apart, e.g. -x -n log" -xn log
	sub_refused "sq: an empty argument (an unset variable?)" ''
	sub_refused "sq: an empty argument (an unset variable?)" -p main ' '
	sub_refused "sq: '-' is not a subcommand; sq -h lists them" -
	sub_refused "sq: 'x' is not a subcommand; sq -h lists them" -- x
	sub_refused "sq: '--' is not a subcommand; sq -h lists them" -- --
	sub_refused "sq: '-u' is not a subcommand; sq -h lists them" -- -u alice
	# D6: what the dashboard did with these before
	sub_refused "sq: 'foo' is not a subcommand; sq -h lists them" -p main foo
	sub_refused "sq: 'foo' is not a subcommand; sq -h lists them" foo -h
	# every echoed word scrubbed and cut to 40 characters
	sub_refused "sq: 'abc[31mdefghijklmnopqrstuvwxyzabcdefghij' is not a subcommand; sq -h lists them" \
		"$(printf 'abc\033[31mdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz')"
	# what still is the dashboard
	sq_run empty -- --
	need "a bare -- is still swallowed: the dashboard" eval 'rc_is 0 && has "queue is empty"'
	sq_run empty -- -h foo
	need "-h before a stray word: the help, as before" eval 'rc_is 0 && has "auto-fitting Slurm dashboard"'
	sq_run empty -- -n log
	need "-n log: a job named log, the dashboard" eval 'rc_is 0 && argv_has squeue -n log'
}

# ============================================================================
# sq log JOBID (SQLOG-v3)
# ============================================================================
# Franz (2026-10-20): "out; --err for err"; "All, follow, stop at end"; purged
# jobs "Refuse"; arrays "Ask for a task"; job failed "0, plus an end note";
# notes when piped "Always"; SLURM_CLUSTERS "Refuse"; the log text "Raw".
# The stub answers each poll from its @step (tests/lib/stub.sh), and @file
# writes the job's file in the run's directory as a step is served; sq polls
# every 5 s, so a call number is a moment in the follow.
log_fx() {   # log_fx NAME: a fixture whose squeue-all is stdin after log-defaults; prints its dir
	local d=$T_DIR/fx-$1; mkdir -p "$d"
	{ printf '@include %s\n' "$fixtures/_common/log-defaults"; cat; } > "$d/squeue-all"
	printf '%s' "$d"
}
err_is() { [ "$(cat "$ERR")" = "$1" ]; }
# no call saw an SQUEUE_* setting but the SQUEUE_FORMAT2 sq set (stub.sh logs all)
only_format2() {
	gawk -F'\t' '$1 == "CALL" { n++; for (i = 4; i <= NF; i++)
		if ($i ~ /^SQUEUE_/ && $i !~ /^SQUEUE_FORMAT2=/ && $i !~ /[(]unset[)]$/) bad = 1 }
		END { exit !(n && !bad) }' "$LOG"
}           # err_is TEXT: stderr is exactly TEXT
out_is() { [ "$(cat "$OUT"; echo .)" = "$1." ]; }  # out_is TEXT: stdout byte for byte, last newline too
wd() { printf '%s/wd/%s' "$RUN" "$1"; }            # wd FILE: FILE in the run's work dir

c_log_follow() {   # L4, L5: each phase, polled, in parallel runs
	T_TITLE="sq log follows: pending, the file late, -n, CG, a requeue, held, special exit, an outage, a job gone, a file never written, --err"
	local late n cg rq rh se down gone0 gone1 never err bad r
	sq_start "$(log_fx late <<'EOF'
@step 1
StateCompact=PD; Reason=Priority
@step 2
StateCompact=R
@step 4
StateCompact=R
@file create wd/out_500.log one\ntwo\n
@step 5
StateCompact=R
@file append wd/out_500.log three\n
@step 6
StateCompact=CD; exit_code=0:0
EOF
)" -- log 500; late=$RUN
	sq_start "$(log_fx n <<'EOF'
@step 1
StateCompact=R
@file create wd/out_500.log a\nb\nc\nd\n
@step 2
StateCompact=R
@file append wd/out_500.log e\n
@step 3
StateCompact=CD
EOF
)" -- log -n 2 500; n=$RUN
	sq_start "$(log_fx cg <<'EOF'
@step 1
StateCompact=R
@file create wd/out_500.log start\n
@step 2
StateCompact=CG
@file append wd/out_500.log cg1\n
@step 3
StateCompact=CG
@file append wd/out_500.log cg2\n
@step 4
StateCompact=TO; exit_code=0:15
@file append wd/out_500.log last
EOF
)" -- log 500; cg=$RUN
	local held_body='@step 1
StateCompact=R
@file create wd/out_500.log run0\n
@step 2'
	sq_start "$(log_fx rq <<<"$held_body"$'\nStateCompact=CG; RestartCnt=1')" -- log 500; rq=$RUN
	sq_start "$(log_fx rh <<<"$held_body"$'\nStateCompact=RH; RestartCnt=1; Reason=launch failed requeued held')" -- log 500; rh=$RUN
	sq_start "$(log_fx se <<<"$held_body"$'\nStateCompact=SE; RestartCnt=1')" -- log 500; se=$RUN
	sq_start "$(log_fx down <<'EOF'
@step 1
StateCompact=R
@file create wd/out_500.log x\n
@step 2
@stderr squeue: error: Unable to contact slurm controller (connect failure)
@exit 1
@step 4
StateCompact=CD
EOF
)" -- log 500; down=$RUN
	sq_start "$(log_fx gone0 <<'EOF'
@step 1
StateCompact=R
@file create wd/out_500.log x\n
@step 2
# Slurm no longer has the record: nothing
EOF
)" -- log 500; gone0=$RUN
	sq_start "$(log_fx gone1 <<'EOF'
@step 1
StateCompact=R
@file create wd/out_500.log x\n
@step 2
@stderr slurm_load_jobs error: Invalid job id specified
@exit 1
EOF
)" -- log 500; gone1=$RUN
	sq_start "$(log_fx never <<'EOF'
@step 1
StateCompact=R
@step 2
StateCompact=F; exit_code=1:0
EOF
)" -- log 500; never=$RUN
	# a poll that fails, or answers what cannot be read, leaves the last good
	# record's fields: the "waiting" note still names the host
	local keep keepfail keepraw keepcut
	for keep in fail raw cut; do
		case $keep in
			fail) bad=$'@stderr squeue: error: Unable to contact slurm controller (connect failure)\n@exit 1' ;;
			raw)  bad='@raw not a record' ;;
			cut)  bad=$'@cut\nStateCompact=R' ;;
		esac
		sq_start "$(log_fx "keep$keep" <<<$'@step 1\nStateCompact=R\n@step 2\n'"$bad"$'\n@step 4\nStateCompact=CD')" -- log 500
		printf -v "keep$keep" '%s' "$RUN"
	done
	sq_start "$(log_fx err <<'EOF'
@defaults STDERR=\{run}/wd/err_%j.log
@step 1
StateCompact=R
@file create wd/out_500.log out\n
@file create wd/err_500.log err\n
@step 2
StateCompact=CD
EOF
)" -- log --err 500; err=$RUN

	# the 3 s grace: the end comes well after the poll that saw it (counted
	# in 0.1 s steps; without the grace it comes within a second or two)
	local grace_ok=
	use_run "$n"; waits_for 30 eval '[ "$(stub_calls)" -ge 3 ]' && ! waits_for 2.0 eval '[ -s "$RUN/rc" ]' && grace_ok=1
	sq_finish "$late"
	need "late: nothing of sq's alive when it returned" nothing_at_exit
	need "late: rc 0, the whole file as it grew" eval 'rc_is 0 && out_is "one
two
three
"'
	need "late: the notes, once each: pending, waiting for the file (after ~10 s), the end" eval 'err_is "sq log: job 500 is pending (Priority); waiting for it to start
sq log: waiting for $(wd out_500.log) to appear (job 500 runs on node01.cluster)
sq log: job 500 ended: COMPLETED (exit code 0:0)"'
	need "late: Slurm asked every poll until the end: 6 calls" eval '[ "$(stub_calls)" = 6 ]'
	need "late: L0's environment on every call" eval 'all_calls_env SLURM_TIME_FORMAT %s squeue && all_calls_env SLURM_BITSTR_LEN 0 squeue && only_format2'
	sq_finish "$n"
	need "-n 2: sq ran on for more than 2 s after the final poll" eval '[ -n "$grace_ok" ]'
	need "-n 2: the last 2 lines, then what came" eval 'rc_is 0 && out_is "c
d
e
" && err_is "sq log: job 500 ended: COMPLETED (exit code 0:0)"'
	sq_finish "$cg"
	need "CG: nothing of sq's alive when it returned" nothing_at_exit
	need "CG: followed through two CG polls, with what was written then and at the end" eval 'rc_is 0 && out_is "start
cg1
cg2
last" && err_is "sq log: job 500 ended: TIMEOUT (exit code 0:15)" && [ "$(stub_calls)" = 4 ]'
	sq_finish "$rq"
	need "requeue: RestartCnt 0 -> 1 (in CG) ends with the note, rc 0" eval 'rc_is 0 && out_is "run0
" && err_is "sq log: job 500 was requeued (restart 1); run sq log 500 again for its new run" && [ "$(stub_calls)" = 2 ]'
	sq_finish "$rh"
	need "RH: the held note" eval 'rc_is 0 && err_is "sq log: job 500 was requeued (restart 1) and is held; run sq log 500 again for its new run"'
	sq_finish "$se"
	need "SE: the special-exit note" eval 'rc_is 0 && err_is "sq log: job 500 was requeued (restart 1) and is in special exit; run sq log 500 again for its new run"'
	sq_finish "$down"
	need "outage: noted once over two failed polls, followed on, then the end" eval 'rc_is 0 && out_is "x
" && err_is "sq log: slurm unreachable (squeue: error: Unable to contact slurm controller (connect failure)); still following
sq log: job 500 ended: COMPLETED (exit code 0:0)" && [ "$(stub_calls)" = 4 ]'
	sq_finish "$gone0"
	need "gone (no record): rc 0, the note" eval 'rc_is 0 && out_is "x
" && err_is "sq log: job 500 is gone from Slurm; stopping"'
	sq_finish "$gone1"
	need "gone (Invalid job id): rc 0, the note" eval 'rc_is 0 && out_is "x
" && err_is "sq log: job 500 is gone from Slurm; stopping"'
	sq_finish "$never"
	need "ended, the file never written: rc 1" eval 'rc_is 1 && out_empty && err_is "sq log: job 500 ended; $(wd out_500.log) was never written"'
	sq_finish "$err"
	need "--err: the stderr file" eval 'rc_is 0 && out_is "err
"'
	local why
	for keep in fail raw cut; do
		case $keep in
			fail) why="squeue: error: Unable to contact slurm controller (connect failure)" ;;
			*)    why="squeue output unreadable" ;;
		esac
		r=keep$keep; sq_finish "${!r}"
		need "a poll that $keep: the note still names the host" eval 'rc_is 1 && err_is "sq log: slurm unreachable ($why); still following
sq log: waiting for $(wd out_500.log) to appear (job 500 runs on node01.cluster)
sq log: job 500 ended; $(wd out_500.log) was never written"'
	done
}

c_log_now() {   # L2, L3's refusals, L4's --no-follow and the already-final job
	T_TITLE="sq log on the first answer: --no-follow, an ended job, unreadable, purged, unknown task, arrays, het jobs, interactive, /dev/null, --err, refusals"
	local fx
	fx=$(log_fx run <<'EOF'
StateCompact=R
@file create wd/out_500.log a\nb\n
EOF
)
	sq_run "$fx" -- log --no-follow 500
	need "--no-follow, running: what is there, rc 0, no note" eval 'rc_is 0 && out_is "a
b
" && err_empty && [ "$(stub_calls)" = 1 ]'
	sq_run "$fx" -- log --no-follow -n1 500
	need "--no-follow -n1: the last line" eval 'rc_is 0 && out_is "b
"'
	sq_run "$fx" -- log 500 -n 1 --no-follow
	need "options after the id, -n 1 apart: the same" eval 'rc_is 0 && out_is "b
"'
	sq_run "$(log_fx pend <<<'StateCompact=PD; Reason=Resources')" -- log --no-follow 500
	need "--no-follow, pending: rc 1" eval 'rc_is 1 && out_empty && err_is "sq log: job 500 has not started yet"'
	sq_run "$(log_fx nofile <<<'StateCompact=R')" -- log --no-follow 500
	need "--no-follow, no file yet: rc 1" eval 'rc_is 1 && err_is "sq log: $(wd out_500.log) was not written yet (job 500 runs on node01.cluster)"'
	fx=$(log_fx ended <<'EOF'
StateCompact=F; exit_code=2:0
@file create wd/out_500.log done\n
EOF
)
	sq_run "$fx" -- log 500
	need "already ended: the file, no follow, the end note, rc 0, one call" eval 'rc_is 0 && out_is "done
" && err_is "sq log: job 500 ended: FAILED (exit code 2:0)" && [ "$(stub_calls)" = 1 ]'
	sq_run "$fx" -- log --no-follow 000500
	need "--no-follow on an ended job: the same; leading zeros dropped" eval 'rc_is 0 && out_is "done
" && argv_has squeue --jobs=500'
	sq_run "$(log_fx endnofile <<<'StateCompact=CA; exit_code=0:0')" -- log 500
	need "already ended, never written: rc 1" eval 'rc_is 1 && err_is "sq log: job 500 ended; $(wd out_500.log) was never written"'
	sq_run "$(log_fx locked <<'EOF'
StateCompact=R
@file create wd/out_500.log secret\n
@file chmod wd/out_500.log 000
EOF
)" -- log 500
	need "unreadable: rc 1" eval 'rc_is 1 && out_empty && err_is "sq log: cannot read $(wd out_500.log): Permission denied"'
	local purged="sq log: Slurm does not know job 500 (it ended more than about 5 minutes ago, or never existed), so its output path is unknown"
	sq_run "$(log_fx purged1 <<<$'@stderr slurm_load_jobs error: Invalid job id specified\n@exit 1')" -- log 500
	need "purged (Invalid job id): rc 1, the refusal" eval 'rc_is 1 && err_is "$purged"'
	sq_run "$(log_fx purged0 <<<'# nothing')" -- log 500
	need "purged (no record): rc 1, the refusal" eval 'rc_is 1 && err_is "$purged"'
	sq_run "$(log_fx down <<<$'@stderr squeue: error: Unable to contact slurm controller (connect failure)\n@exit 1')" -- log 500
	need "unreachable at once: rc 1" eval 'rc_is 1 && err_is "sq log: slurm unreachable · squeue: error: Unable to contact slurm controller (connect failure)"'
	sq_run "$(log_fx hang <<<'@hang 10')" SQ_TIMEOUT=1 -- log 500
	need "SQ_TIMEOUT bounds it: rc 1" eval 'rc_is 1 && err_is "sq log: slurm unreachable · no response after 1s"'
	sq_run "$(log_fx garbage <<<'@raw not a record')" -- log 500
	need "an answer sq cannot read: rc 1" eval 'rc_is 1 && err_is "sq log: slurm unreachable · squeue output unreadable"'

	local tasks='JobID=601; ArrayJobID=600; ArrayTaskID=1; StateCompact=R
JobID=602; ArrayJobID=600; ArrayTaskID=2; StateCompact=R
JobID=600; ArrayJobID=600; ArrayTaskID=4-5,9%2; StateCompact=PD'
	sq_run "$(log_fx notask <<<$'@step 1\n# no task 7\n@step 2\n'"$tasks")" -- log 600_7
	need "unknown task: rc 1 with the tasks the array has, from a second call on the array" eval 'rc_is 1 && err_is "sq log: Slurm does not know task 600_7; array 600 has tasks 1,2,4,5,9" && argv_has squeue --jobs=600_7 && argv_has squeue --jobs=600'
	sq_run "$(log_fx notaskdown <<<$'@step 1\n# no task 7\n@step 2\n@stderr squeue: error: Unable to contact slurm controller (connect failure)\n@exit 1')" -- log 600_7
	need "unknown task, the second call failing: unreachable, not unknown" eval 'rc_is 1 && err_is "sq log: slurm unreachable · squeue: error: Unable to contact slurm controller (connect failure)"'
	sq_run "$(log_fx array <<<"$tasks")" -- log 600
	need "an array named bare: rc 2, a task to name" eval 'rc_is 2 && err_is "sq log: 600 is an array; name a task, e.g. sq log 600_1 (its tasks: 1,2,4,5,9)"'
	sq_run "$(log_fx bigarray <<<'JobID=600; ArrayJobID=600; ArrayTaskID=0-99:3%4; StateCompact=PD')" -- log 600
	need "a pending array: 10 tasks at most" eval 'rc_is 2 && err_is "sq log: 600 is an array; name a task, e.g. sq log 600_0 (its tasks: 0,3,6,9,12,15,18,21,24,27,…)"'
	sq_run "$(log_fx lasttask <<'EOF'
JobID=600; ArrayJobID=600; ArrayTaskID=9; StateCompact=CD; STDOUT=\{run}/wd/slurm-600.out; STDERR=\{run}/wd/slurm-600.out
@file create wd/slurm-600_9.out task 9\n
EOF
)" -- log --no-follow 600
	need "the array's last task by the array id: named, followed, slurm-%A_%a.out" eval 'rc_is 0 && out_is "task 9
" && err_is "sq log: job 600 is task 600_9 of an array; showing it
sq log: job 600 ended: COMPLETED (exit code 0:0)"'
	sq_run "$(log_fx task <<'EOF'
JobID=602; ArrayJobID=600; ArrayTaskID=2; StateCompact=CD; STDOUT=\{run}/wd/slurm-602.out; STDERR=\{run}/wd/slurm-602.out
@file create wd/slurm-600_2.out task 2\n
EOF
)" -- log --no-follow 600_2
	need "a task by N_T: its own record, slurm-%A_%a.out" eval 'rc_is 0 && out_is "task 2
" && argv_has squeue --jobs=600_2'

	local het='JobID=700; ArrayJobID=700; HetJobID=700; HetJobOffset=0; StateCompact=CD; STDOUT=\{run}/wd/het_%j.out; STDERR=\{run}/wd/het_%j.out
JobID=701; ArrayJobID=701; HetJobID=700; HetJobOffset=1; StateCompact=CD; STDOUT=\{run}/wd/het_%j.out; STDERR=\{run}/wd/het_%j.out
@file create wd/het_700.out leader\n'
	local hetnote="sq log: job %s belongs to het job 700, whose leader 700+0 writes its output; showing that
sq log: job %s ended: COMPLETED (exit code 0:0)"
	sq_run "$(log_fx het1 <<<"$het")" -- log --no-follow 700+1
	need "N+K: the leader's file, one note" eval 'rc_is 0 && out_is "leader
" && err_is "$(printf "$hetnote" 700+1 700+1)" && argv_has squeue --jobs=700+1'
	sq_run "$(log_fx het0 <<<"$het")" -- log --no-follow 700
	need "the leader by its id: no note" eval 'rc_is 0 && out_is "leader
" && err_is "sq log: job 700 ended: COMPLETED (exit code 0:0)"'
	sq_run "$(log_fx hetboth <<<"$het")" -- log --no-follow 701
	need "a component by its own id, its leader in the answer: the leader" eval 'rc_is 0 && out_is "leader
" && err_is "$(printf "$hetnote" 701 701)"'
	sq_run "$(log_fx hetalone <<<$'@step 1\nJobID=701; ArrayJobID=701; HetJobID=700; HetJobOffset=1; StateCompact=CD\n@step 2\n'"$het")" -- log --no-follow 701
	need "a component alone in the answer: asked again by its het job's id" eval 'rc_is 0 && out_is "leader
" && err_is "$(printf "$hetnote" 701 701)" && argv_has squeue --jobs=701 && argv_has squeue --jobs=700'
	sq_run "$(log_fx nothet <<<'StateCompact=R')" -- log 500+1
	need "N+K on a job that is no het job: rc 2" eval 'rc_is 2 && err_is "sq log: 500 is not a het job, so 500+1 names no component of one; e.g. sq log 500"'

	sq_run "$(log_fx interactive <<<'BatchFlag=0; STDOUT=N/A; STDERR=N/A')" -- log 500
	need "an interactive job: rc 1" eval 'rc_is 1 && err_is "sq log: job 500 is an interactive job; its output went to its terminal"'
	sq_run "$(log_fx null <<<'STDOUT=/dev/null; STDERR=/dev/null')" -- log 500
	need "-o none: rc 1" eval 'rc_is 1 && err_is "sq log: job 500'"'"'s output is discarded (it goes to /dev/null)"'
	sq_run "$(log_fx nullout <<<'STDOUT=/dev/null; STDERR=\{run}/wd/e.log')" -- log 500
	need "-o none -e FILE: rc 1, pointing at --err" eval 'rc_is 1 && err_is "sq log: job 500'"'"'s output is discarded (it goes to /dev/null); its stderr has a file of its own: sq log --err 500"'
	sq_run "$(log_fx nullerr <<<'STDERR=/dev/null')" -- log --err 500
	need "--err with -e none: rc 1, drop --err" eval 'rc_is 1 && err_is "sq log: job 500'"'"'s stderr is discarded (it goes to /dev/null); drop --err"'
	fx=$(log_fx same <<'EOF'
StateCompact=CD
@file create wd/out_500.log both\n
EOF
)
	sq_run "$fx" -- log --err --no-follow 500
	need "--err without -e: the stdout file, one note" eval 'rc_is 0 && out_is "both
" && err_is "sq log: job 500 writes its stderr into its stdout file; showing that
sq log: job 500 ended: COMPLETED (exit code 0:0)"'

	# L0: the environment
	sq_run "$fx" SQUEUE_USERS=nobody SQUEUE_PARTITION=x SQUEUE_SORT=bogus SQUEUE_FORMAT=%i SQUEUE_STATES=PD SLURM_TIME_FORMAT=relative SLURM_BITSTR_LEN=5 -- log --no-follow 500
	need "inherited SQUEUE_* unset, SQUEUE_FORMAT2 framed, %s and 0 pinned" eval 'rc_is 0 && out_is "both
" && only_format2 && [ "$(env_of squeue 1 SLURM_TIME_FORMAT)" = %s ] && [ "$(env_of squeue 1 SLURM_BITSTR_LEN)" = 0 ]'
	need "the format: the 17 fields, each ending in the nonce" eval 'n=$(env_of squeue 1 SQ_NONCE); [ "$(env_of squeue 1 SQUEUE_FORMAT2)" = "$(for f in JobID ArrayJobID ArrayTaskID HetJobID HetJobOffset StateCompact RestartCnt BatchFlag BatchHost WorkDir STDOUT STDERR UserName Name StartTime Reason exit_code; do printf "%s:%s," "$f" "$n"; done | sed "s/,\$//")" ]'
	sq_run "$fx" SLURM_CLUSTERS=other -- log 500
	need "SLURM_CLUSTERS: refused" eval 'rc_is 2 && no_slurm_call && err_is "sq log: job output files are read on this machine; unset SLURM_CLUSTERS"'
	sq_run "$fx" SLURM_CLUSTERS= -- log 500
	need "SLURM_CLUSTERS empty: refused too" eval 'rc_is 2 && no_slurm_call && err_is "sq log: job output files are read on this machine; unset SLURM_CLUSTERS"'
	# L5: following needs GNU tail >= 8.28; showing what is there does not
	local tailpath="$here/lib/tail-as:$here/bin:$PATH"
	sq_run "$fx" PATH="$tailpath" SQSTUB_TAIL=busybox -- log 500
	need "BusyBox tail: rc 1 before any Slurm call" eval 'rc_is 1 && no_slurm_call && err_is "sq log: following needs GNU tail; use --no-follow"'
	sq_run "$fx" PATH="$tailpath" SQSTUB_TAIL=old -- log 500
	need "GNU tail 8.22: rc 1" eval 'rc_is 1 && no_slurm_call && err_is "sq log: following needs GNU tail; use --no-follow"'
	sq_run "$fx" PATH="$tailpath" SQSTUB_TAIL=busybox -- log --no-follow 500
	need "--no-follow needs no GNU tail" eval 'rc_is 0 && out_is "both
"'
}

# A FIFO or a device as the output path: opening the FIFO blocked sq log for
# good, and tail streamed /dev/zero into its reader without end.  Refused at
# once, as sq job's why tail refuses one, running or ended, followed or not
c_log_not_regular() {
	T_TITLE="sq log on a FIFO or /dev/zero as the output path: rc 1 within 2 s, 'is not a regular file', nothing left running"
	local fifo=$T_DIR/fifo path state mode
	mkfifo "$fifo"
	for path in "$fifo" /dev/zero; do
		for state in R CD; do
			for mode in --no-follow ""; do
				sq_start "$(log_fx "${path##*/}-$state${mode:+-nofollow}" <<<"StateCompact=$state; STDOUT=$path; STDERR=$path")" \
					-- log ${mode:+"$mode"} 500
				sq_finish "$RUN" 2
				need "$path, $state, ${mode:-following}: rc 1 within 2 s, the refusal, nothing written, nothing left running" \
					eval 'rc_is 1 && out_empty && err_is "sq log: $path is not a regular file" && nothing_at_exit && nothing_left'
			done
		done
	done
}

c_log_syntax() {   # L1
	T_TITLE="sq log's command line: options before or after the id, -n N, repeats, --, every refusal with an example"
	local example="e.g. sq log 12345, an array task 12345_4 or a het job's component 12345+1" w
	local fx; fx=$(log_fx done <<'EOF'
StateCompact=CD
@file create wd/out_500.log a\nb\nc\n
EOF
)
	sq_run "$fx" -- log -e --err --no-follow --no-follow -n 1 -n5 500
	need "repeats are harmless, the last -n counts" eval 'rc_is 0 && out_is "a
b
c
"'
	sq_run "$fx" -- log --no-follow -- 500
	need "-- before the id" eval 'rc_is 0 && argv_has squeue --jobs=500'
	sq_run "$fx" -- log --no-follow 4294967293
	need "the highest job id is asked about" argv_has squeue --jobs=4294967293
	sq_run "$fx" -- log --no-follow 0000600_0009
	need "leading zeros dropped in a task id" argv_has squeue --jobs=600_9
	log_refused() {   # log_refused TEXT ARGS...
		local text=$1; shift
		sq_run "$fx" -- log "$@"
		need "sq log $*: rc 2, no Slurm call, '$text'" eval 'rc_is 2 && out_empty && no_slurm_call && err_is "sq log: $text"'
	}
	log_refused "which job? e.g. sq log 12345"
	log_refused "which job? e.g. sq log 12345" --no-follow --
	log_refused "-n needs a number of lines, e.g. sq log -n 20 12345" 500 -n
	log_refused "-n needs a number of lines, not 'x'; e.g. sq log -n 20 12345" -n x 500
	log_refused "-n needs a number of lines, not 'x'; e.g. sq log -n 20 12345" -nx 500
	log_refused "-n needs a number of lines, not '-5'; e.g. sq log -n 20 12345" -n -5 500
	log_refused "-n needs a number of lines, not '1234567890'; e.g. sq log -n 20 12345" -n 1234567890 500
	log_refused "-n needs a number of lines, not '=5'; e.g. sq log -n 20 12345" -n=5 500
	log_refused "--err takes no value; write it on its own, e.g. sq log --err 12345" --err=x 500
	log_refused "--no-follow takes no value; write it on its own, e.g. sq log --no-follow 12345" --no-follow=1 500
	log_refused "--help takes no value; write it on its own, e.g. sq log --help 12345" --help=x
	log_refused "'-x' is not an option of sq log (sq log -h lists them); e.g. sq log -n 20 --err 12345" -x 500
	log_refused "'--follow' is not an option of sq log (sq log -h lists them); e.g. sq log -n 20 --err 12345" --follow 500
	log_refused "'-en' is not an option of sq log (sq log -h lists them); e.g. sq log -n 20 --err 12345" -en 5 500
	log_refused "one job at a time, not '500' and '501'; e.g. sq log 12345" 500 501
	log_refused "one job at a time, not '500' and '--no-follow'; e.g. sq log 12345" -- 500 --no-follow
	for w in 0 '' abc 5_ '5_[1-3]' 12345678901 4294967294 5_4000001 5_12345678 5+12345 5+ +1 _1 '0_1' ' 5'; do
		log_refused "'$w' is not a job id; $example" "$w"
	done
	log_refused "'-5' is not a job id; $example" -- -5
	sq_run "$fx" -- log 5_4000000 --no-follow
	need "task 4000000 is still a task" argv_has squeue --jobs=5_4000000
	sq_run "$fx" -- log --help
	need "the help: rc 0, the five things L8 says" eval 'rc_is 0 && no_slurm_call && has "ends shortly" && has "reused" && has "cannot tell it the job ended" && has "python -u" && has "stdbuf -oL" && has "--no-follow -n N"'
}

c_log_paths() {   # L3: the path the job's slurmstepd computes
	T_TITLE="sq log's path: slurmstepd's expansion (fname_port.py's table), the NULL defaults, -e, relative patterns, backslashes"
	# The table of ~/.claude-scratch/sq/attack-sqlog-slurm/fname_port.py, a port of
	# Slurm 23.11.4 fname.c (job 11875, no array, user schroder, name nc, batch
	# host fb2-bioinf), pattern -> what slurmstepd writes.  Each case reads the
	# path back from the "never written" refusal of an ended job.
	local -a table=(
		'o_%j.out'          'o_11875.out'
		'o_%5j.out'         'o_11875.out'
		'o_%05j.out'        'o_11875.out'
		'o_%010j.out'       'o_0000011875.out'
		'o_%100j.out'       'o_0000011875.out'
		'o_%%N.out'         'o_%N.out'
		'o_%%%j.out'        'o_%11875.out'
		'o_%N_%j.out'       'o_fb2-bioinf_11875.out'
		'o_%5N.out'         'o_fb2-bioinf.out'
		'o_%J_%s_%t_%n.out' 'o_11875_batch_0_0.out'
		'o_%05Z.out'        'o_5Z.out'
		'o_%a.out'          'o_4294967294.out'
		'o\_%j.out'         'o_%j.out'
		'o_\\%j.out'        'o_\%j.out'
		'o_%%j\x.out'       'o_%%jx.out'
		'o_%5'              'o_5'
		'o_%u_%x_%A.out'    'o_schroder_nc_11875.out'
		'o_%3t_%2n.out'     'o_000_00.out'
		'o_%Z_%.out'        'o_%Z_%.out'
		'o_%'               'o_%'
	)
	local i pat want rec
	rec='JobID=11875; ArrayJobID=11875; ArrayTaskID=N/A; UserName=schroder; Name=nc; BatchHost=fb2-bioinf.bioinf.local; WorkDir=/data/wd; StateCompact=CD'
	path_is() {   # path_is NAME RECORD-FIELDS WANT [sq log args]: the refusal names WANT
		local name=$1 fields=$2 want=$3; shift 3
		local -a args=("$@"); [ $# -gt 0 ] || args=(11875)
		sq_run "$(printf '@defaults %s\n%s\n' "$rec" "$fields" | log_fx "$name")" -- log --no-follow "${args[@]}"
		need "$name: $want" eval 'rc_is 1 && tail -n 1 "$ERR" | grep -qxF "sq log: job ${args[-1]} ended; $want was never written"'
	}
	for ((i = 0; i < ${#table[@]}; i += 2)); do
		pat=$(printf '%s' "${table[i]}" | sed 's/\\/\\\\/g')   # a fixture writes \ as \\
		want=${table[i+1]}
		path_is "t$i" "STDOUT=/data/wd/$pat; STDERR=/data/wd/$pat" "/data/wd/$want"
	done
	# NULL: squeue prints WorkDir/slurm-JOBID.out, slurmstepd writes slurm-%J.out,
	# for an array task slurm-%A_%a.out; without -e, stderr goes where stdout does
	path_is null "STDOUT=/data/wd/slurm-11875.out; STDERR=/data/wd/slurm-11875.out" /data/wd/slurm-11875.out
	path_is nullarray "JobID=11880; ArrayJobID=11875; ArrayTaskID=5; STDOUT=/data/wd/slurm-11880.out; STDERR=/data/wd/slurm-11880.out" \
		/data/wd/slurm-11875_5.out 11875_5
	path_is nullerr "JobID=11880; ArrayJobID=11875; ArrayTaskID=5; STDOUT=/data/wd/slurm-11880.out; STDERR=/data/wd/slurm-11880.out" \
		/data/wd/slurm-11875_5.out --err 11875_5
	need "nullerr: the same-file note first" eval 'head -n 1 "$ERR" | grep -qxF "sq log: job 11875_5 writes its stderr into its stdout file; showing that"'
	path_is erronly "JobID=11880; ArrayJobID=11875; ArrayTaskID=5; STDOUT=/data/wd/slurm-11880.out; STDERR=/data/wd/e_%A_%a.err" \
		/data/wd/e_11875_5.err --err 11875_5
	path_is outonly "STDOUT=/data/o/%x.log; STDERR=/data/o/%x.log" /data/o/nc.log --err 11875
	path_is notnull "STDOUT=/data/wd/slurm-11875.log; STDERR=/data/wd/slurm-11875.log" /data/wd/slurm-11875.log
	# relative (scontrol update can leave one): joined to WorkDir; with a
	# backslash appended as it is, as fname_create() does
	path_is rel "STDOUT=r_%j.out; STDERR=r_%j.out" /data/wd/r_11875.out
	path_is relslash "WorkDir=/data/wd/; STDOUT=r.out; STDERR=r.out" /data/wd/r.out
	path_is relbackslash "STDOUT=r\\\\_%j.out; STDERR=r\\\\_%j.out" /data/wdr_%j.out
	path_is spaces "WorkDir=/data/my wd; STDOUT=/data/my wd/a b %j.out; STDERR=/data/my wd/a b %j.out" "/data/my wd/a b 11875.out"
}
# sq log opens the file by the path the job wrote it under, from its record as
# Slurm sent it (sq log's facts take no pass), and passes its bytes on as they
# are (Franz, 2026-10-24: "Leave the file as is"); its notes are outside text,
# so the path they show reads ␚ for a broken byte and loses a bidi control.
c_log_not_utf8() {
	T_TITLE="sq log: o_M\\xfcller.log and o_a+RLO+b.log opened and passed on byte for byte; the notes show o_M␚ller.log and o_ab.log: waiting for it to appear, never written"
	local nm shown fx late body='l\xfcne \xe2\x80\xae1\n'
	for nm in 'M\xfcller:M␚ller' 'a\xe2\x80\xaeb:ab'; do
		shown=${nm#*:} nm=${nm%%:*}
		fx=$(log_fx "now-$RANDOM" <<EOF
StateCompact=R; Name=$nm; STDOUT=\\{run}/wd/o_%x.log; STDERR=\\{run}/wd/o_%x.log
@file create wd/o_$nm.log $body
EOF
)
		sq_run "$fx" -- log --no-follow 500
		need "$nm: rc 0, no note, the file's bytes as they are" eval 'rc_is 0 && err_empty && cmp -s "$OUT" <(printf "$body")'
		sq_run "$(log_fx "end-$RANDOM" <<<"StateCompact=CD; Name=$nm; STDOUT=\\{run}/wd/o_%x.log; STDERR=\\{run}/wd/o_%x.log")" -- log 500
		need "$nm, ended, no file: rc 1, the path decoded" eval 'rc_is 1 && out_empty && err_is "sq log: job 500 ended; $(wd "o_$shown.log") was never written"'
	done
	sq_start "$(log_fx late <<'EOF'
@defaults Name=M\xfcller; STDOUT=\{run}/wd/o_%x.log; STDERR=\{run}/wd/o_%x.log
@step 1
StateCompact=R
@step 3
StateCompact=R
@file create wd/o_M\xfcller.log one\n
@step 4
StateCompact=CD; exit_code=0:0
EOF
)" -- log 500; late=$RUN
	sq_finish "$late"
	need "a file that appears late (after 10 s): waiting for o_M␚ller.log, then its content, then the end" eval 'rc_is 0 && out_is "one
" && err_is "sq log: waiting for $(wd o_M␚ller.log) to appear (job 500 runs on node01.cluster)
sq log: job 500 ended: COMPLETED (exit code 0:0)"'
}

c_log_stream() {   # L5, L7: a gone reader, a full disk, signals, SIGKILL
	T_TITLE="sq log's processes: | head -n 3 and > /dev/full end it, INT/TERM/HUP give 128+N, also during a poll, SIGKILL leaves nothing within a poll"
	local fx slow head full fullnow int term hup intpoll termpoll kill9 killpend
	fx=$(log_fx forever <<'EOF'
StateCompact=R
@file create wd/out_500.log l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n
EOF
)
	slow=$(log_fx slow <<'EOF'
StateCompact=R
@file create wd/out_500.log l1\n
@step 2
@hang 30
EOF
)
	SQOUT=head3 sq_start "$fx" -- log 500; head=$RUN
	SQOUT=full sq_start "$fx" -- log 500; full=$RUN
	SQOUT=full sq_start "$fx" -- log --no-follow 500; fullnow=$RUN
	sq_start "$fx" -- log 500; int=$RUN
	sq_start "$fx" -- log 500; term=$RUN
	sq_start "$fx" -- log 500; hup=$RUN
	sq_start "$slow" SQ_TIMEOUT=10 -- log 500; intpoll=$RUN
	sq_start "$slow" SQ_TIMEOUT=10 -- log 500; termpoll=$RUN
	sq_start "$fx" -- log 500; kill9=$RUN
	sq_start "$(log_fx pend <<<'StateCompact=PD; Reason=Priority')" -- log 500; killpend=$RUN
	local first="$(log_fx first <<<'@hang 30')" killfirst killnow pendnone
	sq_start "$(log_fx pendnone <<<'StateCompact=PD; Reason=None')" -- log 500; pendnone=$RUN

	streaming() { use_run "$1"; waits_for 20 grep -q l1 "$OUT"; }
	streaming "$int"  && kill -INT -- "-$SQ_PID"
	streaming "$term" && kill -TERM "$SQ_PID"
	streaming "$hup"  && kill -HUP "$SQ_PID"
	# the second call hangs: sq is waiting for its client when the signal comes
	# and it ends at once, not when the client is done or timed out (10 s)
	local prompt=
	use_run "$intpoll";  waits_for 20 eval '[ "$(stub_calls)" -ge 2 ]' && sleep 0.5 && kill -INT -- "-$SQ_PID" 2>/dev/null
	waits_for 3 eval '[ -s "$RUN/rc" ]' && prompt="$prompt int"
	use_run "$termpoll"; waits_for 20 eval '[ "$(stub_calls)" -ge 2 ]' && sleep 0.5 && kill -TERM "$SQ_PID" 2>/dev/null
	waits_for 3 eval '[ -s "$RUN/rc" ]' && prompt="$prompt term"
	streaming "$kill9" && kill -KILL "$SQ_PID"
	use_run "$killpend"; waits_for 20 eval '[ -s "$ERR" ]' && kill -KILL "$SQ_PID"
	# killed during the first call, before anything was said: its tmp goes too
	# (started only now, so the call still hangs when the kill comes)
	sq_start "$first" SQ_TIMEOUT=2 -- log 500; killfirst=$RUN
	sq_start "$first" SQ_TIMEOUT=2 -- log --no-follow 500; killnow=$RUN
	use_run "$killfirst"; waits_for 20 eval '[ "$(stub_calls)" -ge 1 ]' && sleep 0.3 && kill -KILL "$SQ_PID"
	use_run "$killnow";   waits_for 20 eval '[ "$(stub_calls)" -ge 1 ]' && sleep 0.3 && kill -KILL "$SQ_PID"
	use_run "$pendnone";  waits_for 20 eval '[ -s "$ERR" ]' && kill -TERM "$SQ_PID"

	sq_finish "$head" 20
	need "| head -n 3: rc 0, three lines, nothing left" eval 'rc_is 0 && out_is "l1
l2
l3
" && err_empty && nothing_at_exit'
	sq_finish "$full" 20
	need "> /dev/full: rc 1, tail's write error" eval 'rc_is 1 && err_is "sq log: tail: write error: No space left on device" && nothing_left'
	sq_finish "$fullnow" 20
	need "--no-follow > /dev/full: rc 1 too" eval 'rc_is 1 && err_is "sq log: tail: write error: No space left on device"'
	local r sig
	for r in int:130 term:143 hup:129 intpoll:130 termpoll:143; do
		sig=${r%%:*}; sq_finish "${!sig}" 20
		need "$sig: rc ${r#*:}, nothing left when sq returned, its tmp gone" eval 'rc_is ${r#*:} && nothing_at_exit && [ -z "$(ls -A "$RUN/tmp")" ]'
	done
	need "intpoll/termpoll: sq ended within 3 s of the signal" eval '[ "$prompt" = " int term" ]'
	need "intpoll/termpoll: the hanging client was ended too" eval 'use_run "$intpoll"; nothing_left && use_run "$termpoll" && nothing_left'
	sq_finish "$pendnone" 20
	need "pending with Reason None: no parenthesis" eval 'rc_is 143 && err_is "sq log: job 500 is pending; waiting for it to start"'
	for r in kill9 killpend killfirst killnow; do
		sq_finish "${!r}" 20
		need "$r: SIGKILL, rc 137, tmp removed by the sentinel within 3 s, nothing left within a poll" eval 'rc_is 137 && waits_for 3 eval "[ -z \"\$(ls -A \"\$RUN/tmp\")\" ]" && waits_for 6 nothing_left'
	done
}

# ============================================================================
# sq job JOBID (SQJOB-v3)
# ============================================================================
# Franz (2026-10-20): grouped sections, the efficiency as the compact bar
# lines; peak memory "Largest step total"; arrays "One summary line" over
# "COMPLETED tasks only"; running "Memory only, say so"; CPU "The larger of
# both"; the RSS date "Setting, off by default"; r2's screens "Accept as
# rendered"; v3: an own running job's memory is JOBMEM's reading (no "peak so
# far"), no "(whole cores)", "between two samples".  The pinned screens are
# r2's (and r1's pending dependency) with those three changes.  Fixtures date
# everything relative to the run (\{epoch...}, every age shown mid-bucket),
# the screens' dates are masked, and SQ_PSS_SINCE is the switch 27h56m before
# the run, as r2 had it (2026-10-19 15:59 CEST, rendered 2026-10-20 17:55 UTC).
jfx=$fixtures/sqjob
pss_ago=100560
job_run() {   # job_run FIXTURE [VAR=value | -VAR]... -- [sq args]: sq_run as fsill, the PSS switch set
	local fx=$1; shift
	[[ $fx == /* ]] || fx=$jfx/$fx
	sq_run "$fx" SQSTUB_UID=1041 SQ_PSS_SINCE=@$(( $(epoch_now) - pss_ago )) "$@"
}
job_mask() { sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}/<date>/g' "$1"; }   # the dates, as without_clock the clock
job_is() { cmp -s <(job_mask "$1") <(job_mask "$OUT"); }   # job_is FILE: stdout is FILE, dates aside
# stdout with the run's own directory left out, which the paths of a fixture
# whose output files sq reads begin with (\{run}/media/...)
unrooted() { RUNDIR=$RUN gawk '{ while ((i = index($0, ENVIRON["RUNDIR"] "/"))) $0 = substr($0, 1, i - 1) substr($0, i + length(ENVIRON["RUNDIR"])); print }' "$OUT"; }
# screen_is FILE: stdout is the pinned screen FILE, dates aside and unrooted;
# with --pin it becomes FILE
screen_is() {
	if [ $pin = 1 ]; then unrooted > "$1"; return 0; fi
	cmp -s <(job_mask "$1") <(unrooted | job_mask /dev/stdin)
}
# job_fx NAME FILE: fixture NAME's FILE is stdin, a squeue-all after
# job-defaults, a sacct after job-sacct-defaults; until given, squeue-all
# forgot the job, sacct answers nothing and getent knows no user.  Prints
# its directory
job_fx() {
	local d=$T_DIR/fx-$1
	mkdir -p "$d"
	case $2 in
		squeue-all) { printf '@include %s\n' "$fixtures/_common/job-defaults"; cat; } > "$d/$2" ;;
		sacct)      { printf '@include %s\n' "$fixtures/_common/job-sacct-defaults"; cat; } > "$d/$2" ;;
		*)          cat > "$d/$2" ;;
	esac
	[ -f "$d/squeue-all" ] || printf '@stderr slurm_load_jobs error: Invalid job id specified\n@exit 1\n' > "$d/squeue-all"
	[ -f "$d/sacct" ] || : > "$d/sacct"
	[ -f "$d/passwd" ] || printf '# no user known\n' > "$d/passwd"
	printf '%s' "$d"
}
kv_is() {     # kv_is KEY VALUE: a line of the report is KEY, then VALUE after the key column
	plain | K=$1 V=$2 gawk '{ k = ENVIRON["K"]; if (index($0, "  " k "  ") != 1) next
		v = substr($0, length(k) + 3); sub(/^ +/, "", v); if (v == ENVIRON["V"]) f = 1 } END { exit !f }'
}
title_is() { [ "$(plain | head -n 1)" = "$1" ]; }
notes_raw() { plain | gawk '/^ *↳ / { sub(/^ *↳ /, ""); print }'; }   # every ↳ line, in order
notes() { notes_raw | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}/<date>/g'; }   # the same, dates masked
notes_are() { [ "$(notes)" = "$(printf '%s\n' "$@")" ]; }   # notes_are TEXT...: exactly these, in this order (dates <date>)
alloc_calls() { gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && (" " $3) ~ / -u / { n++ } END { print n+0 }' "$LOG"; }   # JOBMEM's

c_job_screens() {   # Q2, Q3, acceptance 1
	T_TITLE="the accepted sq job screens byte for byte, dates aside: r2's 12 with v3's three changes and r1's pending dependency, colour on and off; why-v2's days and why sections (array, oom, pending-dep, pending-est, timeout)"
	local c ext flag
	local -A id=([pending-est]=11962 [pending-dep]=11961 [running-own]=11950 [running-other]=11960 [finished-11912]=11912
		[oom-11818]=11818 [oom-11818-nopss]=11818 [twotask-11584]=11584 [idle-11898]=11898
		[arraytask-11367_211]=11367_211 [array-11367]=11367 [timeout-11191]=11191 [exclusive-10866]=10866)
	for c in finished-11912 twotask-11584 oom-11818 oom-11818-nopss idle-11898 running-own running-other pending-est \
	         pending-dep arraytask-11367_211 array-11367 timeout-11191 exclusive-10866; do
		for flag in --color --no-color; do
			ext=ansi; [ $flag = --color ] || ext=txt
			if [ $c = oom-11818-nopss ]; then job_run oom-11818 -SQ_PSS_SINCE -- $flag job "${id[$c]}"
			else job_run $c -- $flag job "${id[$c]}"; fi
			need "$c $flag: rc 0, stderr empty, the accepted screen" eval 'rc_is 0 && err_empty && screen_is "$jfx/screens/job__$c.$ext"'
		done
	done
	local cache=$T_DIR/cache; mkdir -p "$cache"
	job_run running-own XDG_CACHE_HOME="$cache" -- --no-color job 11950
	need "running-own: JOBMEM's allocation call and one sstat for fsill's running jobs, its snapshot written" eval '
		rc_is 0 && [ "$(alloc_calls)" = 1 ] && argv_has squeue -h -u 1041 && [ "$(calls sstat)" = 1 ] &&
		argv_has sstat -n -p -a --noconvert -j 11950 -o JobID,TRESUsageInTot && [ -s "$cache/sq/memuse" ]'
	# dated 10 s back: WSL steps its clock back about 1.5 s every 30 s, and a
	# snapshot a second "from the future" is a call
	sed -i "1s/.*/$(( $(epoch_now) - 10 ))/" "$cache/sq/memuse" 2>/dev/null
	job_run running-own XDG_CACHE_HOME="$cache" -- --no-color job 11950
	need "running-own again within 30 s: the snapshot's reading, no JOBMEM call, the same screen" eval '
		rc_is 0 && [ "$(alloc_calls)" = 0 ] && [ "$(calls sstat)" = 0 ] && job_is "$jfx/screens/job__running-own.txt"'
}
c_job_contract() {   # Q0
	T_TITLE="sq job's calls: SQUEUE_*/SACCT_* unset, %s and 0 pinned, formats framed; cluster refusals; usage errors; het refused; a gone reader, a full disk, signals"
	local n n2 want f sig rc fx
	job_run finished-11912 -- --no-color job 11912
	want=$T_DIR/want; cp "$OUT" "$want"
	need "plain: rc 0, stderr empty" eval 'rc_is 0 && err_empty'
	job_run finished-11912 SQUEUE_USERS=nobody SQUEUE_PARTITION=x SQUEUE_SORT=bogus SQUEUE_FORMAT=%i SQUEUE_STATES=PD \
		SACCT_FORMAT=JobID SACCT_FEDERATION=1 SACCT_LOCAL=1 SLURM_TIME_FORMAT=relative SLURM_BITSTR_LEN=5 -- --no-color job 11912
	need "inherited SQUEUE_*, SACCT_*, time and bitstring formats: rc 0, the same report" eval 'rc_is 0 && err_empty && job_is "$want"'
	need "no call saw an SQUEUE_* but the SQUEUE_FORMAT2 sq set, nor any SACCT_*" eval 'only_format2 && ! grep "^CALL" "$LOG" | grep -q "SACCT_"'
	need "every call: SLURM_TIME_FORMAT=%s, SLURM_BITSTR_LEN=0" eval 'all_calls_env SLURM_TIME_FORMAT %s squeue sacct && all_calls_env SLURM_BITSTR_LEN 0 squeue sacct'
	n=$(env_of squeue 1 SQ_NONCE) n2=$(env_of sacct 1 SQ_NONCE2)
	need "squeue -h --jobs=11912 -t all: sq log's 17 fields and 12 more in SQUEUE_FORMAT2, each ending in the queue nonce, which no command line carries" eval '
		argv_has squeue -h --jobs=11912 -t all && [ "$(env_of squeue 1 SQUEUE_FORMAT)" = "(unset)" ] &&
		[ "$(env_of squeue 1 SQUEUE_FORMAT2)" = "$(for f in JobID ArrayJobID ArrayTaskID HetJobID HetJobOffset StateCompact RestartCnt BatchFlag BatchHost WorkDir STDOUT STDERR UserName Name StartTime Reason exit_code Partition SubmitTime EndTime TimeLimit TimeLeft TimeUsed Dependency NumCPUs NumNodes tres-alloc NodeList UserID; do printf "%s:%s," "$f" "$n"; done | sed "s/,\$//")" ] &&
		! grep "^CALL" "$LOG" | cut -f3 | grep -qF "$n"'
	need "sacct -p --delimiter=<a nonce of its own> -n --noconvert -a -j 11912 -o the 24 fields (TimelimitRaw and FailedNode for the why section), never -X or -D" eval '
		argv_has sacct -p "--delimiter=$n2" -n --noconvert -a -j 11912 -o JobID,JobIDRaw,UID,User,State,ExitCode,ElapsedRaw,AllocCPUS,ReqCPUS,ReqTRES,AllocTRES,TotalCPU,TRESUsageInTot,TRESUsageInMax,NTasks,Submit,Start,End,NodeList,Partition,WorkDir,TimelimitRaw,FailedNode,JobName &&
		argv_lacks sacct -X && argv_lacks sacct -D && [ "$n2" != "$n" ]'
	need "one squeue and one sacct call, no sstat (not a running job)" eval '[ "$(calls squeue)" = 1 ] && [ "$(calls sacct)" = 1 ] && [ "$(calls sstat)" = 0 ]'
	job_run finished-11912 SQ_FMT=bogus%% SQ_CENTER=x SQ_COMPACT=7 SQ_RECENT_MAX=-1 -- --no-color job -- 11912
	need "a dashboard setting neither applied nor validated; -- before the id: the same report" eval 'rc_is 0 && err_empty && job_is "$want"'
	job_run finished-11912 -- --me --no-bell --full --no-color job 11912
	need "valueless dashboard flags before job: the same report" eval 'rc_is 0 && job_is "$want"'
	# refused before any call
	sub_refused "sq job: sq job reads this cluster only; drop -M" -M other job 11912
	sub_refused "sq job: sq job reads this cluster only; drop --clusters" --clusters=other job 11912
	sub_refused "sq job: sq job reads this cluster only; drop --federation" --federation job 11912
	sub_refused "sq job: sq job reads this cluster only; drop --sibling" --sibling -p main job 11912
	for f in other ""; do
		sq_run empty SLURM_CLUSTERS="$f" -- job 11912
		need "SLURM_CLUSTERS='$f': rc 2, refused, no call" eval 'rc_is 2 && out_empty && no_slurm_call && err_is "sq job: sq job reads this cluster only; unset SLURM_CLUSTERS"'
	done
	sub_refused "sq: subcommands come first, before any option that takes a value: sq job …" -p main job 11912
	sub_refused "sq job: which job? e.g. sq job 12345" job
	sub_refused "sq job: one job at a time, not '1' and '2'; e.g. sq job 12345" job 1 2
	sub_refused "sq job: '-x' is not an option of sq job (sq job -h); e.g. sq job 12345" job -x 1
	sub_refused "sq job: --help takes no value; write it on its own, e.g. sq job --help 12345" job --help=x
	sub_refused "sq job: --color takes no value; write it on its own, e.g. sq job --color 12345" job --color=always 11912
	# --color and --no-color after job, as before it
	job_run finished-11912 -- job --no-color 11912
	need "sq job --no-color ID: the report sq --no-color job ID gives" eval 'rc_is 0 && err_empty && job_is "$want"'
	job_run finished-11912 -- --no-color job 11912 --color
	need "sq --no-color job ID --color: the last one wins, colour" eval 'rc_is 0 && job_is "$jfx/screens/job__finished-11912.ansi"'
	job_run finished-11912 -- job --colour -- 11912
	need "sq job --colour -- ID: colour" eval 'rc_is 0 && job_is "$jfx/screens/job__finished-11912.ansi"'
	for f in abc 0 00 4294967294 1_99999999 1_4000001 1+ 12_3+1 '' -1; do
		sub_refused "sq job: '$f' is not a job id; e.g. sq job 12345, an array task 12345_4 or an array 12345" job -- "$f"
	done
	sq_run empty -- job -h
	need "sq job -h: rc 0, its help on stdout, no Slurm call" eval 'rc_is 0 && has "usage: sq job [--color|--no-color] JOBID" && has "SQ_PSS_SINCE" && err_empty && no_slurm_call'
	sq_run empty -- -h
	need "sq -h names it" has "sq job JOBID"
	sq_run empty -- job 10646+1
	need "a het component typed: rc 1, refused, no call" eval 'rc_is 1 && out_empty && no_slurm_call && err_is "sq job: het jobs are not supported yet"'
	# the report's reader gone before it is written: quietly 0; a full disk: 1
	fx=$jfx/finished-11912
	sq_env "$fx" SQSTUB_UID=1041 -- job 11912
	env -i "${ENVLIST[@]}" "$bound" -k 2 30 "$sq" "${SQ_ARGV[@]}" 2> "$ERR" < /dev/null | true; RC=${PIPESTATUS[0]}; note_run
	need "| true (its reader gone): rc 0, stderr empty" eval 'rc_is 0 && err_empty'
	sq_env "$fx" SQSTUB_UID=1041 -- job 11912
	env -i "${ENVLIST[@]}" "$bound" -k 2 30 "$sq" "${SQ_ARGV[@]}" > /dev/full 2> "$ERR" < /dev/null; RC=$?; note_run
	need "> /dev/full: rc 1, says why" eval 'rc_is 1 && err_is "sq job: cannot write the report: No space left on device"'
	# a signal while Slurm is asked: 128+N, nothing left
	fx=$(job_fx hang squeue-all <<<'@hang 20')
	for sig in INT:130 TERM:143 HUP:129; do
		sq_start "$fx" SQSTUB_UID=1041 SQ_TIMEOUT=25 -- job 11912
		waits_for 10 eval 'grep -q "^CALL	squeue" "$LOG"'
		sleep 0.3; kill -"${sig%:*}" "$SQ_PID" 2>/dev/null
		sq_finish "$RUN" 20
		need "SIG${sig%:*} during squeue: rc ${sig#*:}, nothing left, the tmp dir gone" eval 'rc_is '"${sig#*:}"' && nothing_at_exit && waits_for 3 nothing_left && [ -z "$(ls -A "$RUN/tmp")" ]'
	done
	# killed outright, during squeue's call, sacct's, and JOBMEM's sstat: no
	# EXIT cleanup, so the sentinel ends the call in flight within a tick (its
	# budget, 25 s, is far off) and removes the tmp dir
	local own=$T_DIR/fx-killown f9
	mkdir -p "$own"; cp "$jfx/running-own"/* "$own/"; printf '@hang 30\n' > "$own/sstat"
	for f9 in "$fx:squeue" "$(job_fx hangacct sacct <<<'@hang 30'):sacct" "$own:sstat"; do
		sq_start "${f9%:*}" SQSTUB_UID=1041 SQ_TIMEOUT=25 -- job "$([ "${f9##*:}" = sstat ] && echo 11950 || echo 11912)"
		waits_for 10 eval 'grep -q "^CALL	${f9##*:}" "$LOG"'
		sleep 0.3; kill -KILL "$SQ_PID" 2>/dev/null
		need "SIGKILL during ${f9##*:}: within 3 s the tmp dir gone and nothing left of the call" eval '
			waits_for 3 eval "[ -z \"\$(ls -A \"\$RUN/tmp\")\" ]" && waits_for 3 nothing_left'
		sq_finish "$RUN" 10
	done
}
c_job_select() {   # Q1
	T_TITLE="which job: a task by its array id, by its unique id, one still in a pending array, an array cancelled pending, het jobs, an unknown one, a one-task array; own by squeue's uid, else accounting's"
	local d
	d=$(job_fx task squeue-all <<'EOF'
JobID=11955; ArrayJobID=11367; ArrayTaskID=212; StateCompact=R; UserName=hal; UserID=1033; Name=sweep; tres_alloc=cpu=2,mem=15600M,node=1,billing=2; TimeUsed=1:00:00; TimeLeft=UNLIMITED; TimeLimit=UNLIMITED; STDOUT=/w/sweep_%A_%a.out; STDERR=/w/sweep_%A_%a.out; EndTime=N/A
EOF
)
	job_run "$d" -- --no-color job 11367_212
	need "N_T running, from squeue alone: rc 0, its unique id in the title, %A_%a in its path, accounting's silence noted nowhere" eval '
		rc_is 0 && err_empty && title_is "▌ 11367_212 (unique id 11955)  sweep · hal" && kv_is state "RUNNING on fb2-bioinf (LocalQ)" &&
		kv_is stdout /w/sweep_11367_212.out && kv_is stderr "into stdout" && [ -z "$(notes)" ]'
	need "... asked as --jobs=11367_212 and -j 11367_212" eval 'argv_has squeue -h --jobs=11367_212 -t all && argv_has sacct -j 11367_212'
	job_run rawid-11559 -- --no-color job 11559
	need "a task by its unique id (11559, real rows): rc 0, that task, the id in its title, no note about it" eval '
		rc_is 0 && err_empty && title_is "▌ 11367_230 (unique id 11559)  j · hal" && kv_is state "COMPLETED · exit 0" && ! notes | grep -q 11559'
	d=$(job_fx meta squeue-all <<'EOF'
JobID=11367; ArrayJobID=11367; ArrayTaskID=215-216%5; StateCompact=PD; Reason=JobArrayTaskLimit; UserName=hal; UserID=1033; Name=sweep; NumCPUs=1; tres_alloc=cpu=1,mem=7800M,node=1,billing=1; TimeLimit=UNLIMITED; TimeLeft=UNLIMITED; TimeUsed=0:00; StartTime=N/A; EndTime=N/A; NodeList=; BatchHost=; STDOUT=/w/slurm-11367.out; STDERR=/w/slurm-11367.out
EOF
)
	job_run "$d" -- --no-color job 11367_216
	need "a task still in a pending array's record: rc 0, that task without a unique id, the record's reason, its own default path" eval '
		rc_is 0 && err_empty && title_is "▌ 11367_216  sweep · hal" && kv_is state "PENDING (JobArrayTaskLimit)" &&
		kv_is CPUs "1 requested" && kv_is memory "7.6G requested" && kv_is "time limit" none && kv_is stdout /w/slurm-11367_216.out'
	job_run "$d" -- --no-color job 11367_217
	need "a task outside that record: rc 1, unknown" eval 'rc_is 1 && out_empty && err_is "sq job: Slurm does not know job 11367_217 (neither the queue nor accounting has it)"'
	job_run pdarray-10251 -- --no-color job 10251_2
	need "a task of a pending array, cancelled and purged (10251, real rows): rc 1, as an unknown job" eval '
		rc_is 1 && out_empty && err_is "sq job: Slurm does not know job 10251_2 (neither the queue nor accounting has it)"'
	job_run pdarray-10251 -- --no-color job 10251
	need "that array: its 4 tasks cancelled, not pending (the attack's 10251 finding)" eval '
		rc_is 0 && title_is "▌ 10251  j · hal · array of 4: 4 cancelled" && notes_are "no task has completed yet"'
	job_run het-10646 -- --no-color job 10646
	need "a het job's leader (10646, real rows): rc 1, refused" eval 'rc_is 1 && out_empty && err_is "sq job: het jobs are not supported yet"'
	d=$(job_fx hetq squeue-all <<<'JobID=901; ArrayJobID=901; HetJobID=900; HetJobOffset=1; StateCompact=R')
	job_run "$d" -- --no-color job 901
	need "a het component squeue knows: rc 1, refused" eval 'rc_is 1 && out_empty && err_is "sq job: het jobs are not supported yet"'
	d=$(job_fx unknown sacct < /dev/null)
	job_run "$d" -- --no-color job 99
	need "known to neither: rc 1" eval 'rc_is 1 && out_empty && err_is "sq job: Slurm does not know job 99 (neither the queue nor accounting has it)"'
	d=$(job_fx one sacct <<'EOF'
JobID=600_0; JobIDRaw=600; TotalCPU=15:00.000
JobID=600_0.batch; JobIDRaw=600.batch; UID=; User=; TotalCPU=15:00.000; TRESUsageInTot=cpu=00:15:00,mem=1073741824; TRESUsageInMax=cpu=00:15:00,mem=1073741824; NTasks=1
EOF
)
	job_run "$d" -- --no-color job 600
	need "an array of one task: the array view" eval '
		rc_is 0 && title_is "▌ 600  job · alice · array of 1: 1 done" &&
		has "  CPU ████▒▒▒▒▒▒▒▒▒▒▒▒  25.0%  median · min 25.0% (600_0) · max 25.0%" && notes_are "over the 1 completed task; the weakest: sq job 600_0"'
	# own: squeue's uid, else accounting's
	d=$jfx/running-own
	job_run "$d" -- --no-color job 11950
	need "squeue's UserID 1041 is fsill's: the MEM line" has "12/64G now"
	mkdir -p "$T_DIR/fx-other"; cp "$d"/* "$T_DIR/fx-other/"; sed -i 's/UserID=1041/UserID=1033/' "$T_DIR/fx-other/squeue-all"
	job_run "$T_DIR/fx-other" -- --no-color job 11950
	need "squeue's UserID another's, accounting's fsill's: squeue wins, not own" eval 'rc_is 0 && lacks "efficiency" && kv_is memory "64G allocated · its use is shown to fsill only" && [ "$(calls sstat)" = 0 ]'
	printf '@stderr slurm_load_jobs error: Unable to contact slurm controller (connect failure)\n@exit 1\n' > "$T_DIR/fx-other/squeue-all"
	sed -i 's/UID=1041/UID=1033/' "$T_DIR/fx-other/sacct"
	job_run "$T_DIR/fx-other" -- --no-color job 11950
	need "squeue down, accounting's UID another's: not own" eval 'rc_is 0 && lacks "efficiency" && has "its use is shown to fsill only"'
	sed -i 's/UID=1033/UID=1041/' "$T_DIR/fx-other/sacct"
	job_run "$T_DIR/fx-other" -- --no-color job 11950
	need "squeue down, accounting's UID fsill's: own, its MEM line (the allocation call answers apart)" has "12/64G now"
}
c_job_branches() {   # Q2, Q3
	T_TITLE="the report's branches: over 100 %, never started (real rows and cancelled pending), squeue ended before accounting, stopped, interactive, no steps, the cap while running, an array with none completed, NODE_FAIL's node"
	local d
	d=$(job_fx over sacct <<'EOF'
JobID=800; TotalCPU=30:00.000
JobID=800.batch; JobIDRaw=800.batch; UID=; User=; TotalCPU=30:00.000; TRESUsageInTot=cpu=00:30:00,mem=5368709120; TRESUsageInMax=cpu=00:30:00,mem=5368709120; NTasks=1
EOF
)
	job_run "$d" -- --color job 800
	need "over its allocation: 125.0 % as is, the bar full and bold red, the figure uncoloured" eval '
		rc_is 0 && has "  MEM ████████████████ 125.0%  5/4G peak (the batch script)" &&
		[ "$(LC_ALL=C grep -o "$ESC\[1;31m█" "$OUT" | wc -l)" = 16 ] && has "  CPU ████████▒▒▒▒▒▒▒▒  50.0%  30m00s of 1h00m"'
	# a killed srun step of two tasks: neither TotalCPU (its tasks never
	# reaped) nor the busier task's polled cpu (TRESUsageInMax) holds the
	# step's CPU time, only TRESUsageInTot's sum of both tasks does
	d=$(job_fx totcpu sacct <<'EOF'
JobID=800; State=CANCELLED by 1050; ExitCode=0:15
JobID=800.batch; JobIDRaw=800.batch; UID=; User=; State=CANCELLED; ExitCode=0:15; TotalCPU=00:00.100; TRESUsageInTot=cpu=00:00:00,mem=10485760; TRESUsageInMax=cpu=00:00:00,mem=10485760; NTasks=1
JobID=800.0; JobIDRaw=800.0; UID=; User=; State=CANCELLED; ExitCode=0:15; TotalCPU=00:00.010; TRESUsageInTot=cpu=00:30:00,mem=1073741824; TRESUsageInMax=cpu=00:15:00,mem=536870912; NTasks=2
EOF
)
	job_run "$d" -- --no-color job 800
	need "a killed two-task step: its CPU from TRESUsageInTot (30 min), which beats TotalCPU and TRESUsageInMax (15 min), and the polled note" eval '
		rc_is 0 && has "  CPU ████████▒▒▒▒▒▒▒▒  50.0%  30m00s of 1h00m" && notes | grep -qxF "CPU time includes processes Slurm killed or never waited for (polled between two samples, so still a lower bound)"'
	job_run neverstarted-10195 -- --no-color job 10195
	need "never started (10195, real rows): no node, no ran line, the request, 'it never started', no bars" eval '
		rc_is 0 && err_empty && kv_is state "FAILED · exit 1" && ! kv_is ran "0s on None assigned (LocalQ)" && lacks "  ran " &&
		kv_is CPUs "1 requested" && kv_is memory "1.9T requested" && notes_are "it never started" && ! matches "^  (CPU|MEM) "'
	d=$(job_fx cxl sacct <<<'JobID=800; State=CANCELLED by 1050; AllocCPUS=0; AllocTRES=; ElapsedRaw=0; Start=None; NodeList=None assigned')
	job_run "$d" -- --no-color job 800
	need "cancelled while pending (Start None): the same" eval '
		rc_is 0 && kv_is state "CANCELLED · exit 0" && lacks "  ran " && kv_is CPUs "2 requested" && kv_is memory "4G requested" && notes_are "it never started"'
	d=$(job_fx lag squeue-all <<<'JobID=800'); job_fx lag sacct <<<'JobID=800; State=RUNNING; End=Unknown; ElapsedRaw=1200' > /dev/null
	job_run "$d" -- --no-color job 800
	need "squeue says COMPLETED, accounting still RUNNING: squeue's state and times, efficiency only that accounting has no end yet" eval '
		rc_is 0 && kv_is state "COMPLETED · exit 0" && kv_is ran "30m00s on fb2-bioinf (LocalQ)" && matches "^  ended +.* \(15m ago\)$" &&
		notes_are "accounting has not recorded its end yet" && ! matches "^  (CPU|MEM) "'
	# ST, squeue's StateCompact for STOPPED, once lost from the table of names
	d=$(job_fx stopped squeue-all <<<'JobID=800; StateCompact=ST; EndTime=N/A'); job_fx stopped sacct <<<'JobID=800; State=STOPPED; End=Unknown' > /dev/null
	job_run "$d" -- --no-color job 800
	need "a stopped job (ST): its state is STOPPED" eval 'rc_is 0 && err_empty && kv_is state "STOPPED on fb2-bioinf (LocalQ)"'
	d=$(job_fx interactive squeue-all <<<'JobID=800; BatchFlag=0'); job_fx interactive sacct <<<'JobID=800' > /dev/null
	job_run "$d" -- --no-color job 800
	need "an interactive job: its output went to its terminal" eval 'rc_is 0 && kv_is output "its terminal (an interactive job)" && lacks "stdout"'
	d=$(job_fx nosteps sacct <<<'JobID=800; TotalCPU=30:00')
	job_run "$d" -- --no-color job 800
	need "no step rows: the job row's TotalCPU, no MEM line" eval '
		rc_is 0 && has "  CPU ████████▒▒▒▒▒▒▒▒  50.0%  30m00s of 1h00m" && ! matches "^  MEM "'
	d=$(job_fx capr squeue-all <<<'JobID=800; StateCompact=R; EndTime=N/A'); job_fx capr sacct <<<'JobID=800; State=RUNNING; ReqCPUS=1; End=Unknown' > /dev/null
	job_run "$d" -- --no-color job 800
	need "another's running job given more CPUs than asked: the cap note under resources, under the values; no efficiency" eval '
		rc_is 0 && kv_is CPUs "2 allocated (1 requested)" && plain | grep -qxF "            ↳ 1 requested CPU became 2: a program running 1 thread reaches at most 50%" &&
		lacks efficiency && kv_is memory "4G allocated · its use is shown to alice only"'
	d=$(job_fx nonedone squeue-all <<<'JobID=700; ArrayJobID=700; ArrayTaskID=0-3; StateCompact=PD; Reason=Dependency; NodeList=; EndTime=N/A')
	job_fx nonedone sacct <<<'JobID=700_[0-3]; JobIDRaw=700; State=PENDING; AllocCPUS=0; ElapsedRaw=0; Start=Unknown; End=Unknown' > /dev/null
	job_run "$d" -- --no-color job 700
	need "an array with no task completed: the counts, the pending reason, no bars" eval '
		rc_is 0 && title_is "▌ 700  job · alice · array of 4: 4 pending" && notes_are "no task has completed yet; pending (Dependency)" && ! matches "^  (CPU|MEM) "'
	# W4/V6: a NODE_FAIL job's state line names the node it lost, not the
	# signal of a step Slurm killed with it
	d=$(job_fx nf sacct <<'EOF'
JobID=800; State=NODE_FAIL; ExitCode=1:0; FailedNode=fb2-bioinf-0; NodeList=fb2-bioinf-0
JobID=800.extern; JobIDRaw=800.extern; UID=; User=; State=CANCELLED; ExitCode=0:9; FailedNode=
JobID=800.0; JobIDRaw=800.0; UID=; User=; State=CANCELLED; ExitCode=0:9; FailedNode=
EOF
)
	job_run "$d" -- --no-color job 800
	need "NODE_FAIL from accounting: 'NODE_FAIL on' its FailedNode, no signal" eval 'rc_is 0 && kv_is state "NODE_FAIL on fb2-bioinf-0" && lacks "sig9"'
	sed -i 's/FailedNode=fb2-bioinf-0; NodeList=fb2-bioinf-0/FailedNode=; NodeList=fb2-bioinf-0/' "$d/sacct"
	job_run "$d" -- --no-color job 800
	need "... FailedNode empty: its NodeList" eval 'rc_is 0 && kv_is state "NODE_FAIL on fb2-bioinf-0"'
	d=$(job_fx nfq squeue-all <<<'JobID=800; StateCompact=NF; exit_code=0:1; NodeList=fb2-bioinf-0; BatchFlag=0')
	job_run "$d" -- --no-color job 800
	need "... from squeue alone: its NodeList" eval 'rc_is 0 && kv_is state "NODE_FAIL on fb2-bioinf-0"'
}
c_job_own() {   # Q2: an own running job's memory is JOBMEM's
	T_TITLE="an own running job's MEM line is JOBMEM's reading: a fresh snapshot is used (no sstat, no allocation call), a stale one renewed for all own jobs in the dashboard's format; ? and !; the dashboard after sq job calls nothing"
	local d=$T_DIR/fx-own f cache=$T_DIR/cacheA cache2=$T_DIR/cacheB first
	mkdir -p "$d" "$cache/sq" "$cache2/sq"
	for f in sinfo squeue squeue-alloc squeue-tres sstat; do printf '@include %s\n' "$fixtures/jobmem/$f" > "$d/$f"; done
	{ printf '@include %s\n' "$fixtures/_common/job-defaults"
	  echo 'JobID=11898; ArrayJobID=11898; StateCompact=R; UserName=fsill; UserID=1041; Name=kraken2; NumCPUs=8; tres_alloc=cpu=8,mem=32G,node=1,billing=8; TimeUsed=2:03:19; TimeLeft=9:56:41; TimeLimit=12:00:00; StartTime=\{epoch-2h03m30s}; EndTime=N/A'; } > "$d/squeue-all"
	{ printf '@include %s\n' "$fixtures/_common/job-sacct-defaults"
	  echo 'JobID=11898; JobIDRaw=11898; UID=1041; User=fsill; State=RUNNING; ElapsedRaw=7399; Elapsed=02:03:19; AllocCPUS=8; ReqCPUS=8; ReqTRES=billing=8,cpu=8,mem=32G,node=1; AllocTRES=billing=8,cpu=8,mem=32G,node=1; Start=\{epoch-2h03m30s}; End=Unknown; JobName=kraken2'; } > "$d/sacct"
	snap_of() { printf '%s/sq/memuse' "$1"; }
	# age CACHE SECONDS: the snapshot dated that far back.  A fresh one is
	# dated 10 s back before it is relied on: WSL steps its clock back about
	# 1.5 s every 30 s, and a snapshot a second "from the future" is a call
	age() { sed -i "1s/.*/$(( $(epoch_now) - $2 ))/" "$(snap_of "$1")" 2>/dev/null; }
	# the dashboard first, then sq job within 30 s, then the dashboard again
	mem_run "$d" SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
	need "the dashboard: rc 0, one allocation call, one sstat, the snapshot written" eval 'rc_is 0 && [ "$(alloc_calls)" = 1 ] && [ "$(calls sstat)" = 1 ] && [ -s "$(snap_of "$cache")" ]'
	first=$RUN/first; without_clock "$OUT" > "$first"; age "$cache" 10; cp "$(snap_of "$cache")" "$T_DIR/dash.memuse"
	job_run "$d" XDG_CACHE_HOME="$cache" -- --color job 11898
	need "sq job within 30 s: rc 0, no sstat, no allocation call, the snapshot's reading: 31/32G, red as JOBMEM colours 96.8 %" eval '
		rc_is 0 && err_empty && [ "$(calls sstat)" = 0 ] && [ "$(alloc_calls)" = 0 ] &&
		has "  MEM ███████████████▒  96.8%  31/32G now" && LC_ALL=C grep -q "$ESC\[31m█" "$OUT" && notes_are "CPU efficiency comes when the job ends"'
	need "... and the snapshot left as the dashboard wrote it" cmp -s "$(snap_of "$cache")" "$T_DIR/dash.memuse"
	age "$cache" 10
	mem_run "$d" SQ_WIDTH=110 XDG_CACHE_HOME="$cache" -- --color
	need "the dashboard after it: rc 0, no sstat, the same screen" eval 'rc_is 0 && [ "$(calls sstat)" = 0 ] && cmp -s "$first" <(without_clock "$OUT")'
	# sq job first: it renews the snapshot for all of fsill's running jobs, as the dashboard would
	job_run "$d" XDG_CACHE_HOME="$cache2" -- --color job 11898
	need "sq job with no snapshot: the allocation call (squeue -h -u 1041), one sstat for all 8 running jobs, the reading shown" eval '
		rc_is 0 && err_empty && [ "$(alloc_calls)" = 1 ] && argv_has squeue -h -u 1041 &&
		[ "$(calls sstat)" = 1 ] && argv_has sstat -n -p -a --noconvert -j 11895,11898,11902,11903,11904,11905,11906,11908 -o JobID,TRESUsageInTot &&
		has "96.8%  31/32G now"'
	need "... the snapshot in the dashboard's format: an epoch, then the same job lines" eval '
		head -n 1 "$(snap_of "$cache2")" 2>/dev/null | grep -qxE "[0-9]+" && cmp -s <(tail -n +2 "$(snap_of "$cache2")") <(tail -n +2 "$T_DIR/dash.memuse") &&
		[ "$(ls -A "$cache2/sq")" = memuse ]'
	age "$cache2" 10
	mem_run "$d" SQ_WIDTH=110 XDG_CACHE_HOME="$cache2" -- --color
	need "the dashboard within 30 s of that sq job: no sstat, the dashboard's screen" eval 'rc_is 0 && [ "$(calls sstat)" = 0 ] && cmp -s "$first" <(without_clock "$OUT")'
	age "$cache2" 40
	job_run "$d" XDG_CACHE_HOME="$cache2" -- --color job 11898
	need "a snapshot 40 s old: renewed, one allocation call and one sstat" eval '
		rc_is 0 && [ "$(alloc_calls)" = 1 ] && [ "$(calls sstat)" = 1 ] && [ "$(head -n 1 "$(snap_of "$cache2")" 2>/dev/null)" -ge "$(( $(epoch_now) - 10 ))" ] 2>/dev/null'
	# ? and !, as JOBMEM marks them
	grep -v '^11898	' "$T_DIR/dash.memuse" > "$(snap_of "$cache2")"; age "$cache2" 10
	job_run "$d" XDG_CACHE_HOME="$cache2" -- --color job 11898
	need "not in a fresh snapshot (started since): a dim ?, the use not known, no call" eval '
		rc_is 0 && [ "$(calls sstat)" = 0 ] && has "  MEM ················         ?/32G now" && LC_ALL=C grep -qF "$ESC[2m?$ESC[0m/32G now" "$OUT"'
	printf '@stderr slurm_load_jobs error: Socket timed out on send/recv operation\n@exit 1\n' > "$d/squeue-alloc"
	age "$cache2" 40
	job_run "$d" XDG_CACHE_HOME="$cache2" -- --color job 11898
	need "the allocation call failing: a red !, no sstat" eval '
		rc_is 0 && [ "$(alloc_calls)" = 1 ] && [ "$(calls sstat)" = 0 ] && has "  MEM ················         !/32G now" && LC_ALL=C grep -qF "$ESC[31m!$ESC[0m/32G now" "$OUT"'
	printf '@include %s\n' "$fixtures/jobmem/squeue-alloc" > "$d/squeue-alloc"
	{ grep -v '^JobID=11898' "$fixtures/jobmem/sstat"; echo '@stderr sstat: error: slurm_job_step_stat: there was an error with the request to fb2-bioinf rc = Invalid user id for StepId=11898.batch'; } > "$d/sstat"
	rm -f "$(snap_of "$cache2")"
	job_run "$d" XDG_CACHE_HOME="$cache2" -- --no-color job 11898
	need "sstat failing for it: !" eval 'rc_is 0 && [ "$(calls sstat)" = 1 ] && has "  MEM ················         !/32G now"'
}
c_job_notes() {   # Q4
	T_TITLE="the notes, each once and in order: single (cap, polled, OOM, RSS, multi-task), array (cap, polled tasks, pointer, RSS tasks, multi-task tasks); mixed CPUs: no cap"
	local d
	d=$(job_fx all sacct <<'EOF'
JobID=800; State=OUT_OF_MEMORY; ExitCode=0:125; ReqCPUS=1; Start=\{epoch-30h}; Submit=\{epoch-30h}
JobID=800.batch; JobIDRaw=800.batch; UID=; User=; State=OUT_OF_MEMORY; ExitCode=0:125; TotalCPU=00:01.000; TRESUsageInTot=cpu=00:00:01,mem=10485760; TRESUsageInMax=cpu=00:00:01,mem=10485760; NTasks=1; Start=\{epoch-30h}
JobID=800.0; JobIDRaw=800.0; UID=; User=; State=OUT_OF_MEMORY; ExitCode=0:125; TotalCPU=00:10.000; TRESUsageInTot=cpu=00:00:05,mem=2147483648; TRESUsageInMax=cpu=00:20:00,mem=1073741824; NTasks=2; Start=\{epoch-30h}
EOF
)
	job_run "$d" TZ=CEST-2 -- --no-color job 800
	need "single, all five: cap, polled, OOM, RSS, multi-task, in that order" eval '
		rc_is 0 && notes_are "1 requested CPU became 2: a program running 1 thread reaches at most 50%" \
			"CPU time includes processes Slurm killed or never waited for (polled between two samples, so still a lower bound)" \
			"OUT_OF_MEMORY: it hit its 4G limit between two samples; the peak shown is too low" \
			"step 0 started before <date> CEST (RSS accounting): memory shared between processes counted once per process; the peak may read high" \
			"step 0 ran 2 tasks: its peak adds up each task'"'"'s own peak, an upper bound"'
	need "... CPU from the polled 20 min, memory from step 0's total" eval 'has "  CPU █████▒▒▒▒▒▒▒▒▒▒▒  33.4%  20m01s of 1h00m" && has "  MEM ████████▒▒▒▒▒▒▒▒  50.0%  2/4G peak (step 0)"'
	job_run "$d" -SQ_PSS_SINCE -- --no-color job 800
	need "SQ_PSS_SINCE unset: no RSS note" eval 'rc_is 0 && [ "$(notes | wc -l)" = 4 ] && ! notes | grep -q RSS'
	d=$(job_fx arr sacct <<'EOF'
JobID=700_1; JobIDRaw=701; ReqCPUS=1; TotalCPU=00:00.100
JobID=700_1.batch; JobIDRaw=701.batch; UID=; User=; TotalCPU=00:00.100; TRESUsageInTot=cpu=00:00:00,mem=1073741824; TRESUsageInMax=cpu=00:45:00,mem=1073741824; NTasks=1
JobID=700_2; JobIDRaw=702; ReqCPUS=1; TotalCPU=15:00.000; Start=\{epoch-30h}
JobID=700_2.batch; JobIDRaw=702.batch; UID=; User=; TotalCPU=00:00.100; TRESUsageInTot=cpu=00:00:00,mem=10485760; TRESUsageInMax=cpu=00:00:00,mem=10485760; NTasks=1; Start=\{epoch-30h}
JobID=700_2.0; JobIDRaw=702.0; UID=; User=; TotalCPU=15:00.000; TRESUsageInTot=cpu=00:15:00,mem=3221225472; TRESUsageInMax=cpu=00:07:30,mem=1610612736; NTasks=2; Start=\{epoch-30h}
JobID=700_3; JobIDRaw=703; State=FAILED; ExitCode=1:0
EOF
)
	job_run "$d" TZ=UTC -- --no-color job 700
	need "array: counts, then cap, polled tasks, the pointer to the weakest, RSS tasks, multi-task tasks, in that order (the why section's pointer last)" eval '
		rc_is 0 && title_is "▌ 700  job · alice · array of 3: 2 done · 1 failed" &&
		has "  CPU ████████▒▒▒▒▒▒▒▒  50.0%  median · min 25.0% (700_2) · max 75.0% · 2 CPUs per task (1 requested)" &&
		has "  MEM ████████▒▒▒▒▒▒▒▒  50.0%  median · min 25.0% (700_1) · max 75.0%" &&
		notes_are "1 requested CPU became 2: a program running 1 thread reaches at most 50%" \
			"1 task: CPU time includes processes Slurm killed or never waited for (polled between two samples, so still a lower bound)" \
			"over the 2 completed tasks; the weakest: sq job 700_2" \
			"1 task started before <date> UTC (RSS accounting): shared memory counted once per process; their peaks may read high" \
			"1 task peaked in a step of several tasks: that peak adds up each task'"'"'s own, an upper bound" \
			"sq job 700_3 says more about one of them"'
	sed -i 's/^JobID=700_2; JobIDRaw=702; ReqCPUS=1;/JobID=700_2; JobIDRaw=702; ReqCPUS=1; AllocCPUS=4; AllocTRES=billing=4,cpu=4,mem=4G,node=1;/' "$d/sacct"
	job_run "$d" -SQ_PSS_SINCE -- --no-color job 700
	need "tasks given different CPUs: no cap note, no 'per task'" eval 'rc_is 0 && ! notes | grep -q "requested CPU" && lacks "per task"'
}
c_job_pss() {   # Q6
	T_TITLE="SQ_PSS_SINCE: each accepted form, printed back in sq's zone to the minute; empty is unset; anything else rc 2; the dashboard and sq log ignore it"
	local at v ep shown bad
	# a minute two days back: after twotask-11584's step 0 started (128h
	# before the run), before it ended (none: it ended 128h ago too), so the
	# note is due for every form that reads as a date in between
	ep=$(( ($(epoch_now) - 2 * 86400) / 60 * 60 ))
	shown=$(TZ=CEST-2 date -d @$ep '+%Y-%m-%d %H:%M CEST')
	for v in "$(TZ=CEST-2 date -d @$ep '+%Y-%m-%d %H:%M')" "$(TZ=CEST-2 date -d @$ep '+%Y-%m-%d %H:%M:%S')" \
	         "$(date -u -d @$ep '+%Y-%m-%d %H:%M UTC')" "$(TZ=CEST-2 date -d @$ep '+%Y-%m-%d %H:%M +0200')" \
	         "$(TZ=CEST-2 date -d @$ep '+%Y-%m-%d %H:%M CEST')" "$(date -u -d @$ep '+%Y-%m-%dT%H:%MZ')" \
	         "$(date -u -d @$ep '+%Y-%m-%dT%H:%M:%SZ')" "@$ep"; do
		job_run twotask-11584 TZ=CEST-2 SQ_PSS_SINCE="$v" -- --no-color job 11584
		need "SQ_PSS_SINCE='$v': rc 0, the RSS note at $shown" eval 'rc_is 0 && err_empty && notes_raw | grep -qF "step 0 started before $shown (RSS accounting)"'
	done
	v=$(TZ=CEST-2 date -d @$ep '+%Y-%m-%d')
	job_run twotask-11584 TZ=CEST-2 SQ_PSS_SINCE="$v" -- --no-color job 11584
	need "SQ_PSS_SINCE='$v' (a day): its midnight in sq's zone" eval 'rc_is 0 && notes_raw | grep -qF "step 0 started before $v 00:00 CEST (RSS accounting)"'
	job_run twotask-11584 SQ_PSS_SINCE= -- --no-color job 11584
	need "SQ_PSS_SINCE empty: unset, no RSS note" eval 'rc_is 0 && err_empty && ! notes | grep -q RSS'
	for bad in yesterday 15:59 1 now-2hours 2026-13-40 "2026-10-19 25:00" "2026-10-19 15:59 XYZ" "2026-10-19  15:59" \
	           2026-10-19T13:59 "2026-10-19T13:59 Z" @ @12x "@-5" "2026-10-19 15:59 CEST extra" "$(printf 'x\033[31my')"; do
		job_run twotask-11584 SQ_PSS_SINCE="$bad" -- --no-color job 11584
		need "SQ_PSS_SINCE='$bad': rc 2, no Slurm call, says so" eval '
			rc_is 2 && out_empty && no_slurm_call &&
			err_is "sq job: SQ_PSS_SINCE is no date sq job reads: '"'"'$(printf "%s" "$bad" | tr -d "\033")'"'"'; e.g. SQ_PSS_SINCE=\"2026-10-19 15:59 CEST\", 2026-10-19T13:59Z or @1792418340"'
	done
	sq_run empty SQ_PSS_SINCE=garbage --
	need "the dashboard ignores it" eval 'rc_is 0 && err_empty && has "queue is empty"'
	sq_run "$(log_fx pss <<<'StateCompact=CD
@file create wd/out_500.log done\n')" SQ_PSS_SINCE=garbage -- log --no-follow 500
	need "sq log ignores it" eval 'rc_is 0 && [ "$(cat "$OUT")" = done ]'
}
c_job_sources() {   # Q7
	T_TITLE="one source down: the other's view and a dim line saying which (squeue down or unreadable, accounting down, hanging or unreadable, for an ended, a pending job and an array); both: rc 1"
	local d
	d=$(job_fx qdown squeue-all <<<'@stderr slurm_load_jobs error: Unable to contact slurm controller (connect failure)
@exit 1'); cp "$jfx/finished-11912/sacct" "$d/sacct"
	job_run "$d" -- --no-color job 11912
	need "squeue down: rc 0, the view from accounting, the line under the title, the paths unknown for it, the efficiency" eval '
		rc_is 0 && err_empty && [ "$(plain | sed -n 2p)" = "  ↳ squeue did not answer; shown from accounting" ] &&
		kv_is output "unknown: squeue did not answer" && has "  CPU ████████▒▒▒▒▒▒▒▒  49.4%  8m14s of 16m40s" && kv_is ran "8m20s on fb2-bioinf (LocalQ)"'
	printf '@raw garbage\n' > "$d/squeue-all"
	job_run "$d" -- --no-color job 11912
	need "squeue unreadable: the same, its own words" eval 'rc_is 0 && [ "$(plain | sed -n 2p)" = "  ↳ squeue answered what cannot be read; shown from accounting" ]'
	d=$(job_fx adown sacct <<<'@stderr sacct: error: Problem talking to the database: Connection refused
@exit 1'); cp "$jfx/finished-11912/squeue-all" "$d/squeue-all"
	job_run "$d" -- --no-color job 11912
	need "accounting down, an ended job: rc 0, squeue's view, the efficiency section saying why" eval '
		rc_is 0 && err_empty && kv_is state "COMPLETED · exit 0" && kv_is ran "8m20s on fb2-bioinf (LocalQ)" && kv_is stdout /media/BioNAS2/fsill/rnaseq/logs/align-reads-11912.out &&
		has "efficiency" && notes_are "accounting did not answer (sacct: error: Problem talking to the database: Connection refused)"'
	printf '@hang 10\n' > "$d/sacct"
	job_run "$d" -- --no-color job 11912
	need "accounting hanging: within SQ_TIMEOUT (3 s)" eval 'rc_is 0 && notes_are "accounting did not answer within 3s"'
	printf '@raw garbage\n' > "$d/sacct"
	job_run "$d" -- --no-color job 11912
	need "accounting unreadable: its own words" eval 'rc_is 0 && notes_are "accounting answered what cannot be read"'
	cp "$jfx/pending-est/squeue-all" "$jfx/pending-est/scontrol-node" "$jfx/pending-est/squeue-queue" "$d/"; printf '@hang 10\n' > "$d/sacct"
	job_run "$d" -- --no-color job 11962
	need "accounting hanging, a pending job: the line under the title" eval 'rc_is 0 && [ "$(plain | sed -n 2p)" = "  ↳ accounting did not answer within 3s" ] && lacks efficiency'
	cp "$jfx/array-11367/squeue-all" "$d/squeue-all"
	job_run "$d" -- --no-color job 11367
	need "accounting hanging, an array: the counts squeue has, a floor (≥, V16), no bars, why" eval '
		rc_is 0 && title_is "▌ 11367  sweep · hal · array of ≥5 (accounting did not answer): 3 running · 2 pending" &&
		notes_are "done, failed and cancelled tasks are not counted: accounting did not answer within 3s" && ! matches "^  (CPU|MEM) "'
	printf '@stderr slurm_load_jobs error: Unable to contact slurm controller (connect failure)\n@exit 1\n' > "$d/squeue-all"
	printf '@stderr sacct: error: Problem talking to the database: Connection refused\n@exit 1\n' > "$d/sacct"
	job_run "$d" -- --no-color job 11912
	need "both down: rc 1, squeue's reason" eval 'rc_is 1 && out_empty && err_is "sq job: slurm unreachable · slurm_load_jobs error: Unable to contact slurm controller (connect failure)"'
	printf '@stderr slurm_load_jobs error: Invalid job id specified\n@exit 1\n' > "$d/squeue-all"
	job_run "$d" -- --no-color job 11912
	need "squeue forgot it, accounting down: rc 1, accounting's reason" eval 'rc_is 1 && out_empty && err_is "sq job: slurm unreachable · sacct: error: Problem talking to the database: Connection refused"'
	: > "$d/sacct"; printf '@stderr slurm_load_jobs error: Unable to contact slurm controller (connect failure)\n@exit 1\n' > "$d/squeue-all"
	job_run "$d" -- --no-color job 11912
	need "squeue down, accounting without it: rc 1, squeue's reason" eval 'rc_is 1 && err_is "sq job: slurm unreachable · slurm_load_jobs error: Unable to contact slurm controller (connect failure)"'
}

# ============================================================================
# sq job's why section (WHY-v1 W1-W5, v2 V1-V18)
# ============================================================================
# Franz (2026-10-21): the screens "Accept as rendered" (prototype why-proto),
# the tail of a failed job's output for "All jobs", no line for a running
# job, a big array "Longer default + mark partial".  The pinned why__ screens
# are those renders re-rendered by the final code (--pin), the removed
# variants left out; the completed, running, array, pending-dep and
# pending-est screens are job__ ones above.  Their fixtures date everything
# from the run, every age mid-bucket (days too), their output files under the
# run's directory (\{run}/media/...), which the comparison leaves out.
# why_cases: NAME FIXTURE ID [VAR=value...]
why_cases=(
	"pending-dep-mixed dep-mixed-11969 11969"
	"pending-dep-failed dep-failed-11963 11963"
	"pending-resources resources-11964 11964"
	"pending-badconstraints badconstraints-11955 11955"
	"pending-held-own held-own-11966 11966"
	"pending-held-other held-other-11967 11967"
	"failed-127 failed127-11836 11836"
	"failed-1-other failed1-11837 11837"
	"failed-sigill-purged sigill-11353 11353"
	"failed-sigill-recent sigill-recent-11353 11353"
	"failed-slurm53 slurm53-10864 10864"
	"failed-step-cancelled stepcancel-11360 11360"
	"timeout timeout-11325 11325"
	"oom oom-11820 11820"
	"cancelled-running-own cancelled-11945 11945"
	"cancelled-running-seen-by-hal cancelled-11945 11945 SQSTUB_UID=1025"
	"cancelled-pending-array pdarray-10251 10251"
	"nodefail nodefail-11971 11971"
)
# why_run FIXTURE [VAR=value | -VAR]... -- [sq args]: job_run on bioserver's
# head node, 100 columns wide, as the renders were made
why_run() { local fx=$1; shift; job_run "$fx" SQSTUB_HOST=fb2-bioinf.bioinf.local COLUMNS=100 "$@"; }
why_lines() { ${SRC:-plain} | gawk '/^why$/ { on = 1; next } on && /^[a-z]/ { exit } on'; }   # the why section, its caption left out
why_has() { why_lines | grep -qxF -- "$1"; }      # why_has LINE: the section has this line, whole
why_lacks_section() { ! plain | grep -qx why; }
c_why_screens() {   # W1, AC1
	T_TITLE="the accepted why screens byte for byte, dates and the run's directory aside, colour on and off: 18 renders (the 5 job__ screens above cover the rest), with V5's days and V6's NODE_FAIL line"
	local c name fx id extra flag ext
	for c in "${why_cases[@]}"; do
		read -r name fx id extra <<< "$c"
		for flag in --color --no-color; do
			ext=ansi; [ $flag = --color ] || ext=txt
			why_run "$fx" $extra -- $flag job "$id"
			need "$name $flag: rc 0, stderr empty, the pinned screen" eval 'rc_is 0 && err_empty && screen_is "$jfx/screens/why__$name.$ext"'
		done
	done
}
# V18: every relative time of a why fixture sits mid-bucket, days included
c_why_clock_step() {
	T_TITLE="every why fixture draws its why section, and the same report when the clock steps 2 s back or forward after the stub answered"
	local c name fx id extra want skew
	for c in "${why_cases[@]}" "pending-dep pending-dep 11961" "pending-est pending-est 11962" "array array-11367 11367"; do
		read -r name fx id extra <<< "$c"
		why_run "$fx" $extra -- --no-color job "$id"
		need "$name: rc 0, its why section" eval 'rc_is 0 && plain | grep -qx why'
		want=$RUN/screen; unrooted | job_mask /dev/stdin > "$want"
		for skew in -2 2; do
			why_run "$fx" $extra SQSTUB_SKEW=$skew -- --no-color job "$id"
			need "$name, the clock stepped ${skew}s: the same report, dates aside" eval 'cmp -s "$want" <(unrooted | job_mask /dev/stdin)'
		done
	done
}
# the calls the why section makes: framed and pinned as sq job's own, every
# caller setting unset, each only when the job's state calls for it
c_why_calls() {   # W2, V13, V14
	T_TITLE="the why section's calls: scontrol --json show node and squeue -t PD,R for Resources/Priority, scontrol alone for BadConstraints, the parents' squeue and the failed ones' sacct; none for other jobs; SQUEUE_*/SACCT_*/SCONTROL_* unset, %s and 0 pinned"
	local n2 f
	why_run pending-est SQUEUE_SORT=bogus SQUEUE_STATES=PD SACCT_FORMAT=JobID SCONTROL_FEDERATION=1 SCONTROL_ALL=1 \
		SLURM_TIME_FORMAT=relative SLURM_BITSTR_LEN=5 SLURM_JSON=compact -- --no-color job 11962
	need "Priority, a caller's SQUEUE_*, SACCT_*, SCONTROL_* and formats: rc 0, the pinned report" eval '
		rc_is 0 && err_empty && job_is "$jfx/screens/job__pending-est.txt"'
	need "... no call saw an SQUEUE_* but the SQUEUE_FORMAT2 sq set, an SACCT_* or an SCONTROL_*" eval '
		only_format2 && ! grep "^CALL" "$LOG" | grep -qE "SACCT_|SCONTROL_"'
	need "... scontrol --json show node once, without SLURM_JSON, and the whole queue once: squeue -h -t PD,R, 15 fields framed by the queue nonce" eval '
		[ "$(calls scontrol)" = 1 ] && argv_has scontrol --json show node && scontrol_clean && [ "$(calls squeue)" = 2 ] && argv_has squeue -h -t PD,R &&
		[ "$(env_of squeue 2 SQUEUE_FORMAT2)" = \
		  "$(for f in JobID ArrayJobID ArrayTaskID StateCompact UserName Partition NodeList NumCPUs tres-alloc EndTime TimeLeft TimeLimit SubmitTime Reason PriorityLong; do printf "%s:%s," "$f" "$(env_of squeue 1 SQ_NONCE)"; done | sed "s/,\$//")" ]'
	need "... every squeue and sacct call: SLURM_TIME_FORMAT=%s, SLURM_BITSTR_LEN=0" eval '
		all_calls_env SLURM_TIME_FORMAT %s squeue sacct && all_calls_env SLURM_BITSTR_LEN 0 squeue sacct'
	why_run badconstraints-11955 -- --no-color job 11955
	need "BadConstraints: scontrol, no queue call" eval 'rc_is 0 && [ "$(calls scontrol)" = 1 ] && [ "$(calls squeue)" = 1 ]'
	why_run dep-failed-11963 -- --no-color job 11963
	n2=$(env_of sacct 1 SQ_NONCE2)
	need "a failed parent: its squeue (--jobs=11950 -t all, sq job's format) and its sacct (-j 11950, sq job's fields)" eval '
		rc_is 0 && argv_has squeue -h --jobs=11950 -t all && argv_has sacct -p "--delimiter=$n2" -n --noconvert -a -j 11950 &&
		[ "$(calls sacct)" = 2 ] && [ "$(calls scontrol)" = 0 ]'
	why_run dep-mixed-11969 -- --no-color job 11969
	need "two parents, none failed: one squeue for both, no sacct for them" eval '
		rc_is 0 && argv_has squeue -h --jobs=11950,11958 -t all && [ "$(calls sacct)" = 1 ]'
	for f in finished-11912:11912 running-own:11950 timeout-11325:11325 held-own-11966:11966; do
		why_run "${f%:*}" -- --no-color job "${f#*:}"
		need "${f%:*}: no call beyond sq job's own (and JOBMEM's)" eval '
			rc_is 0 && [ "$(calls scontrol)" = 0 ] && ! argv_has squeue -h -t PD,R && [ "$(calls sacct)" = 1 ] && [ "$(calls getent)" = 0 ]'
	done
}

# ---- the tail of a failed job's output (W3, V1-V4, V12) ----------------------
# tail_fx NAME [FIELD=value...] -- [@file LINE...]: failed127-11836 (fsill's
# job, exit 127, started 270 s and ended 130 s before the run, on fb2-bioinf)
# with its output in \{run}/media/out.log, FIELDs of its record changed and
# its file made by these @file lines; prints its directory
tail_fx() {
	local d=$T_DIR/fx-$1 rec f fields=(); shift
	while [ $# -gt 0 ] && [ "$1" != -- ]; do fields+=("$1"); shift; done
	[ $# -gt 0 ] && shift
	rec=$(record_with "$(grep '^JobID=11836;' "$jfx/failed127-11836/squeue-all")" \
		'STDOUT=\{run}/media/out.log' 'STDERR=\{run}/media/out.log' "${fields[@]}")
	mkdir -p "$d"
	sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$jfx/failed127-11836/sacct" > "$d/sacct"
	{ printf '@include %s\n' "$fixtures/_common/job-defaults"
	  for f; do printf '@file %s\n' "$f"; done
	  printf '%s\n' "$rec"; } > "$d/squeue-all"
	printf '%s' "$d"
}
out_file() { printf 'create media/out.log %s' "$1"; }   # out_file CONTENT: the @file line making it (fixture escapes)
dated() { printf 'touch media/out.log \\{now-%s}' "$1"; }  # dated AGO: the @file line dating it, e.g. 200s
tail_lines() { SRC=cplain why_lines | gawk 'f && /^    / { sub(/^    /, ""); print } /ends with:$/ { f = 1 }'; }   # the lines shown
tail_lines_are() { [ "$(tail_lines)" = "$(printf '%s\n' "$@")" ]; }
why_notes() { why_lines | gawk '/^  ↳ / { sub(/^  ↳ /, ""); print }'; }
c_why_tail() {   # W3, V2-V4, V12
	T_TITLE="the tail: the last 5 lines that are not blank, of the last 4096 bytes, as a terminal shows them, scrubbed, cut to COLUMNS, else the terminal's width, else 120; a first line the bound cut dropped, unless it is the only one; 0 bytes empty"
	local d long line i
	d=$(tail_fx plain -- "$(out_file 'one\ntwo\n\nthree\n  \nfour\nfive\nsix\nseven\n')" "$(dated 200s)")
	why_run "$d" -- --no-color job 11836
	need "9 lines, 2 blank: the last 5 not blank, under 'its output ends with:'" eval '
		rc_is 0 && err_empty && why_has "  its output ends with:" && tail_lines_are three four five six seven && [ -z "$(why_notes)" ]'
	# 50 lines of 100 bytes and a newline: 5050 bytes, so the last 4096 begin
	# 45 bytes into line 10, which is cut and goes
	long=; for i in $(seq -w 1 50); do long="$long$(printf 'L%s%097d' "$i" 0)\\n"; done
	d=$(tail_fx long -- "$(out_file "$long")" "$(dated 200s)")
	why_run "$d" COLUMNS=60 -- --no-color job 11836
	need "5050 bytes: the last 5 lines, each cut to 60 columns with …" eval '
		rc_is 0 && tail_lines_are $(for i in 46 47 48 49 50; do printf "L%s%052d… " $i 0; done)'
	# the last 4096 bytes begin exactly at a line: nothing is cut, and the
	# first of them is shown when it is one of the last five
	d=$(tail_fx edge -- "$(out_file "$(printf 'x%.0s' $(seq 1 99))\\n$(printf '%01023d\\n%01023d\\n%01023d\\n%01023d\\n' 1 2 3 4)")" "$(dated 200s)")
	why_run "$d" COLUMNS=30 -- --no-color job 11836
	need "4096 bytes after a whole line: its 4 lines, none dropped" eval '
		rc_is 0 && [ "$(tail_lines | wc -l)" = 4 ] && tail_lines | head -n 1 | grep -qx "0\{25\}…"'
	# one line of 10000 bytes, no newline: shown, cut at its start (…) and end
	d=$(tail_fx oneline -- "$(out_file "$(printf 'a%.0s' $(seq 1 10000))")" "$(dated 200s)")
	why_run "$d" COLUMNS=40 -- --no-color job 11836
	need "a single line longer than the bound: shown cut, never 'empty' (V4)" eval '
		rc_is 0 && tail_lines_are "…$(printf "a%.0s" $(seq 1 34))…" && ! why_notes | grep -q empty'
	# a progress bar: CRs, no newline, longer than the bound; what shows is the
	# text after the last CR, whole
	line=; for i in $(seq 1 200); do line="$line\\r$(printf '%3d%%|%s|' "$i" "$(printf '#%.0s' $(seq 1 20))")"; done
	d=$(tail_fx progress -- "$(out_file "$line")" "$(dated 200s)")
	why_run "$d" -- --no-color job 11836
	need "a CR progress bar: its last state, as a terminal shows it" eval 'rc_is 0 && tail_lines_are "200%|####################|"'
	d=$(tail_fx escapes -- "$(out_file '\e[1;31mred\e[0m bold\n\e]0;a title\aafter title, \e]8;;http://x\e\\link\e]8;;\e\\ end\nbell\a and \x01ctl\x7f\xc2\x9b x\nhalf \xe2\x82\nplain\r\n')" "$(dated 200s)")
	why_run "$d" -- --color job 11836
	need "CR-LF, CSI and OSC escapes go; other controls and C1 go; a broken character is ␚; no escape of the file reaches the screen" eval '
		rc_is 0 && tail_lines_are "red bold" "after title, link end" "bell and ctl x" "half ␚" "plain" &&
		! why_lines | LC_ALL=C grep -q "$(printf "\a")" && [ "$(LC_ALL=C grep -c "$ESC\]" "$OUT")" = 0 ]'
	d=$(tail_fx empty -- 'truncate media/out.log' "$(dated 200s)")
	why_run "$d" -- --no-color job 11836
	need "0 bytes: 'its output is empty', no lines" eval 'rc_is 0 && [ "$(why_notes)" = "its output is empty" ] && [ -z "$(tail_lines)" ]'
	d=$(tail_fx blank -- "$(out_file '\n  \n\t\n\e[0m\n')" "$(dated 200s)")
	why_run "$d" -- --no-color job 11836
	need "blank lines only: says so, not 'empty'" eval 'rc_is 0 && [ "$(why_notes)" = "its output holds only blank lines" ]'
	# the width: COLUMNS above, else the terminal's, else 120; NOTTY: none
	d=$(tail_fx wide -- "$(out_file "$(printf 'w%.0s' $(seq 1 300))\\n")" "$(dated 200s)")
	NOTTY=1 why_run "$d" -COLUMNS -- --no-color job 11836
	need "no COLUMNS and no terminal: cut to 120 (116 and the indent)" eval 'rc_is 0 && tail_lines_are "$(printf "w%.0s" $(seq 1 115))…"'
	PTY=1 PTY_ROWS=30 PTY_COLS=70 why_run "$d" -COLUMNS -- --no-color job 11836
	need "on a terminal of 70 columns: cut to 70" eval 'tail_lines_are "$(printf "w%.0s" $(seq 1 65))…"'
	NOTTY=1 why_run "$d" COLUMNS=10 -- --no-color job 11836
	need "COLUMNS below 21 is no width: 120" eval 'rc_is 0 && tail_lines_are "$(printf "w%.0s" $(seq 1 115))…"'
}
c_why_tail_file() {   # W3, V1-V3
	T_TITLE="the tail's file: regular files only (a FIFO is not opened), dated within [start-5s, end+60s], missing, unreadable, its host; stderr when it has a file of its own; only for FAILED batch jobs"
	local d st
	d=$(tail_fx fifo -- 'fifo media/out.log')
	why_run "$d" -- --no-color job 11836
	need "a FIFO: not opened, 'its output is not a regular file', at once" eval '
		rc_is 0 && err_empty && [ "$(why_notes)" = "its output is not a regular file" ] && [ -z "$(tail_lines)" ]'
	d=$(tail_fx older -- "$(out_file 'old run\n')" "$(dated 276s)")
	why_run "$d" -- --no-color job 11836
	need "written 6 s before the start: not this run's" eval '
		rc_is 0 && [ "$(why_notes)" = "its output was last written before the job started, so it is not this run'"'"'s; not shown" ]'
	d=$(tail_fx lo -- "$(out_file 'early\n')" "$(dated 274s)")
	why_run "$d" -- --no-color job 11836
	need "4 s before the start: within the 5 s, shown" eval 'rc_is 0 && tail_lines_are early'
	d=$(tail_fx later -- "$(out_file 'next run\n')" "$(dated 68s)")
	why_run "$d" -- --no-color job 11836
	need "62 s after the end: written later (V3)" eval '
		rc_is 0 && [ "$(why_notes)" = "its output file was written after the job ended (a later run?)" ] && [ -z "$(tail_lines)" ]'
	d=$(tail_fx hi -- "$(out_file 'last words\n')" "$(dated 72s)")
	why_run "$d" -- --no-color job 11836
	need "58 s after the end: within the 60 s, shown" eval 'rc_is 0 && tail_lines_are "last words"'
	d=$(tail_fx missing)
	why_run "$d" -- --no-color job 11836
	need "no file, read on the host it ran on: 'its output is not there'" eval 'rc_is 0 && [ "$(why_notes)" = "its output is not there" ]'
	why_run "$d" SQSTUB_HOST=fb2-bioinf-0 -- --no-color job 11836
	need "... read on another host: which one the job wrote it on" eval '
		rc_is 0 && [ "$(why_notes)" = "its output is not there; the job wrote it on fb2-bioinf" ]'
	d=$(tail_fx host -- "$(out_file 'shared\n')" "$(dated 200s)")
	why_run "$d" SQSTUB_HOST=fb2-bioinf-0.bioinf.local -- --no-color job 11836
	need "shown on another host: the note names both" eval '
		rc_is 0 && tail_lines_are shared && [ "$(why_notes)" = "read here on fb2-bioinf-0; the job wrote it on fb2-bioinf" ]'
	d=$(tail_fx unreadable -- "$(out_file 'secret\n')" "$(dated 200s)" 'chmod media/out.log 000')
	why_run "$d" -- --no-color job 11836
	need "mode 000: 'cannot be read here'" eval 'rc_is 0 && [ "$(why_notes)" = "its output cannot be read here" ]'
	d=$(tail_fx stderr STDERR=\\{run}/media/err.log -- "$(out_file 'out\n')" "$(dated 200s)" 'create media/err.log err\n' 'touch media/err.log \{now-200s}')
	why_run "$d" -- --no-color job 11836
	need "stderr in a file of its own: its stderr" eval 'rc_is 0 && why_has "  its stderr ends with:" && tail_lines_are err'
	d=$(tail_fx stdout STDERR=/dev/null -- "$(out_file 'out\n')" "$(dated 200s)")
	why_run "$d" -- --no-color job 11836
	need "stderr discarded: its stdout" eval 'rc_is 0 && why_has "  its stdout ends with:" && tail_lines_are out'
	d=$(tail_fx devnull STDOUT=/dev/null STDERR=/dev/null)
	why_run "$d" -- --no-color job 11836
	need "both discarded: no tail, no note" eval 'rc_is 0 && [ -z "$(why_notes)" ] && ! why_lines | grep -q "ends with"'
	d=$(tail_fx interactive BatchFlag=0 -- 'fifo media/out.log')
	why_run "$d" -- --no-color job 11836
	need "an interactive job: no tail, its file never looked at" eval 'rc_is 0 && [ -z "$(why_notes)" ] && ! why_lines | grep -q "ends with"'
	# V1: OOM, TIMEOUT, CANCELLED and NODE_FAIL get none, a FIFO there is
	# never touched; another user's failed job gets its tail (Franz: "All jobs")
	for st in OOM TO CA NF; do
		d=$(tail_fx "st$st" StateCompact=$st -- 'fifo media/out.log')
		why_run "$d" -- --no-color job 11836
		need "$st: no tail, no note about the file" eval 'rc_is 0 && ! why_lines | grep -qE "ends with|its output"'
	done
	# ... and with a readable file, which a tail for every final state would
	# read without a word: tail-as logs every read; FAILED is the control
	for st in F OOM TO CA NF; do
		d=$(tail_fx "rd$st" StateCompact=$st -- "$(out_file 'readable\n')" "$(dated 200s)")
		why_run "$d" PATH="$here/lib/tail-as:$here/bin:$PATH" SQSTUB_TAIL=log -- --no-color job 11836
		if [ $st = F ]; then
			need "FAILED, a readable file: read once (tail -c 4097), its line shown" eval '
				rc_is 0 && [ "$(grep -c "^TAIL	-c 4097 -- " "$LOG")" = 1 ] && tail_lines_are readable'
		else
			need "$st, a readable file: never read, no tail (V1)" eval 'rc_is 0 && ! grep -q "^TAIL" "$LOG" && ! why_lines | grep -qE "ends with|its output"'
		fi
	done
	d=$(tail_fx other UserName=schroder UserID=1029 -- "$(out_file 'theirs\n')" "$(dated 200s)")
	why_run "$d" -- --no-color job 11836
	need "another user's job: its tail too" eval 'rc_is 0 && tail_lines_are theirs'
}
# sq job reads its answers as the dashboard reads its tables (scrub -s), all
# but the plan, which reads the queue answer as Slurm sent it: the output file
# it opens is the job's own path, while the path shown is decoded (the files
# section, the notes).  A partition or node name in Latin-1 joins its nodes
# under -o as under --json; names alike once decoded are one node, which
# scontrol then lists twice; the tail's lines are outside text, so broken bytes
# read ␚ and bidi controls go; the plan's batch host is compared as it reads.
c_why_not_utf8() {
	T_TITLE="sq job: a Latin-1 or RLO job name, path and partition: the file opened by the job's own path, shown decoded; the partition verdict and the node table under --json and -o; nodes alike once decoded listed twice; tail lines with ␚ and no RLO; the batch host as it reads"
	local d p shown how nm want src=$jfx/badconstraints-11955 rlo=$'\342\200\256'
	for p in 'Loc\xe9lQ:Loc␚lQ' 'Loc\xe2\x80\xaelQ:LoclQ'; do
		shown=${p#*:} p=${p%%:*}
		d=$T_DIR/fx-part-$RANDOM; mkdir -p "$d"
		sed "s/LocalQ/${p//\\/\\\\}/g" "$src/scontrol-node" > "$d/scontrol-node"
		sed -e "s|^@include ../../_common/|@include $fixtures/_common/|" -e "s/^JobID=11955;/JobID=11955; Partition=${p//\\/\\\\};/" "$src/squeue-all" > "$d/squeue-all"
		sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$src/sacct" > "$d/sacct"
		sed "s/LocalQ/$shown/" "$jfx/screens/why__pending-badconstraints.txt" > "$d/want"
		for how in json -o; do
			if [ $how = json ]; then why_run "$d" -- --no-color job 11955; else why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11955; fi
			need "partition $p, $how: rc 0, stderr empty, the pinned screen with $shown" eval 'rc_is 0 && err_empty && job_is "$d/want"'
		done
	done
	for nm in 'n\xe9x:n\xe8x:n␚x' "fb2-bioinf:fb2-bioinf\\xe2\\x80\\xae:fb2-bioinf"; do
		IFS=: read -r p want shown <<< "$nm"
		d=$T_DIR/fx-twice-$RANDOM; mkdir -p "$d"
		sed -e 's/fb2-bioinf-0/@B@/g' -e 's/fb2-bioinf/@A@/g' -e "s/@A@/${p//\\/\\\\}/g" -e "s/@B@/${want//\\/\\\\}/g" "$src/scontrol-node" > "$d/scontrol-node"
		for f in squeue-all sacct; do sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$src/$f" > "$d/$f"; done
		for how in json -o; do
			if [ $how = json ]; then why_run "$d" -- --no-color job 11955; else why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11955; fi
			need "nodes $p and $want, $how: one row $shown, 'scontrol listed it twice'" eval '
				rc_is 0 && err_empty && [ "$(why_lines | grep -cE "^    $shown +\\?")" = 1 ] && why_lines | grep -qE "^    $shown +\\? +\\? +unknown: scontrol listed it twice$"'
		done
	done
	for nm in 'M\xfcller:M␚ller' 'a\xe2\x80\xaeb:ab'; do
		shown=${nm#*:} nm=${nm%%:*}
		d=$(tail_fx "path-$RANDOM" "Name=$nm" 'STDOUT=\{run}/media/o_%x.log' 'STDERR=\{run}/media/o_%x.log' -- \
			"create media/o_$nm.log last-words\\n" "touch media/o_$nm.log \\{now-200s}")
		why_run "$d" -- --no-color job 11836
		need "job name $nm, its stdout o_$nm.log: opened (its tail shown), the title, the files section and the screen decoded" eval '
			rc_is 0 && err_empty && utf8_valid && bidi_inert && tail_lines_are last-words &&
			plain | head -n 1 | grep -qxF "▌ 11836  $shown · fsill" && unrooted | grep -qxF "  stdout    /media/o_$shown.log"'
		d=$(tail_fx "gone-$RANDOM" "Name=$nm" 'STDOUT=\{run}/media/o_%x.log' 'STDERR=\{run}/media/o_%x.log')
		why_run "$d" -- --no-color job 11836
		need "job name $nm, no such file: 'its output is not there', the path decoded" eval '
			rc_is 0 && err_empty && [ "$(why_notes)" = "its output is not there" ] && unrooted | grep -qxF "  stdout    /media/o_$shown.log"'
	done
	d=$(tail_fx lines -- "$(out_file 'a\xe2\x80\xaeb\nM\xfcller \xe2\x81\xa6x\n')" "$(dated 200s)")
	why_run "$d" -- --no-color job 11836
	need "tail lines with RLO, a Latin-1 byte and U+2066: 'ab', 'M␚ller x'" eval 'rc_is 0 && err_empty && bidi_inert && tail_lines_are ab "M␚ller x"'
	d=$(tail_fx host 'BatchHost=fb2-bi\xe9nf.bioinf.local')
	why_run "$d" -- --no-color job 11836
	need "a batch host in Latin-1, read elsewhere: the note names it decoded" eval '
		rc_is 0 && err_empty && [ "$(why_notes)" = "its output is not there; the job wrote it on fb2-bi␚nf" ]'
	why_run "$d" SQSTUB_HOST="$(printf 'fb2-bi\351nf.bioinf.local')" -- --no-color job 11836
	need "... read on that host: the same name, no host in the note" eval 'rc_is 0 && err_empty && [ "$(why_notes)" = "its output is not there" ]'
	d=$(tail_fx hostrlo "BatchHost=fb2-bio${rlo}inf.bioinf.local")
	why_run "$d" -- --no-color job 11836
	need "a batch host with RLO, read on fb2-bioinf: its decoded name is this host's" eval 'rc_is 0 && err_empty && [ "$(why_notes)" = "its output is not there" ]'
}
# sq job reads scontrol -o as the --json answer, control characters too: a
# partition holding one is the queue's partition (both "?" once read), so the
# verdict is the --json one; node\001 beside node? is "listed it twice" on both
# paths.  Under C.UTF-8 and under a gawk forced to C.
c_why_ctl_o() {
	T_TITLE="sq job under -o: a partition with \\001 or \\302\\201 gets the --json verdict (the pinned screen, Loc?lQ); node\\001 beside node? 'listed it twice' as under --json; a state with ESC or \\001 reads ? as under --json; under C.UTF-8 and a gawk in C"
	local d p how json src=$jfx/badconstraints-11955 f
	no_utf8_locale "$T_DIR/nobin"
	for p in 'Loc\x01lQ' 'Loc\xc2\x81lQ' 'pair'; do
		d=$T_DIR/fx-ctl-$RANDOM; mkdir -p "$d"
		for f in squeue-all sacct; do sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$src/$f" > "$d/$f"; done
		if [ "$p" = pair ]; then
			sed -e 's/fb2-bioinf-0/fb2-bio?nf/g' -e 's/fb2-bioinf /fb2-bio\\x01nf /g' -e 's/=fb2-bioinf$/=fb2-bio\\x01nf/' "$src/scontrol-node" > "$d/scontrol-node"
		else
			sed "s/LocalQ/${p//\\/\\\\}/g" "$src/scontrol-node" > "$d/scontrol-node"
			sed -i "s/^JobID=11955;/JobID=11955; Partition=${p//\\/\\\\};/" "$d/squeue-all"
			sed "s/LocalQ/Loc?lQ/" "$jfx/screens/why__pending-badconstraints.txt" > "$d/want"
		fi
		for how in utf8 C; do
			if [ $how = utf8 ]; then why_run "$d" -- --no-color job 11955; else why_run "$d" LC_ALL=C PATH="$T_DIR/nobin:$here/bin:$PATH" -- --no-color job 11955; fi
			json=$RUN/out
			if [ $how = utf8 ]; then why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11955; else why_run "$d" SQSTUB_NOJSON=1 LC_ALL=C PATH="$T_DIR/nobin:$here/bin:$PATH" -- --no-color job 11955; fi
			if [ "$p" = pair ]; then
				need "fb2-bio\\x01nf beside fb2-bio?nf, $how, -o: rc 0, 'listed it twice', the --json screen" eval '
					rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && why_lines | grep -qE "^    fb2-bio\\?nf +\\? +\\? +unknown: scontrol listed it twice$" && job_is "$json"'
			else
				need "partition $p, $how, -o: rc 0, the --json screen$([ $how = C ] || echo ", the pinned one with Loc?lQ")" eval '
					rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && job_is "$json" && { [ $how = C ] || job_is "$d/want"; }'
			fi
		done
	done
	# the states node_read keeps: an ESC in a flag reads ?, as --json reads it
	d=$T_DIR/fx-ctl-state; mkdir -p "$d"
	for f in squeue-all squeue-queue sacct; do sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$jfx/resources-11964/$f" > "$d/$f"; done
	sed -e 's/State=MIXED /State=MIXED+FAIL\\x1b[2J /' -e 's/State=IDLE /State=IDLE+FAIL\\x01 /' "$jfx/resources-11964/scontrol-node" > "$d/scontrol-node"
	for how in utf8 C; do
		if [ $how = utf8 ]; then why_run "$d" -- --no-color job 11964; else why_run "$d" LC_ALL=C PATH="$T_DIR/nobin:$here/bin:$PATH" -- --no-color job 11964; fi
		json=$RUN/out
		if [ $how = utf8 ]; then why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964; else why_run "$d" SQSTUB_NOJSON=1 LC_ALL=C PATH="$T_DIR/nobin:$here/bin:$PATH" -- --no-color job 11964; fi
		need "states MIXED+FAIL+ESC[2J and IDLE+FAIL+\\001, $how, -o: rc 0, no ESC, fb2-bioinf mixed+fail?[2j in the table, the --json screen" eval '
			rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && [ "$(escapes)" = 0 ] && why_lines | grep -qE "^    fb2-bioinf +- +- +mixed\+fail\?\[2j$" &&
			job_is "$json"'
	done
}
# The passes batch L's review found unpinned (F3): each case fails with its
# mutant.  Accounting's answer alone (squeue forgot the job) with a Latin-1
# byte and a U+202E in the job name and a work directory in valid UTF-8 (m21:
# no pass on acct); a parent's node list in Latin-1 (m22: no pass on what
# job_why_finish joins); a pass that fails, through a gawk that fails scrub -s
# with half an answer written (m28: the half moved into place); a CSI in a
# job name under a gawk in C (m29: read_stream's rule back to [[:cntrl:]]).
c_job_passes() {
	T_TITLE="sq job: accounting alone with M\\xfcller+RLO and a UTF-8 work dir reads M␚ller-run, the dir whole; a parent on fb2-bio\\xe9nf reads fb2-bio␚nf; the dashboard: a scrub -s that fails leaves the raw answer, nothing emptied; a CSI in a job name under a gawk in C reads ?"
	local d gbin=$T_DIR/gbin real
	d=$T_DIR/fx-acct; mkdir -p "$d"
	printf '@stderr slurm_load_jobs error: Invalid job id specified\n@exit 1\n' > "$d/squeue-all"
	sed -e 's|^JobID=11912; \(.*\)WorkDir=/media/BioNAS2/fsill/rnaseq; JobName=align-reads$|JobID=11912; \1WorkDir=/media/Bio-\\xc3\\xbc/r; JobName=M\\xfcller-\\xe2\\x80\\xaerun|' \
		"$jfx/finished-11912/sacct" > "$d/sacct"
	job_run "$d" -- --no-color job 11912
	need "accounting alone: rc 0, stderr empty, valid UTF-8, no bidi control, the title M␚ller-run, the work dir /media/Bio-ü/r" eval '
		rc_is 0 && err_empty && utf8_valid && bidi_inert && plain | head -n 1 | grep -qxF "▌ 11912  M␚ller-run · fsill" &&
		plain | grep -qxF "  work dir  /media/Bio-ü/r"'
	d=$(dep_fx nodes 'afterok:900(unfulfilled)' "$(run_rec 900); NodeList=fb2-bio\\xe9nf")
	why_run "$d" -- --no-color job 800
	need "a parent running on fb2-bio\\xe9nf: rc 0, stderr empty, its row reads fb2-bio␚nf" eval '
		rc_is 0 && err_empty && utf8_valid && why_has "    900  RUNNING on fb2-bio␚nf · 1h00m left of 2h00m"'
	real=$(command -v gawk); mkdir -p "$gbin"
	printf '#!/bin/sh\nfor a; do [ "$a" != stream=1 ] || { head -c 10; exit 1; }; done\nexec %q "$@"\n' "$real" > "$gbin/gawk"; chmod +x "$gbin/gawk"
	sq_run not-utf8 PATH="$gbin:$here/bin:$PATH" -- --full
	need "scrub -s failing after 10 bytes: rc 0, the raw answers read, every queue and finished row there" eval '
		rc_is 0 && [ "$(row_first_fields queue | paste -sd,)" = 3001,3002,3003,3004,3005 ] && footer_is 5 5 0 0 &&
		[ "$(row_first_fields recent | paste -sd,)" = 2002,2001 ] && matches "^ +node03 "'
	no_utf8_locale "$T_DIR/nobin"
	d=$(tail_fx csi 'Name=a\xc2\x9b2Jb')
	why_run "$d" LC_ALL=C PATH="$T_DIR/nobin:$here/bin:$PATH" -- --no-color job 11836
	need "a job name with a CSI under a gawk in C: rc 0, no C1 on the screen, the title a?2Jb" eval '
		rc_is 0 && err_empty && c1_off && plain | head -n 1 | grep -qxF "▌ 11836  a?2Jb · fsill"'
}
c_why_tail_hung() {   # V2
	T_TITLE="a reader that does not answer (a hung NFS read, here a tail that sleeps): sq says so after 2 s, kills it, and leaves nothing behind"
	local d
	d=$(tail_fx hung -- "$(out_file 'never read\n')" "$(dated 200s)")
	sq_start "$d" SQSTUB_UID=1041 SQ_PSS_SINCE=@$(( $(epoch_now) - pss_ago )) PATH="$here/lib/tail-as:$here/bin:$PATH" SQSTUB_TAIL=hang -- --no-color job 11836
	sq_finish "$RUN" 10
	need "rc 0, the note, nothing left in its session, the tmp dir gone" eval '
		rc_is 0 && [ "$(why_notes)" = "its output file did not answer within 2s" ] && nothing_at_exit && [ -z "$(ls -A "$RUN/tmp")" ]'
	local start=$(date +%s%N)
	sq_run "$d" SQSTUB_UID=1041 PATH="$here/lib/tail-as:$here/bin:$PATH" SQSTUB_TAIL=hang -- --no-color job 11836
	need "... within 2 s and a little (under 4 s in all)" eval 'rc_is 0 && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 4000 ]'
}

# ---- V14: scontrol's free text cannot forge the figures ------------------------
# node_fx NAME LINE...: badconstraints-11955 (fsill's 140 CPUs and 986.3G,
# LocalQ) against these scontrol -o show node lines; prints its directory
node_fx() {
	local d=$T_DIR/fx-$1 f; shift
	mkdir -p "$d"
	for f in squeue-all sacct; do sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$jfx/badconstraints-11955/$f" > "$d/$f"; done
	printf '%s\n' "$@" > "$d/scontrol-node"
	printf '%s' "$d"
}
c_why_forged() {   # V14
	T_TITLE="scontrol --json, and where Slurm has no --json sinfo's figures with CPUEfctv and MemSpecLimit read from -o only where Slurm prints them: free text naming figures or partitions is text, a node listed twice is unknown; double spaces, a missing MemSpecLimit or CPUEfctv"
	local big small d nojson first
	big=$(grep '^NodeName=fb2-bioinf ' "$jfx/badconstraints-11955/scontrol-node")
	small=$(grep '^NodeName=fb2-bioinf-0 ' "$jfx/badconstraints-11955/scontrol-node")
	for nojson in "" SQSTUB_NOJSON=1; do
		# the probe of the attack: fb2-bioinf without MemSpecLimit, its Reason
		# naming one and another partition list
		d=$(node_fx forged "${big/ MemSpecLimit=31000/} Reason=checking MemSpecLimit=500000 Partitions=small [root@2026-10-21T10:00:00]" "$small")
		why_run "$d" $nojson -- --no-color job 11955
		need "${nojson:+no --json: }a Reason holding MemSpecLimit= and Partitions=: fb2-bioinf's memory for jobs is its RealMemory, in LocalQ still, no MemSpecLimit note for it" eval '
			rc_is 0 && err_empty && why_has "    fb2-bioinf     128          1006.8G  too few CPUs" &&
			! why_notes | grep -q "on fb2-bioinf\$" && why_notes | grep -qxF "memory for jobs is a node'"'"'s RealMemory less what Slurm keeps for the system (MemSpecLimit): 78.1G less 3.1G on fb2-bioinf-0"'
		if [ -n "$nojson" ]; then
			d=$(node_fx comment "$big Comment=x\\nNodeName=fb2-bioinf CPUEfctv=999 CPUTot=999 RealMemory=99999999 AllocMem=0 MemSpecLimit=0 State=IDLE Partitions=LocalQ" "$small")
			why_run "$d" $nojson -- --no-color job 11955
			need "no --json: a Comment whose newline starts a second NodeName=fb2-bioinf line: that node unknown, not the forged figures" eval '
				rc_is 0 && why_has "    fb2-bioinf       ?                ?  unknown: scontrol listed it twice" && ! has 999'
		else   # --json prints that Comment as one string, its newline escaped
			d=$(json_fx "$jfx/badconstraints-11955" "$json_add" NODE=fb2-bioinf KEY=comment \
				V=$'x\nNodeName=fb2-bioinf CPUEfctv=999 CPUTot=999 RealMemory=99999999 AllocMem=0 MemSpecLimit=0 State=IDLE Partitions=LocalQ')
			why_run "$d" -- --no-color job 11955
			need "--json: a comment string holding a newline (escaped) and a NodeName=fb2-bioinf line of forged figures: one node, its own figures, the screen as pinned" eval '
				rc_is 0 && err_empty && [ "$(calls scontrol)" = 1 ] && job_is "$jfx/screens/why__pending-badconstraints.txt"'
		fi
		d=$(node_fx extra "$big Extra=RealMemory=1 CPUEfctv=1 MemSpecLimit=0" "$small")
		why_run "$d" $nojson -- --no-color job 11955
		need "${nojson:+no --json: }an Extra= at the end, as scontrol prints it, naming figures: ignored, the screen as pinned" eval 'rc_is 0 && job_is "$jfx/screens/why__pending-badconstraints.txt"'
		# 23.11.4 prints the CPU figures before OS=, whose value (the node's
		# uname) has spaces and may name anything: a CPUEfctv or CPUAlloc
		# there is text, not a figure (no CPU run of its own)
		first=' SMP CPUEfctv\x3d999 CPUAlloc\x3d0 PREEMPT_DYNAMIC'     # "=" as \x3d: text, no key (stub.sh)
		d=$(node_fx first "${big/ SMP PREEMPT_DYNAMIC/$first}" "$small")
		why_run "$d" $nojson -- --no-color job 11955
		need "${nojson:+no --json: }CPUEfctv= and CPUAlloc= again in the OS= text: the CPU run counts, the screen as pinned" eval 'rc_is 0 && job_is "$jfx/screens/why__pending-badconstraints.txt"'
		d=$(node_fx cputot "${big/ CPUEfctv=128/}" "${small/ CPUEfctv=24/}")
		why_run "$d" $nojson -- --no-color job 11955
		need "${nojson:+no --json: }no CPUEfctv: CPUTot, the screen as pinned" eval 'rc_is 0 && job_is "$jfx/screens/why__pending-badconstraints.txt"'
		d=$(node_fx garbled "${big/ RealMemory=1031000/ RealMemory=lots}" "$small")
		why_run "$d" $nojson -- --no-color job 11955
		need "${nojson:+no --json: }a figure that is no number: that node unknown" eval 'rc_is 0 && why_has "    fb2-bioinf       ?                ?  unknown: scontrol did not say"'
		# the records first, which sinfo's answer is made of (stub.sh), then scontrol failing
		{ printf '%s\n' "$big" "$small"; printf '@stderr scontrol: error: Unable to contact slurm controller (connect failure)\n@exit 1\n'; } > "$d/scontrol-node"
		why_run "$d" $nojson -- --no-color job 11955
		need "${nojson:+no --json: }scontrol failing: the verdict, no table, and why" eval '
			rc_is 0 && why_has "  can never start: no node it may use (LocalQ) meets what it asks for" &&
			[ "$(why_notes)" = "$(printf "%s\n" "the nodes are unknown: scontrol failed (scontrol: error: Unable to contact slurm controller (connect failure))" "Slurm keeps it pending all the same; remove it: scancel 11955")" ]'
	done
}

c_why_nodes_json() {
	T_TITLE="sq job's nodes from scontrol --json: names and partitions decoded (\\b \\f \\n \\r \\t as ?, a surrogate pair as its character, a lone surrogate as ␚, \\u0026 as &, U+202E raw or as \\u202e gone, \\u009b as ? also under a gawk in C), a member twice is 'did not say', a name twice 'listed it twice'; -o where --json is unusable, within what the --json call left of its bound however long sacct takes; the reason of the last call, a timeout named by its bound"
	local d u v start why='scontrol: error: Unable to contact slurm controller (connect failure)' bfx=$jfx/badconstraints-11955
	u=$(printf '\134u')     # a backslash and u
	d=$(json_fx "$bfx" "$json_name" NODE=fb2-bioinf-0 J="\"fb2\\/x\\\"y\\\\z${u}0007\"")
	why_run "$d" -- --no-color job 11955
	need "a name with \\/, \\\", \\\\ and \\u0007: decoded, the control character as ?" eval '
		rc_is 0 && err_empty && why_has "    fb2/x\"y\\z?    24              75G  too few CPUs, too little memory"'
	d=$(json_fx "$bfx" "$json_name" NODE=fb2-bioinf-0 J='"fb2\b\f\n\r\tx"')
	why_run "$d" -- --no-color job 11955
	need "a name with \\b \\f \\n \\r \\t: each a ?" eval '
		rc_is 0 && err_empty && why_has "    fb2?????x     24              75G  too few CPUs, too little memory"'
	d=$(json_fx "$bfx" "$json_name" NODE=fb2-bioinf-0 J="\"a${u}d83d${u}de00b${u}d800c${u}dfffd\"")
	why_run "$d" -- --no-color job 11955
	need "a name with a surrogate pair (U+1F600), a lone high and a lone low surrogate: 😀 (2 columns), then ␚ for each lone one" eval '
		rc_is 0 && err_empty && why_has "    a😀b␚c␚d      24              75G  too few CPUs, too little memory"'
	d=$(json_fx "$bfx" "$json_name" NODE=fb2-bioinf-0 J=$'"fb2\342\200\256x"')
	why_run "$d" -- --no-color job 11955
	need "a name with a raw U+202E: gone" eval 'rc_is 0 && err_empty && bidi_inert && why_has "    fb2x          24              75G  too few CPUs, too little memory"'
	d=$(json_fx "$bfx" "$json_name" NODE=fb2-bioinf-0 J="\"fb2${u}202ex${u}2066\"")
	why_run "$d" -- --no-color job 11955
	need "a name with the escapes \\u202e and \\u2066: gone" eval 'rc_is 0 && err_empty && bidi_inert && why_has "    fb2x          24              75G  too few CPUs, too little memory"'
	d=$(json_fx "$bfx" "$json_name" NODE=fb2-bioinf-0 J="\"fb2${u}009bx\"")
	why_run "$d" -- --no-color job 11955
	need "a name with \\u009b (CSI): a ?" eval 'rc_is 0 && err_empty && c1_off && why_has "    fb2?x         24              75G  too few CPUs, too little memory"'
	no_utf8_locale "$T_DIR/nobin"
	why_run "$d" LC_ALL=C PATH="$T_DIR/nobin:$here/bin:$PATH" -- --no-color job 11955
	need "... under a gawk in C (no UTF-8 locale known): a ? too, no C1 on the screen" eval 'rc_is 0 && err_empty && c1_off && why_lines | grep -qE "^    fb2\?x +24 "'
	d=$(json_fx "$bfx" "$json_name" NODE=fb2-bioinf-0 J="\"fb2${u}0026x\"")
	why_run "$d" -- --no-color job 11955
	need "a name with \\u0026: an &" eval '
		rc_is 0 && err_empty && why_has "    fb2&x         24              75G  too few CPUs, too little memory"'
	d=$(json_fx "$bfx" '/^ *"LocalQ",$/ && !n++ { sub(/LocalQ/, "Local" ENVIRON["U"] "0051") } { print }' U="$u")
	why_run "$d" -- --no-color job 11955
	need "a partition written with \\u0051: decoded, the screen as pinned" eval 'rc_is 0 && err_empty && job_is "$jfx/screens/why__pending-badconstraints.txt"'
	d=$(json_fx "$bfx" "$json_add" NODE=fb2-bioinf KEY=real_memory J=1)
	why_run "$d" -- --no-color job 11955
	need "real_memory twice: that node unknown, scontrol did not say" eval '
		rc_is 0 && err_empty && why_has "    fb2-bioinf       ?                ?  unknown: scontrol did not say"'
	d=$(json_fx "$bfx" '/^ *"state": \[$/ && !n++ { print; print "        {"; print "          \"x\": 1"; print "        },"; next } { print }')
	why_run "$d" -- --no-color job 11955
	need "a state element that is no string: that node unknown, scontrol did not say" eval '
		rc_is 0 && err_empty && why_has "    fb2-bioinf       ?                ?  unknown: scontrol did not say"'
	d=$(json_fx "$bfx" "$json_name" NODE=fb2-bioinf-0 J='"fb2-bioinf"')
	why_run "$d" -- --no-color job 11955
	need "a name in two nodes: listed it twice" eval '
		rc_is 0 && err_empty && why_has "    fb2-bioinf     ?                ?  unknown: scontrol listed it twice"'
	# the -o fallback
	why_run badconstraints-11955 SQSTUB_NOJSON=1 SLURM_JSON=compact SCONTROL_ALL=1 -- --no-color job 11955
	need "no --json: --json, then -o, neither seeing a caller's SLURM_JSON or SCONTROL_*, the screen as pinned" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && argv_has scontrol -o show node && scontrol_clean &&
		job_is "$jfx/screens/why__pending-badconstraints.txt"'
	d=$(json_fx "$bfx" '{ print } /^    },$/ { exit }')
	why_run "$d" -- --no-color job 11955
	need "a --json answer cut short, exit 0: -o, the screen as pinned" eval '
		rc_is 0 && err_empty && [ "$(calls scontrol)" = 2 ] && job_is "$jfx/screens/why__pending-badconstraints.txt"'
	{ cat "$bfx/scontrol-node"; printf '@stderr %s\n@exit 1\n' "$why"; } > "$d/scontrol-node"   # sinfo answers (stub.sh)
	why_run "$d" -- --no-color job 11955
	need "... and -o failing: no table, nothing from the part read, -o's reason" eval '
		rc_is 0 && ! why_lines | grep -q "fb2-bioinf " &&
		[ "$(why_notes)" = "$(printf "%s\n" "the nodes are unknown: scontrol failed ($why)" "Slurm keeps it pending all the same; remove it: scancel 11955")" ]'
	d=$(mem_fixture "${jfx#"$fixtures/"}/badconstraints-11955" scontrol-node "@include $bfx/scontrol-node\n@exit 1")
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11955
	need "no --json, -o failing silently: its exit status" eval '
		rc_is 0 && why_notes | head -n 1 | grep -qxF "the nodes are unknown: scontrol failed (exit 1)"'
	# a timeout asks no more, and names the bound as job_limit set it, without trailing zeros
	{ cat "$bfx/scontrol-node"; printf '@hang 10\n'; } > "$d/scontrol-node"
	why_run "$d" SQ_TIMEOUT=2 -- --no-color job 11955
	need "--json silent: one call, 'no response after 2s'" eval '
		rc_is 0 && [ "$(calls scontrol)" = 1 ] && why_notes | head -n 1 | grep -qxF "the nodes are unknown: scontrol failed (no response after 2s)"'
	printf '@hang 1\n@exit 1\n' > "$d/scontrol-node.json"
	why_run "$d" "$(timeout_as)" SQSTUB_TIMEOUT=log SQ_TIMEOUT=2.5 -- --no-color job 11955
	need "--json failing after 1 s, -o hanging: -o bounded by about 1.5 s, 'no response after 2.5s'" eval '
		rc_is 0 && [ "$(calls scontrol)" = 2 ] && [ "$(timeout_of scontrol)" = 2.500000 ] && v=$(timeout_of scontrol 2) && gawk -v v="$v" "BEGIN { exit !(v >= 0.5 && v <= 1.5) }" &&
		why_notes | head -n 1 | grep -qxF "the nodes are unknown: scontrol failed (no response after 2.5s)"'
	# the -o call's bound is what the --json call left, not what sacct did
	d=$T_DIR/fx-slowacct; mkdir -p "$d"
	for v in squeue-all scontrol-node; do printf '@include %s\n' "$bfx/$v" > "$d/$v"; done
	printf '@hang 4\n@include %s\n' "$bfx/sacct" > "$d/sacct"
	why_run "$d" "$(timeout_as)" SQSTUB_TIMEOUT=log SQSTUB_NOJSON=1 SQ_TIMEOUT=3 -- --no-color job 11955
	need "sacct taking 3 s, --json failing at once: -o gets nearly all of 3 s (2.5 to 3: /proc/uptime counts in 1/100 s), the table drawn" eval '
		rc_is 0 && [ "$(calls scontrol)" = 2 ] && v=$(timeout_of scontrol 2) && gawk -v v="$v" "BEGIN { exit !(v >= 2.5 && v <= 3) }" &&
		why_has "    fb2-bioinf     128           976.5G  too few CPUs, too little memory"'
}
c_why_nodes_figures() {
	T_TITLE="sq job's node table from scontrol --json (effective_cpus, state) and where Slurm has none from -o's CPUEfctv and sinfo's StateComplete: the effective CPUs where they differ from the total, a state of two flags shown joined by +"
	local d nojson ncalls efctv state
	for nojson in "" SQSTUB_NOJSON=1; do
		if [ -n "$nojson" ]; then ncalls=2 efctv="no --json, CPUEfctv=120 and CPUTot=128" state="no --json, State=MIXED+FAIL"
		else ncalls=1 efctv="--json, effective_cpus 120 and cpus 128" state='--json, state ["MIXED", "FAIL"]'; fi
		d=$(res_fx efctv resources-11964 's/^(NodeName=fb2-bioinf .*)CPUEfctv=128/\1CPUEfctv=120/')
		why_run "$d" $nojson -- --no-color job 11964
		need "$efctv: 72 of 120 free, not of 128" eval '
			rc_is 0 && err_empty && [ "$(calls scontrol)" = $ncalls ] &&
			why_has "    fb2-bioinf    72 of 120  656.5G of 976.5G  too few CPUs free"'
		d=$(res_fx mixfail resources-11964 's/^(NodeName=fb2-bioinf .*)State=MIXED/\1State=MIXED+FAIL/')
		why_run "$d" $nojson -- --no-color job 11964
		need "$state: a node down, its state shown as mixed+fail" eval '
			rc_is 0 && err_empty && [ "$(calls scontrol)" = $ncalls ] &&
			why_has "  waits for an admin: every node big enough for it is down or drained" && why_has "    fb2-bioinf            -            -  mixed+fail"'
	done
}

# ---- pending: every reason's verdict, the dashboard's kind ---------------------
# record_with RECORD FIELD=value...: RECORD with these fields set, a field it
# has changed in place (the stub refuses one set twice)
record_with() {
	local rec=$1; shift
	printf '%s' "$rec" "${@/#/; }" | gawk -F'; ' '{ for (i = 1; i <= NF; i++) { k = $i; sub(/=.*/, "", k); if (!(k in at)) ord[++n] = k; at[k] = $i }
		for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? "; " : ""), at[ord[i]]; print "" }'
}
# pend_fx NAME FIELD=value...: job 800 (alice's, uid 1050) pending in LocalQ,
# accounting without it; prints its directory
pend_fx() {
	local n=$1; shift
	record_with 'JobID=800; StateCompact=PD; Reason=None; NodeList=; BatchHost=; StartTime=N/A; EndTime=N/A; TimeUsed=0:00' "$@" | job_fx "$n" squeue-all
}
pend_why() {   # pend_why "FIELD=value ..." LINE: job 800 so pending has this verdict line (its first)
	local d; d=$(pend_fx p$((++pend_n)) $1)
	why_run "$d" -- --no-color job 800
	[ "$RC" = 0 ] && [ "$(why_lines | head -n 1)" = "  $2" ]
}
c_why_pending() {   # W1, V7, V8, J3, J5
	local d
	T_TITLE="a pending job's verdict for every reason sq has words for, its kind the dashboard's (pend_kind): waiting, the owner's holds (V8), an admin's, faults, never (V7: a QOS limit per job), stuck; the hints, the requeue note, the colours"
	local pend_n=0 r
	need "JobHeldUser, own" pend_why "Reason=JobHeldUser UserID=1041" "needs action: on user hold; it can start once you release it: scontrol release 800"
	need "launch failed requeued held (V8): the owner's to release" pend_why "Reason=launch\sfailed\srequeued\sheld" \
		"needs action: it failed to launch, so Slurm requeued it held; only alice (or an admin) can release it"
	need "... own" pend_why "Reason=launch\sfailed\srequeued\sheld UserID=1041" \
		"needs action: it failed to launch, so Slurm requeued it held; it can start once you release it: scontrol release 800"
	need "job requeued in held state" pend_why "Reason=job\srequeued\sin\sheld\sstate" "needs action: it was requeued held; only alice (or an admin) can release it"
	need "RH (V8): held after a requeue, own" pend_why "StateCompact=RH Reason=launch\sfailure\slimit\sexceeded\srequeued\sheld UserID=1041" \
		"needs action: held after a requeue: scontrol release 800"
	need "SE, another's" pend_why "StateCompact=SE Reason=None" "needs action: held after a requeue (special exit); only alice (or an admin) can release it"
	need "JobHeldAdmin" pend_why "Reason=JobHeldAdmin" "waits for an admin: an admin held it; only an admin can release it"
	need "BeginTime passed" pend_why "Reason=BeginTime" "waits its turn: its begin time has passed; the scheduler starts it on a next pass"
	d=$(pend_fx begin Reason=BeginTime 'StartTime=\{epoch+2h30m}')
	why_run "$d" -- --no-color job 800
	need "BeginTime ahead: its date" eval 'rc_is 0 && why_lines | head -n 1 | grep -qxE "  waits its turn: it asked not to start before [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} \(--begin\)"'
	need "None"        pend_why "Reason=None" "waits its turn: the scheduler has not looked at it yet"
	need "Prolog"      pend_why "Reason=Prolog" "waits its turn: its node runs the prolog; it is about to start"
	need "Cleaning"    pend_why "Reason=Cleaning" "waits its turn: Slurm still cleans up after its previous run"
	need "SchedDefer"  pend_why "Reason=SchedDefer" "waits its turn: the scheduler defers new jobs to its next pass"
	need "Reservation" pend_why "Reason=Reservation" "waits its turn: its reservation has not begun"
	need "Licenses"    pend_why "Reason=Licenses" "waits its turn: the licenses it asks for are in use"
	need "PartitionConfig: never, and the hint" eval 'pend_why "Reason=PartitionConfig" "can never start: it asks for more than partition LocalQ offers" &&
		[ "$(why_notes)" = "Slurm keeps it pending all the same, until alice or an admin cancels it" ]'
	need "... own: remove it" eval 'pend_why "Reason=PartitionConfig UserID=1041" "can never start: it asks for more than partition LocalQ offers" &&
		[ "$(why_notes)" = "Slurm keeps it pending all the same; remove it: scancel 800" ]'
	need "PartitionNodeLimit"  pend_why "Reason=PartitionNodeLimit" "can never start: it asks for more nodes than partition LocalQ allows"
	need "PartitionTimeLimit"  pend_why "Reason=PartitionTimeLimit" "can never start: its time limit is longer than partition LocalQ allows"
	need "InvalidAccount"      pend_why "Reason=InvalidAccount" "can never start: its account is not valid"
	need "InvalidQOS"          pend_why "Reason=InvalidQOS" "can never start: its QOS is not valid"
	need "AccountNotAllowed"   pend_why "Reason=AccountNotAllowed" "can never start: its account may not use partition LocalQ"
	need "QOSNotAllowed"       pend_why "Reason=QOSNotAllowed" "can never start: its QOS may not use partition LocalQ"
	need "JobHoldMaxRequeue"   pend_why "Reason=JobHoldMaxRequeue" "can never start: it was requeued too often; Slurm holds it for good"
	need "uid not in group"    pend_why "Reason=uid\s1050\snot\sin\sgroup\spermitted\sto\suse\sthis\spartition\s(LocalQ).\sgroups\sallowed:\sbio" \
		"can never start: its user may not use partition LocalQ"
	need "NodeDown"            pend_why "Reason=NodeDown" "waits for an admin: a node it needs is down"
	need "PartitionDown"       pend_why "Reason=PartitionDown" "waits for an admin: partition LocalQ is down"
	need "PartitionInactive"   pend_why "Reason=PartitionInactive" "waits for an admin: partition LocalQ is inactive"
	need "FrontEndDown"        pend_why "Reason=FrontEndDown" "waits for an admin: the front end node is down"
	need "PowerNotAvail"       pend_why "Reason=PowerNotAvail" "waits for an admin: not enough power is available"
	need "PowerReserved"       pend_why "Reason=PowerReserved" "waits for an admin: the power it needs is reserved"
	need "ReqNodeNotAvail with its nodes" pend_why "Reason=ReqNodeNotAvail,\sUnavailableNodes:fb2-bioinf-0" "waits for an admin: nodes it needs are not available: fb2-bioinf-0"
	need "ReqNodeNotAvail, Reserved" pend_why "Reason=ReqNodeNotAvail,\sReserved\sfor\smaintenance" "waits for an admin: nodes it needs are not available (reserved)"
	need "Nodes required for job are DOWN ..." pend_why "Reason=Nodes\srequired\sfor\sjob\sare\sDOWN,\sDRAINED\sor\sreserved\sfor\sjobs\sin\shigher\spriority\spartitions" \
		"waits for an admin: nodes it needs are down, drained or reserved"
	need "a QOS group limit: stuck, as the dashboard has it (V7)" pend_why "Reason=QOSGrpCpuLimit" "stuck: a limit holds it (QOSGrpCpuLimit) until enough jobs under that limit end"
	need "an association limit: stuck" pend_why "Reason=AssocMaxJobsLimit" "stuck: a limit holds it (AssocMaxJobsLimit) until enough jobs under that limit end"
	need "a QOS limit per job: never (V7), and the hint" eval 'pend_why "Reason=QOSMaxCpuPerJobLimit" "can never start: it asks for more than a limit allows (QOSMaxCpuPerJobLimit)" &&
		[ "$(why_notes)" = "Slurm keeps it pending all the same, until alice or an admin cancels it" ]'
	need "a limit of minutes: never" pend_why "Reason=AssocGrpCPUMinutesLimit" "can never start: it asks for more than a limit allows (AssocGrpCPUMinutesLimit)"
	need "a reason sq does not know: stuck, Slurm's word" pend_why "Reason=Bogus" "stuck: Slurm says Bogus; sq has no plain words for that"
	need "requeued before: the note" eval 'pend_why "Reason=None RestartCnt=2" "waits its turn: the scheduler has not looked at it yet" &&
		[ "$(why_notes)" = "requeued 2 times so far (a node failure, or scontrol requeue)" ]'
	# the throttle of a task still in its array's pending record
	d=$(pend_fx task ArrayJobID=800 ArrayTaskID=5-9%2 Reason=JobArrayTaskLimit)
	why_run "$d" -- --no-color job 800_7
	need "a task in a pending array's record: the array's throttle" eval 'rc_is 0 && [ "$(why_lines | head -n 1)" = "  waits its turn: its array runs at most 2 tasks at once; this one starts when one of them ends" ]'
	# the colours: green, yellow, red, by who has to act
	local reason hue word
	while IFS=: read -r reason hue word; do
		d=$(pend_fx "c$reason" Reason=$reason)
		why_run "$d" -- --color job 800
		need "$reason: '$word' in colour $hue" eval 'rc_is 0 && LC_ALL=C grep -qF "  $ESC[${hue}m$word$ESC[0m: " "$OUT"'
	done <<'EOF'
None:32:waits its turn
JobHeldUser:33:needs action
NodeDown:33:waits for an admin
PartitionConfig:31:can never start
Bogus:33:stuck
EOF
	d=$(job_fx qdown squeue-all <<<'@stderr slurm_load_jobs error: Unable to contact slurm controller (connect failure)
@exit 1')
	job_fx qdown sacct <<<'JobID=800; State=PENDING; ExitCode=0:0; ElapsedRaw=0; AllocCPUS=0; Start=Unknown; End=Unknown; NodeList=None assigned' > /dev/null
	why_run "$d" -- --no-color job 800
	need "squeue down, accounting says PENDING: stuck, the reason unknown" eval 'rc_is 0 && why_has "  stuck: squeue did not answer, so its reason is unknown"'
}

# ---- dependencies (J6, J7) ------------------------------------------------------
# dep_fx NAME DEPENDENCY [PARENTS-RECORD...]: job 800 pending on DEPENDENCY
# (Reason Dependency), the parents call answered with these records (none:
# Slurm knows none of them); prints its directory
dep_fx() {
	local n=$1 dep=$2 d list; shift 2
	d=$(pend_fx "$n" Reason=Dependency "Dependency=$dep")
	list=$(printf '%s' "$dep" | gawk '{ n = split($0, c, /[,?]/); for (i = 1; i <= n; i++) if (match(c[i], /:([0-9]+)(_([0-9]+|\*))?/, m)) printf "%s%s", (o++ ? "," : ""), m[1] ((m[3] != "" && m[3] != "*") ? "_" m[3] : "") }')
	{ printf '@include %s\n' "$fixtures/_common/job-defaults"; printf '%s\n' "$@"; } > "$d/squeue-all.$list"
	printf '%s' "$d"
}
run_rec() { printf 'JobID=%s; StateCompact=R; Name=p; TimeLeft=1:00:00; TimeLimit=2:00:00; EndTime=\\{epoch+1h00m30s}' "$1"; }   # a running parent
c_why_dep() {   # J6, J7
	T_TITLE="dependencies: the condition in the lead line or per row, AND and OR, a delay, singleton, an array parent, a parent Slurm forgot or squeue could not say, a met or impossible one with no clause left"
	local d
	d=$(dep_fx same 'afterok:900(unfulfilled),afterok:901(unfulfilled)' "$(run_rec 900)" "$(run_rec 901)")
	why_run "$d" -- --no-color job 800
	need "two parents, one kind: 'once 900 and 901 have completed successfully', a row each" eval '
		rc_is 0 && [ "$(why_lines)" = "$(printf "%s\n" "  waits its turn: it may start once 900 and 901 have completed successfully" \
			"    900  RUNNING on fb2-bioinf · 1h00m left of 2h00m" "    901  RUNNING on fb2-bioinf · 1h00m left of 2h00m")" ]'
	d=$(dep_fx anyof 'afterany:900(unfulfilled)?afterany:901(failed)' "$(run_rec 900)")
	why_run "$d" -- --no-color job 800
	need "OR with one clause still open: it waits, 'once 900 or 901 has ended', 901 unknown to Slurm" eval '
		rc_is 0 && why_has "  waits its turn: it may start once 900 or 901 has ended" && why_has "    901  Slurm no longer knows it"'
	d=$(dep_fx anyfail 'afternotok:900(failed)?afternotok:901(failed)')
	why_run "$d" -- --no-color job 800
	need "OR with every clause failed: will never start, the hint" eval '
		rc_is 0 && why_has "  will never start: it may start only once 900 or 901 has failed, which can no longer happen" &&
		[ "$(why_notes)" = "Slurm keeps it pending all the same, until alice or an admin cancels it" ]'
	d=$(dep_fx delay 'after:900+10(unfulfilled)' "$(run_rec 900)")
	why_run "$d" -- --no-color job 800
	need "a delay: 'has started and 10 minutes have passed'" eval 'rc_is 0 && why_has "  waits its turn: it may start once 900 has started and 10 minutes have passed"'
	d=$(pend_fx single Reason=Dependency 'Dependency=singleton(unfulfilled)' Name=nightly)
	why_run "$d" -- --no-color job 800
	need "singleton: no other job of alice's named nightly" eval 'rc_is 0 && why_has "  waits its turn: it may start once no other job of alice'"'"'s named nightly runs or waits ahead of it"'
	d=$(dep_fx arr 'afterok:902_*(unfulfilled)' 'JobID=903; ArrayJobID=902; ArrayTaskID=1; StateCompact=R' 'JobID=904; ArrayJobID=902; ArrayTaskID=2; StateCompact=R' \
		'JobID=902; ArrayJobID=902; ArrayTaskID=3-5; StateCompact=PD; Reason=JobArrayTaskLimit')
	why_run "$d" -- --no-color job 800
	need "an array parent (_*): every task of it, its tasks counted by state" eval '
		rc_is 0 && why_has "  waits its turn: it may start once every task of array 902 has completed successfully" &&
		why_has "    902  its tasks now: 2 RUNNING · 3 PENDING"'
	d=$(dep_fx task 'afterok:902_4(unfulfilled)' 'JobID=905; ArrayJobID=902; ArrayTaskID=4; StateCompact=R; TimeLeft=1:00:00; TimeLimit=2:00:00')
	why_run "$d" -- --no-color job 800
	need "an array task parent (902_4): its own state" eval 'rc_is 0 && why_has "    902_4  RUNNING on fb2-bioinf · 1h00m left of 2h00m"'
	d=$(dep_fx qfail 'afterok:900(unfulfilled)' '@stderr slurm_load_jobs error: Unable to contact slurm controller (connect failure)' '@exit 1')
	why_run "$d" -- --no-color job 800
	need "the parents' squeue failing: 'unknown: squeue did not answer'" eval 'rc_is 0 && why_has "    900  unknown: squeue did not answer"'
	d=$(pend_fx never Reason=DependencyNeverSatisfied)
	why_run "$d" -- --no-color job 800
	need "DependencyNeverSatisfied and no clause left: will never start" eval '
		rc_is 0 && why_has "  will never start: a job it depends on ended the wrong way" && [ "$(why_notes)" = "Slurm keeps it pending all the same, until alice or an admin cancels it" ]'
	d=$(pend_fx met Reason=Dependency)
	why_run "$d" -- --no-color job 800
	need "Dependency and no clause left: met, the next pass" eval 'rc_is 0 && why_has "  waits its turn: its dependency is met now; the scheduler starts it on a next pass"'
}

# ---- Resources and Priority (J9-J11, V9, V11) ---------------------------------
# res_fx NAME FIXTURE [SED...]: FIXTURE (resources-11964 or pending-est) with
# these sed expressions run on its scontrol-node and squeue-queue; prints its directory
res_fx() {
	local d=$T_DIR/fx-$1 src=$jfx/$2 f e; shift 2
	mkdir -p "$d"
	for f in squeue-all sacct scontrol-node squeue-queue; do
		sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$src/$f" > "$d/$f"
		for e; do sed -i -E "$e" "$d/$f"; done
	done
	printf '%s' "$d"
}
c_why_resources() {   # J9-J11, V9, V11
	T_TITLE="Resources and Priority: fits now, every big node drained, several nodes, a year-long limit is no 'no time limit' (11875 live), Slurm's queue order (priority, then submit), array tasks as N_T, scontrol or the queue failing"
	local d
	d=$(res_fx fits resources-11964 's/^(NodeName=fb2-bioinf .*)CPUAlloc=48/\1CPUAlloc=16/')
	why_run "$d" -- --no-color job 11964
	need "enough free now: Slurm's reason is stale, no jobs to end first" eval '
		rc_is 0 && why_has "  waits its turn: enough is free now on fb2-bioinf; Slurm should start it on a next pass" &&
		why_has "    fb2-bioinf    112 of 128  656.5G of 976.5G  fits now" && ! why_lines | grep -q "to end first"'
	d=$(res_fx drained resources-11964 's/^(NodeName=fb2-bioinf .*)State=MIXED/\1State=MIXED+DRAIN/')
	why_run "$d" -- --no-color job 11964
	need "every node big enough drained: waits for an admin" eval '
		rc_is 0 && why_has "  waits for an admin: every node big enough for it is down or drained" && why_has "    fb2-bioinf            -            -  drained"'
	d=$(res_fx year resources-11964 's/^(JobID=11875;.*)TimeLeft=UNLIMITED; TimeLimit=UNLIMITED/\1TimeLeft=362-14:00:00; TimeLimit=365-00:00:00/')
	why_run "$d" -- --no-color job 11964
	need "11875 with TimeLimit 365-00:00:00, as it is live: its time left, no 'no time limit' note" eval '
		rc_is 0 && why_has "    11875  schroder  32 CPUs    256G  362d14h left" && [ -z "$(why_notes)" ]'
	d=$(res_fx nodes2 resources-11964)
	sed -i 's/^\(JobID=11964;.*\)$/\1; NumNodes=2/' "$d/squeue-all"
	why_run "$d" -- --no-color job 11964
	need "two nodes asked for: the table compares one" eval 'rc_is 0 && why_notes | grep -qxF "it asks for 2 nodes; the table compares one"'
	d=$(res_fx task resources-11964 's/^JobID=11950; ArrayJobID=11950;/JobID=11960; ArrayJobID=11367; ArrayTaskID=212;/')
	why_run "$d" -- --no-color job 11964
	need "an array task among the jobs to end first: 11367_212, the column as wide as it (V11)" eval '
		rc_is 0 && why_has "    11367_212  fsill     16 CPUs     64G  21h46m left" && why_has "    11875      schroder  32 CPUs    256G  no time limit"'
	# Slurm's order (V9): 11958 has the higher priority though submitted after
	# 11962, 11957 the same priority and submitted before it, 11959 a lower one
	d=$(res_fx order pending-est 's/^(JobID=11958;.*)SubmitTime=\\\{epoch-16200s\}/\1SubmitTime=\\{epoch-3900s}; PriorityLong=9/')
	cat >> "$d/squeue-queue" <<'EOF'
JobID=11957; ArrayJobID=11367; ArrayTaskID=213; StateCompact=PD; UserName=hal; Partition=LocalQ; NodeList=; NumCPUs=2; tres_alloc=cpu=2,mem=15600M,node=1,billing=2; EndTime=N/A; TimeLeft=1:00:00; TimeLimit=1:00:00; SubmitTime=\{epoch-9930s}; Reason=Priority
JobID=11959; StateCompact=PD; UserName=schroder; Partition=LocalQ; NodeList=; NumCPUs=4; tres_alloc=cpu=4,mem=31200M,node=1,billing=4; EndTime=N/A; TimeLeft=1:00:00; TimeLimit=1:00:00; SubmitTime=\{epoch-20000s}; Reason=Priority; PriorityLong=0
EOF
	why_run "$d" -- --no-color job 11962
	need "ahead: the higher priority first (submitted later, so 'ahead of it in the queue'), then the earlier submit; a lower priority submitted earlier is not" eval '
		rc_is 0 && [ "$(why_lines | sed -n 1,3p)" = "$(printf "%s\n" "  waits its turn: 2 jobs ahead of it in the queue come first" \
			"    11958      amadvi     64 CPUs    500G  PENDING (Resources), submitted 1h ago" \
			"    11367_213  hal         2 CPUs   15.2G  PENDING (Priority), submitted 2h ago")" ]'
	d=$(res_fx nonodes resources-11964)
	{ cat "$jfx/resources-11964/scontrol-node"; printf '@stderr scontrol: error: Unable to contact slurm controller (connect failure)\n@exit 1\n'; } > "$d/scontrol-node"
	why_run "$d" -- --no-color job 11964
	need "scontrol failing: the lead, Slurm's word for it as the nodes are unknown (N8), then why there is no table" eval '
		rc_is 0 && why_has "  waits its turn: Slurm finds too little free now on the nodes it may use (LocalQ)" &&
		[ "$(why_notes)" = "the nodes are unknown: scontrol failed (scontrol: error: Unable to contact slurm controller (connect failure))" ]'
	d=$(res_fx noqueue resources-11964)
	printf '@stderr slurm_load_jobs error: Socket timed out on send/recv operation\n@exit 1\n' > "$d/squeue-queue"
	why_run "$d" -- --no-color job 11964
	need "the queue call failing, Resources: the table, then why no jobs to end first" eval '
		rc_is 0 && why_has "    fb2-bioinf    80 of 128  656.5G of 976.5G  too few CPUs free" &&
		[ "$(why_notes)" = "which jobs must end first is unknown: squeue did not answer" ]'
	d=$(res_fx noqueue2 pending-est)
	printf '@hang 10\n' > "$d/squeue-queue"
	why_run "$d" -- --no-color job 11962
	need "the queue call hanging, Priority: within SQ_TIMEOUT, 'a job ahead of it', and why none is named" eval '
		rc_is 0 && why_has "  waits its turn: a job ahead of it in the queue comes first" && why_notes | grep -qxF "the jobs ahead are unknown: squeue did not answer"'
}

# ---- an ended job (J13-J19, V10) ----------------------------------------------
# end_fx NAME [FIELD=value...] -- [STEP-ROW...]: job 800 of accounting
# (alice's, uid 1050, ran 30 min), its job row with these fields, these step
# rows; squeue has forgotten it; prints its directory
end_fx() {
	local n=$1 rec='JobID=800'; shift
	while [ $# -gt 0 ] && [ "$1" != -- ]; do rec=$(record_with "$rec" "$1"); shift; done
	[ $# -gt 0 ] && shift
	printf '%s\n' "$rec" "$@" | job_fx "$n" sacct
}
end_why() {   # end_why FIXTURE LINE: sq job 800 has this first why line
	why_run "$1" -- --no-color job 800
	[ "$RC" = 0 ] && [ "$(why_lines | head -n 1)" = "  $2" ]
}
step() { printf 'JobID=800.%s; JobIDRaw=800.%s; UID=; User=; %s' "$1" "$1" "$2"; }   # step NAME FIELDS: a step row
c_why_ended() {   # J13-J19, V10
	T_TITLE="an ended job: each exit's words and its ambiguity, a signal, a Slurm error, a canceller (you, root, the owner, another, nobody recorded, not yet known), getent failing (V10), TIMEOUT, NODE_FAIL's requeue, DEADLINE, PREEMPTED, BOOT_FAIL"
	local d
	need "exit 2"   end_why "$(end_fx e2 State=FAILED ExitCode=2:0)" "exit 2: often a usage error (a wrong option or argument) or a shell syntax error"
	need "exit 126" end_why "$(end_fx e126 State=FAILED ExitCode=126:0)" "exit 126: a command was found but could not be run (not executable)"
	need "... and its twin, 254" eval 'why_notes | grep -qxF "or exit 254, the program'"'"'s own code (exit(-1) is 255): sacct prints an exit above 128 less 128, so it cannot tell the two apart"'
	need "exit 9 from sacct: or 137, SIGKILL" end_why "$(end_fx e9 State=FAILED ExitCode=9:0)" "exit 9 (or 137: a command killed by SIGKILL, killed outright)"
	need "exit 42: the program's own" end_why "$(end_fx e42 State=FAILED ExitCode=42:0)" "exit 42: the program's own code; its output may say what it means"
	d=$(record_with 'JobID=800; StateCompact=F; exit_code=255:0' | job_fx raw255 squeue-all)
	need "squeue's raw 255 wins: the program's own, no ambiguity" end_why "$d" "exit 255: the program's own code (exit(-1) is 255); its output may say what it means"
	need "FAILED with no exit recorded" end_why "$(end_fx e0 State=FAILED ExitCode=0:0)" "Slurm marked it FAILED, but neither the job nor a step recorded an exit code"
	need "a signal, no canceller" end_why "$(end_fx sig State=FAILED ExitCode=0:0 -- "$(step batch 'State=FAILED; ExitCode=0:11')")" \
		"killed by signal 11 (SIGSEGV, invalid memory access, a segmentation fault)"
	need "Slurm error 52" end_why "$(end_fx err52 State=FAILED ExitCode=0:52)" "Slurm error 52: its tasks could not start"
	# who cancelled: getent knows bob (1025), not 1077
	d=$(end_fx cxyou 'State=CANCELLED\sby\s1041'); printf 'bob:x:1025:1025::/home/bob:/bin/bash\n' > "$d/passwd"
	need "by the caller: you" end_why "$d" "cancelled by you after it ran 30m00s"
	d=$(end_fx cxroot 'State=CANCELLED\sby\s0'); printf 'bob:x:1025:1025::/home/bob:/bin/bash\n' > "$d/passwd"
	need "by uid 0: root" end_why "$d" "cancelled by root (an admin, or Slurm itself) after it ran 30m00s"
	d=$(end_fx cxbob 'State=CANCELLED\sby\s1025'); printf 'bob:x:1025:1025::/home/bob:/bin/bash\n' > "$d/passwd"
	need "by another user getent names" end_why "$d" "cancelled by bob after it ran 30m00s"
	need "... one getent call: passwd 1025" eval '[ "$(calls getent)" = 1 ] && grep -qx "CALL	getent	passwd 1025" "$LOG"'
	d=$(end_fx cxnone 'State=CANCELLED\sby\s1077'); printf 'bob:x:1025:1025::/home/bob:/bin/bash\n' > "$d/passwd"
	need "a uid getent does not know: uid N (V10)" end_why "$d" "cancelled by uid 1077 after it ran 30m00s"
	d=$(end_fx cxowner 'State=CANCELLED\sby\s1050'); printf '@hang 20\nalice:x:1050:1050::/home/alice:/bin/bash\n' > "$d/passwd"
	need "getent hanging, the owner's uid: its owner (V10), within SQ_TIMEOUT" end_why "$d" "cancelled by its owner after it ran 30m00s"
	d=$(end_fx cxpend 'State=CANCELLED\sby\s1041' AllocCPUS=0 Start=None ElapsedRaw=0 NodeList=None\sassigned); printf 'bob:x:1025:1025::/home/bob:/bin/bash\n' > "$d/passwd"
	need "cancelled while pending: how long after its submit" end_why "$d" "cancelled by you while it was pending, 35m00s after it was submitted"
	d=$(end_fx cxnobody State=CANCELLED)
	need "CANCELLED with no one recorded: says so, and when Slurm does that" eval 'end_why "$d" "cancelled after it ran 30m00s; Slurm recorded no one" &&
		[ "$(why_notes)" = "it records no one when it cancels a job itself (a dependency that can never be met, with --kill-on-invalid-dep; a disabled scrontab entry)" ] && [ "$(calls getent)" = 0 ]'
	d=$(record_with 'JobID=800; StateCompact=CA' | job_fx cxlag squeue-all); job_fx cxlag sacct <<<'JobID=800; State=RUNNING; End=Unknown' > /dev/null
	need "squeue says CANCELLED, accounting has no end yet: who shows later" end_why "$d" "cancelled after it ran 30m00s; who did it shows once accounting has recorded the end"
	d=$(record_with 'JobID=800; StateCompact=TO; TimeUsed=1:00:40; TimeLimit=1:00:00' | job_fx to squeue-all)
	need "TIMEOUT from squeue: its limit and how long it ran" end_why "$d" "it reached its time limit of 1h00m after 1h00m"
	d=$(record_with 'JobID=800; StateCompact=NF; exit_code=0:1; RestartCnt=1' | job_fx nf squeue-all)
	need "NODE_FAIL of a batch job requeued before: the note" eval 'end_why "$d" "its node fb2-bioinf failed while it ran" && [ "$(why_notes)" = "Slurm had requeued it 1 time before" ]'
	need "DEADLINE"  end_why "$(end_fx dl State=DEADLINE)" "Slurm ended it: its deadline (--deadline) could no longer be met"
	need "PREEMPTED" end_why "$(end_fx pr State=PREEMPTED)" "preempted: a job with a higher priority took its resources"
	need "BOOT_FAIL" end_why "$(end_fx bf State=BOOT_FAIL)" "its node failed to boot"
	why_run "$jfx/finished-11912" -- --no-color job 11912
	need "COMPLETED: no why section" eval 'rc_is 0 && why_lacks_section'
	why_run "$jfx/running-own" -- --no-color job 11950
	need "RUNNING: no why section (Franz: no line)" eval 'rc_is 0 && why_lacks_section'
}
c_why_array() {   # J25, V16
	T_TITLE="an array's why: failures first by count, the first three ids then …, the pending tasks by their record's reason; the ≥N count while accounting is down"
	local d i rows=
	for i in 1 2 3 4 5; do rows="$rows$(printf 'JobID=900_%s; JobIDRaw=%s; State=FAILED; ExitCode=1:0' $i $((900 + i)))"$'\n'; done
	rows="${rows}JobID=900_6; JobIDRaw=906; State=OUT_OF_MEMORY; ExitCode=0:125"$'\n'"JobID=900_7; JobIDRaw=907; State=COMPLETED"
	d=$(job_fx arr sacct <<<"$rows")
	record_with 'JobID=900; ArrayJobID=900; ArrayTaskID=8-9; StateCompact=PD; Reason=Dependency; NodeList=; EndTime=N/A' | job_fx arr squeue-all > /dev/null
	why_run "$d" -- --no-color job 900
	need "5 failed (3 ids, then …), 1 out of memory, 2 pending by reason, the pointer" eval '
		rc_is 0 && [ "$(why_lines)" = "$(printf "%s\n" "  5 failed with exit 1: 900_1, 900_2, 900_3, …" "  1 ran out of memory: 900_6" \
			"  2 pending: Slurm'"'"'s reason: Dependency" "  ↳ sq job 900_1 says more about one of them")" ]'
	printf '@hang 10\n' > "$d/sacct"
	why_run "$d" -- --no-color job 900
	need "accounting hanging: ≥2, the note, no why section (it needs accounting)" eval '
		rc_is 0 && title_is "▌ 900  job · alice · array of ≥2 (accounting did not answer): 2 pending" &&
		notes_are "done, failed and cancelled tasks are not counted: accounting did not answer within 3s" && why_lacks_section'
}

# ---- the time sq job takes (W2, V13) --------------------------------------------
finished_in() { printf '%s' $(( $(stat -c %Y "$RUN/rc") - $1 )); }   # finished_in START: seconds from START to sq's end
timeout_of() {   # timeout_of TOOL [N]: the bound sq's timeout gave TOOL's first (N-th) call (TIMEOUT lines, SQSTUB_TIMEOUT=log)
	gawk -F'\t' -v t="$1" -v want="${2:-1}" '$1 == "TIMEOUT" && index(" " $2 " ", " " t " ") && ++seen == want { n = split($2, a, " ")
		for (i = 1; i <= n; i++) if (a[i] == "-k") { print a[i + 2]; exit } }' "$LOG"
}
c_why_budget() {   # Franz #1, W2, V13, V16
	T_TITLE="sq job waits 30 s for accounting unless SQ_TIMEOUT validly says otherwise (invalid: as unset); the queue keeps SQ_TIMEOUT's 5 s; every call within sacct's budget and 5 s more; the ≥N array"
	local runs=() r start=$(epoch_now) d dep v
	# accounting silent, SQ_TIMEOUT unset: the pinned ≥N screen after 30 s,
	# colour on and off at once
	sq_start "$jfx/array-silent-11367" SQSTUB_UID=1041 SQ_PSS_SINCE=@$(( start - pss_ago )) -SQ_TIMEOUT -- --no-color job 11367; runs+=("$RUN")
	sq_start "$jfx/array-silent-11367" SQSTUB_UID=1041 SQ_PSS_SINCE=@$(( start - pss_ago )) -SQ_TIMEOUT -- --color job 11367; runs+=("$RUN")
	# a pending job whose queue answers after 4 s, then every other call hangs:
	# sacct for 30 s, its parent's squeue for 5 (SQ_TIMEOUT's default), its
	# failed parent's sacct for what is left of 35 s
	dep=$T_DIR/fx-hangs; mkdir -p "$dep"
	{ echo '@hang 4'; sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$jfx/dep-failed-11963/squeue-all"; } > "$dep/squeue-all"
	printf '@hang 60\n' > "$dep/sacct"; printf '@hang 60\n' > "$dep/sacct.11950"; printf '@hang 60\n' > "$dep/squeue-all.11950"
	sq_start "$dep" SQSTUB_UID=1041 -SQ_TIMEOUT -- --no-color job 11963; runs+=("$RUN")
	for r in "${runs[@]}"; do sq_finish "$r" 60; done
	use_run "${runs[0]}"; RC=$(cat "$RUN/rc")
	# the end is a whole-second mtime and WSL steps the clock back about 1.5 s
	# every 30 s: 27 s still tells the 30 s budget from SQ_TIMEOUT's 5
	need "accounting silent, SQ_TIMEOUT unset: the pinned ≥N screen, after 30 s (27 by the clock) and before 35" eval '
		rc_is 0 && screen_is "$jfx/screens/why__array-silent.txt" && [ "$(finished_in $start)" -ge 27 ] && [ "$(finished_in $start)" -le 36 ] && nothing_at_exit'
	use_run "${runs[1]}"; RC=$(cat "$RUN/rc")
	need "... colour on" eval 'rc_is 0 && screen_is "$jfx/screens/why__array-silent.ansi"'
	use_run "${runs[2]}"; RC=$(cat "$RUN/rc")
	need "everything hanging: done within sacct's 30 s and 5 more (2 s kill grace aside), each source's note, nothing left" eval '
		rc_is 0 && [ "$(finished_in $start)" -le 37 ] && nothing_at_exit &&
		[ "$(plain | sed -n 2p)" = "  ↳ accounting did not answer within 30s" ] &&
		why_has "  will never start: it may start only once 11950 has completed successfully, which can no longer happen" &&
		why_has "    11950  unknown: squeue did not answer"'
	# the bounds as sq gives them to timeout: SQ_TIMEOUT valid is both, and
	# anything else is as unset (sacct 30, the queue 5)
	for v in 2 2.5 7; do
		job_run finished-11912 "$(timeout_as)" SQSTUB_TIMEOUT=log SQ_TIMEOUT=$v -- --no-color job 11912
		need "SQ_TIMEOUT=$v: sacct and squeue both $v" eval 'rc_is 0 && [ "$(timeout_of sacct)" = $v ] && [ "$(timeout_of squeue)" = $v ]'
	done
	for v in abc 0 0.0 -1 '' 1.2.3; do
		job_run finished-11912 "$(timeout_as)" SQSTUB_TIMEOUT=log SQ_TIMEOUT="$v" -- --no-color job 11912
		need "SQ_TIMEOUT='$v' (no valid bound): sacct 30, squeue 5" eval 'rc_is 0 && [ "$(timeout_of sacct)" = 30 ] && [ "$(timeout_of squeue)" = 5 ]'
	done
	job_run finished-11912 "$(timeout_as)" SQSTUB_TIMEOUT=log -SQ_TIMEOUT -- --no-color job 11912
	need "SQ_TIMEOUT unset: sacct 30, squeue 5" eval 'rc_is 0 && [ "$(timeout_of sacct)" = 30 ] && [ "$(timeout_of squeue)" = 5 ]'
	d=$T_DIR/fx-short; mkdir -p "$d"; cp "$jfx/array-11367/squeue-all" "$d/"; printf '@hang 10\n' > "$d/sacct"
	job_run "$d" SQ_TIMEOUT=2 -- --no-color job 11367
	need "SQ_TIMEOUT=2, accounting hanging: 2 s, and the ≥N note says 2s" eval '
		rc_is 0 && notes_are "done, failed and cancelled tasks are not counted: accounting did not answer within 2s"'
	job_run pending-est "$(timeout_as)" SQSTUB_TIMEOUT=log SQ_TIMEOUT=4 -- --no-color job 11962
	need "the why section's calls: within SQ_TIMEOUT too (at most 4 s each)" eval '
		rc_is 0 && v=$(timeout_of scontrol) && [ "${v%%.*}" -le 4 ] && [ "${v%%.*}" -ge 3 ]'
}
c_why_parallel() {   # V13
	T_TITLE="the why section's calls run while sacct is asked: three calls of 3 s each take 3 s, not 6 or 9, and draw the pinned report"
	local d=$T_DIR/fx-slow f start
	mkdir -p "$d"
	for f in squeue-all sacct scontrol-node squeue-queue; do
		{ [ $f = squeue-all ] || echo '@hang 3'; sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$jfx/pending-est/$f"; } > "$d/$f"
	done
	start=$(date +%s%N)
	job_run "$d" SQ_TIMEOUT=6 -- --no-color job 11962
	need "sacct, scontrol and the queue, 3 s each: about 3 s in all (under 5), the pinned report" eval '
		rc_is 0 && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 5000 ] && job_is "$jfx/screens/job__pending-est.txt"'
}
c_why_signals() {   # V2, V13: nothing outlives sq
	T_TITLE="a signal or SIGKILL while the why section's calls and sacct run together: 128+N, or the sentinel ends them; nothing left, the tmp dir gone"
	local d=$T_DIR/fx-hang f sig
	mkdir -p "$d"
	for f in squeue-all sacct scontrol-node squeue-queue; do
		{ [ $f = squeue-all ] || echo '@hang 30'; sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$jfx/pending-est/$f"; } > "$d/$f"
	done
	for sig in INT:130 TERM:143 KILL:; do
		sq_start "$d" SQSTUB_UID=1041 SQ_TIMEOUT=25 -- --no-color job 11962
		need "SIG${sig%:*}: sacct, scontrol and the queue call all in flight at once" \
			waits_for 10 eval '[ "$(calls scontrol)" = 1 ] && [ "$(calls sacct)" = 1 ] && argv_has squeue -h -t PD,R'
		sleep 0.3; kill -"${sig%:*}" "$SQ_PID" 2>/dev/null
		if [ -n "${sig#*:}" ]; then
			sq_finish "$RUN" 20
			need "SIG${sig%:*} while sacct, scontrol and the queue call run: rc ${sig#*:}, nothing left, the tmp dir gone" eval '
				rc_is '"${sig#*:}"' && nothing_at_exit && waits_for 3 nothing_left && [ -z "$(ls -A "$RUN/tmp")" ]'
		else
			need "SIGKILL then: within 3 s the sentinel ends all three calls and removes the tmp dir" eval '
				waits_for 3 eval "[ -z \"\$(ls -A \"\$RUN/tmp\")\" ]" && waits_for 3 nothing_left'
			sq_finish "$RUN" 10
		fi
	done
}

# ============================================================================
# the argument normal form (OPTS-v4): how sq reads its command line and
# squeue's environment, and what squeue and sacct get from them
# ============================================================================
# Franz (2026-10-24): "I follow your recommendations"; OPTS-v4's AC1-AC23 and
# AC27, one case each or a few together.  Q is the queue call, M the mirror
# call, F the fallback, S the dashboard's sacct call.
opts_long_ok() {   # no squeue call took a long option but the six sq spells long, and --jobs=
	gawk -F'\t' '$1 == "CALL" && $2 == "squeue" { n = split($3, W, " ")
		for (i = 1; i <= n; i++) if (W[i] ~ /^--/ && W[i] !~ /^--(me|hide|noconvert|federation|local|sibling)$/ && W[i] !~ /^--jobs=/) bad = 1 }
		END { exit bad }' "$LOG"
}
orun() {   # orun FIXTURE [VAR=value | -VAR]... -- [sq args]: sq_run, and squeue got no other long option (AC14)
	sq_run "$@"
	need "sq ${*}: no long option reaches squeue but --me --hide --noconvert --federation --local --sibling --jobs=" opts_long_ok
}
o_args() { local a=; while [ $# -gt 0 ] && [ "$1" != -- ]; do a="$a $1"; shift; done; shift; printf '%s' "${a# }${a:+ }sq${*:+ }$*"; }
o_refused() {   # o_refused TEXT [VAR=value | -VAR]... -- ARGS...: rc 2, nothing on stdout, no Slurm call, stderr exactly "sq: TEXT"
	local text=$1; shift
	sq_run empty "$@"
	need "$(o_args "$@"): rc 2, nothing on stdout, no Slurm call, says '$text'" eval '
		rc_is 2 && out_empty && no_slurm_call && err_is "sq: $text"'
}
o_twin() {   # o_twin: an accepted run, so a case of refusals alone still proves the stubs answer
	orun empty --
	need "the accepted twin, sq alone: rc 0, the stubs called" eval 'rc_is 0 && [ "$(calls queue)" = 1 ]'
}
q_argv() { gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && (" " $3) !~ / -t all / && $0 !~ /tres-alloc/ { print $3 }' "$LOG"; }
q_is() { [ "$(calls queue)" = 1 ] && [ "$(q_argv)" = "$(printf '%q ' -h -S t,i "$@")" ]; }   # q_is ARGS...: Q got exactly -h -S t,i ARGS
f_is() {   # f_is ARGS...: the fallback got exactly -h ARGS -t all
	[ "$(calls fallback)" = 1 ] &&
	[ "$(gawk -F'\t' '$1 == "CALL" && $2 == "squeue" && (" " $3) ~ / -t all / { print $3 }' "$LOG")" = "$(printf '%q ' -h "$@" -t all)" ]
}
s_is() {   # s_is ARGS...: S got exactly ARGS between "-E now" and "-o JobID,…"
	local got want=
	[ "$(calls sacct)" = 1 ] || return 1
	got=$(gawk -F'\t' '$1 == "CALL" && $2 == "sacct" { print $3 }' "$LOG")
	got=${got#*"-E now "} got=${got%%"-o JobID"*}
	[ $# = 0 ] || want=$(printf '%q ' "$@")
	[ "$got" = "$want" ]
}
caption_is() { [ "$(section recent | head -n 1 | sed 's/^ *//; s/ *$//')" = "$1" ]; }
n4_vars=" SQUEUE_ALL SQUEUE_ARRAY SQUEUE_FEDERATION SQUEUE_LOCAL SQUEUE_PRIORITY SQUEUE_SIB SQUEUE_SIBLING SQUEUE_ACCOUNT SQUEUE_NAMES SQUEUE_LICENSES SQUEUE_PARTITION SQUEUE_QOS SQUEUE_STATES SQUEUE_USERS SQUEUE_SORT "
squeue_env_clean() {   # no squeue call had one of N4's variables, nor SQUEUE_SORT, in its environment
	gawk -F'\t' -v vars="$n4_vars" '$1 == "CALL" && $2 == "squeue" { n++
		for (i = 4; i <= NF; i++) { v = $i; if (sub(/=.*/, "", v) && index(vars, " " v " ")) bad = 1 } }
		END { exit !(n && !bad) }' "$LOG"
}
login_of_stub() { env -i PATH="$here/bin:$PATH" id -un; }   # what the runs' `id -un` answers

c_opts_env_values() {   # AC1
	T_TITLE="squeue's environment filters are their flags: in the queue call's argv in squeue's order, in sacct's, on the caption; F for -n -L"
	orun empty SQUEUE_USERS=bob --
	need "SQUEUE_USERS=bob: Q -u bob, S -u bob without -a, user=bob" eval '
		rc_is 0 && q_is -u bob && s_is -u bob && caption_is "recently finished · last 2h · user=bob · nothing in this window" && squeue_env_clean'
	orun empty SQUEUE_PARTITION=gpu --
	need "SQUEUE_PARTITION=gpu: Q -p gpu, S -a -r gpu, part=gpu" eval '
		rc_is 0 && q_is -p gpu && s_is -a -r gpu && caption_is "recently finished · last 2h · part=gpu · nothing in this window" && squeue_env_clean'
	orun empty SQUEUE_ACCOUNT=acct1 --
	need "SQUEUE_ACCOUNT=acct1: Q -A acct1, S -a -A acct1, acct=acct1" eval '
		rc_is 0 && q_is -A acct1 && s_is -a -A acct1 && caption_is "recently finished · last 2h · acct=acct1 · nothing in this window" && squeue_env_clean'
	orun empty SQUEUE_QOS=long --
	need "SQUEUE_QOS=long: Q -q long, S -a -q long, qos=long" eval '
		rc_is 0 && q_is -q long && s_is -a -q long && caption_is "recently finished · last 2h · qos=long · nothing in this window" && squeue_env_clean'
	orun empty SLURM_CLUSTERS=c1 --
	need "SLURM_CLUSTERS=c1: no -M word in Q, the variable in its env; S -a -M c1, cluster=c1" eval '
		rc_is 0 && q_is && [ "$(env_of squeue 1 SLURM_CLUSTERS)" = c1 ] && s_is -a -M c1 &&
		caption_is "recently finished · last 2h · cluster=c1 · nothing in this window" && squeue_env_clean'
	orun empty SQUEUE_STATES=R --
	need "SQUEUE_STATES=R: Q -t R, S without it, no filter on the caption" eval '
		rc_is 0 && q_is -t R && s_is -a && caption_is "recently finished · last 2h · nothing in this window" && squeue_env_clean'
	orun noacct SQUEUE_NAMES=x --
	need "SQUEUE_NAMES=x, noacct: Q -n x, no S, F -h -n x -t all, the caption names the variable" eval '
		rc_is 0 && q_is -n x && calls_are 1 1 1 0 && f_is -n x &&
		caption_is "recently finished · recent only (sq does not translate SQUEUE_NAMES for sacct)" && squeue_env_clean'
	orun noacct SQUEUE_LICENSES=m --
	need "SQUEUE_LICENSES=m, noacct: Q -L m, no S, F -h -L m -t all, the caption names the variable" eval '
		rc_is 0 && q_is -L m && calls_are 1 1 1 0 && f_is -L m &&
		caption_is "recently finished · recent only (sq does not translate SQUEUE_LICENSES for sacct)" && squeue_env_clean'
	orun empty SQUEUE_PARTITION=gpu SQUEUE_USERS=bob --
	need "SQUEUE_PARTITION=gpu SQUEUE_USERS=bob: Q -p gpu -u bob, S -r gpu -u bob, part=gpu · user=bob (squeue's order)" eval '
		rc_is 0 && q_is -p gpu -u bob && s_is -r gpu -u bob &&
		caption_is "recently finished · last 2h · part=gpu · user=bob · nothing in this window" && squeue_env_clean'
}
c_opts_env_flags() {   # AC2
	T_TITLE="squeue's environment flags, set at all, are their flags, before argv's (squeue's order): -a -r -P --local --federation --sibling"
	local f
	for f in SQUEUE_ALL=1 SQUEUE_ALL=; do
		orun empty "$f" --
		need "$f: Q -S t,i -a, S as without it, last 2h" eval 'rc_is 0 && q_is -a && s_is -a && caption_is "recently finished · last 2h · nothing in this window" && squeue_env_clean'
	done
	orun empty SQUEUE_LOCAL= --
	need "SQUEUE_LOCAL=: Q --local, S --local, last 2h" eval 'rc_is 0 && q_is --local && s_is -a --local && has "recently finished · last 2h" && squeue_env_clean'
	orun empty SQUEUE_FEDERATION= --
	need "SQUEUE_FEDERATION=: Q --federation, S --federation, last 2h" eval 'rc_is 0 && q_is --federation && s_is -a --federation && has "recently finished · last 2h" && squeue_env_clean'
	for f in SQUEUE_SIB SQUEUE_SIBLING; do
		orun noacct "$f=1" --
		need "$f=1, noacct: Q --sibling, F --sibling, no S, the caption names $f" eval '
			rc_is 0 && q_is --sibling && f_is --sibling && calls_are 1 1 1 0 &&
			caption_is "recently finished · recent only (sq does not translate $f for sacct)" && squeue_env_clean'
	done
	orun noacct SQUEUE_SIB=1 SQUEUE_SIBLING=1 --
	need "both set: one --sibling, SQUEUE_SIB named" eval '
		rc_is 0 && q_is --sibling && f_is --sibling && caption_is "recently finished · recent only (sq does not translate SQUEUE_SIB for sacct)"'
	orun empty SQUEUE_PRIORITY=1 --
	need "SQUEUE_PRIORITY=1: Q -P, S without it" eval 'rc_is 0 && q_is -P && s_is -a && squeue_env_clean'
	orun empty SQUEUE_ARRAY= --
	need "SQUEUE_ARRAY=: Q -r, S --array" eval 'rc_is 0 && q_is -r && s_is -a --array && squeue_env_clean'
	orun empty SQUEUE_ALL=1 -- --hide
	need "SQUEUE_ALL=1 with --hide: Q -a --hide, the variable first" eval 'rc_is 0 && q_is -a --hide'
	orun empty SQUEUE_PARTITION=main -- --hide
	need "SQUEUE_PARTITION=main with --hide: Q --hide -p main, the variable after argv" eval 'rc_is 0 && q_is --hide -p main'
	orun empty -- --all --hide --all
	need "--all --hide --all: Q -a --hide -a, every one" eval 'rc_is 0 && q_is -a --hide -a'
}
c_opts_flag_beats_env() {   # AC3
	T_TITLE="a flag beats its environment variable: only the flag reaches squeue, sacct and the caption"
	local login; login=$(login_of_stub)
	orun empty SQUEUE_USERS=bob -- -u alice
	need "SQUEUE_USERS=bob -u alice: Q -u alice only, S -u alice, user=alice" eval '
		rc_is 0 && q_is -u alice && s_is -u alice && has "recently finished · last 2h · user=alice ·"'
	orun empty SQUEUE_USERS=bob -- --me
	need "SQUEUE_USERS=bob --me: Q --me, S -u <login>" eval 'rc_is 0 && q_is --me && s_is -u "$login"'
	orun empty SQUEUE_ACCOUNT=a -- -U b
	need "SQUEUE_ACCOUNT=a -U b: Q -A b" eval 'rc_is 0 && q_is -A b && s_is -a -A b'
	orun empty SQUEUE_PARTITION=a -- --partition=b
	need "SQUEUE_PARTITION=a --partition=b: Q -p b" eval 'rc_is 0 && q_is -p b && s_is -a -r b'
	orun empty SLURM_CLUSTERS=c1 -- -M c2
	need "SLURM_CLUSTERS=c1 -M c2: Q -M c2, S -M c2, cluster=c2" eval '
		rc_is 0 && q_is -M c2 && s_is -a -M c2 && has "recently finished · last 2h · cluster=c2 ·"'
	orun empty SQUEUE_STATES=PD -- -t R
	need "SQUEUE_STATES=PD -t R: Q -t R" eval 'rc_is 0 && q_is -t R'
}
c_opts_env_refused() {   # AC4
	T_TITLE="squeue's environment stops sq where squeue would show no job or fail: empty or hollow filters, SHAPE, D4, SLURM_CLUSTERS under -M too; argv first, subcommands and -h never"
	local login; login=$(login_of_stub)
	o_refused "SQUEUE_USERS is set but holds no user name; unset it, or set one, e.g. SQUEUE_USERS=$login" SQUEUE_USERS= --
	o_refused "SQUEUE_USERS is set but holds no user name; unset it, or set one, e.g. SQUEUE_USERS=$login" "SQUEUE_USERS= " --
	o_refused "SQUEUE_PARTITION is set but holds no partition name; unset it, or set one, e.g. SQUEUE_PARTITION=batch" SQUEUE_PARTITION=, --
	o_refused "SQUEUE_STATES is set but holds no state list; unset it, or set one, e.g. SQUEUE_STATES=R,PD" SQUEUE_STATES=$'\t' --
	o_refused "SLURM_CLUSTERS is set but holds no cluster name; unset it, or set one, e.g. SLURM_CLUSTERS=mycluster" SLURM_CLUSTERS= --
	o_refused "SQUEUE_ACCOUNT is set but holds no account name; unset it, or set one, e.g. SQUEUE_ACCOUNT=myaccount" "SQUEUE_ACCOUNT= , " --
	o_refused "SQUEUE_QOS is set but holds no QoS name; unset it, or set one, e.g. SQUEUE_QOS=normal" SQUEUE_QOS= --
	o_refused "SQUEUE_NAMES is set but holds no job name; unset it, or set one, e.g. SQUEUE_NAMES=myjob" SQUEUE_NAMES= --
	o_refused "SQUEUE_LICENSES is set but holds no license name; unset it, or set one, e.g. SQUEUE_LICENSES=matlab" SQUEUE_LICENSES=, --
	o_refused "SQUEUE_USERS needs a user name, not '-x'; unset it, or set one, e.g. SQUEUE_USERS=$login" SQUEUE_USERS=-x --
	o_refused "SQUEUE_PARTITION needs a partition name, not ' -x'; unset it, or set one, e.g. SQUEUE_PARTITION=batch" "SQUEUE_PARTITION= -x" --
	orun empty SQUEUE_NAMES=-x --
	need "SQUEUE_NAMES=-x: accepted, Q -n -x" eval 'rc_is 0 && q_is -n -x'
	local d4="means different things in different Slurm versions (23.11 ignores it under -p and lets it beat -L); unset it, or give the licenses as -L"
	o_refused "SQUEUE_LICENSES together with -L $d4" SQUEUE_LICENSES=x -- -L y
	o_refused "SQUEUE_LICENSES together with -p $d4" SQUEUE_LICENSES=x -- -p main
	o_refused "SQUEUE_LICENSES together with --partitions $d4" SQUEUE_LICENSES=x -- --partitions=main
	o_refused "SQUEUE_LICENSES together with -L $d4" SQUEUE_LICENSES= -- -L y
	o_refused "SQUEUE_LICENSES together with -p $d4" SQUEUE_LICENSES=x -- -p main -L y
	orun empty SQUEUE_LICENSES=x SQUEUE_PARTITION=main --
	need "SQUEUE_LICENSES=x SQUEUE_PARTITION=main: rc 0, Q -L x -p main" eval 'rc_is 0 && q_is -L x -p main'
	o_refused "SLURM_CLUSTERS is set but holds no cluster name; unset it, or set one, e.g. SLURM_CLUSTERS=mycluster" SLURM_CLUSTERS= -- -M c2
	o_refused "SLURM_CLUSTERS needs a cluster name, not '-x'; unset it, or set one, e.g. SLURM_CLUSTERS=mycluster" SLURM_CLUSTERS=-x --
	o_refused "SLURM_CLUSTERS needs a cluster name, not '-x'; unset it, or set one, e.g. SLURM_CLUSTERS=mycluster" SLURM_CLUSTERS=-x -- -M c2
	# not refused, as at 1eb0218: a flag overrides it, or nothing reads it
	orun empty SQUEUE_USERS= -- -u alice
	need "SQUEUE_USERS= -u alice: rc 0, Q -u alice" eval 'rc_is 0 && q_is -u alice'
	orun empty SQUEUE_USERS= -- --me
	need "SQUEUE_USERS= --me: rc 0, Q --me" eval 'rc_is 0 && q_is --me'
	local h
	for h in -h --help; do
		sq_run empty SQUEUE_USERS= -- "$h"
		need "SQUEUE_USERS= $h: the help, rc 0" eval 'rc_is 0 && has "auto-fitting Slurm dashboard" && err_empty'
	done
	sq_run "$(log_fx envdone <<'EOF'
StateCompact=CD
@file create wd/out_500.log done\n
EOF
)" SQUEUE_USERS= -- log --no-follow 500
	need "SQUEUE_USERS= log 500: sq log runs, the file" eval 'rc_is 0 && [ "$(cat "$OUT")" = done ]'
	job_run running-own SQUEUE_USERS= -- --no-color job 11950
	need "SQUEUE_USERS= job 11950: sq job runs, rc 0" eval 'rc_is 0 && has "11950" && ! grep -q SQUEUE_USERS "$ERR"'
	o_refused "-v prints squeue's own parameters into the output sq parses" SQUEUE_USERS= -- -v
}
c_opts_env_inert() {   # AC5, AC6, AC7
	T_TITLE="unknown SQUEUE_* names stay with squeue, SQUEUE_SORT is unset, SACCT_* leave the dashboard's sacct (that call alone), --noheader keeps sacct and reaches no call"
	orun empty SQUEUE_FOO=1 SQUEUE_USER=bob --
	need "SQUEUE_FOO=1 SQUEUE_USER=bob: S called, last 2h, no fallback, Q carries both" eval '
		rc_is 0 && calls_are 1 1 0 1 && s_is -a && has "recently finished · last 2h" &&
		[ "$(env_of squeue 1 SQUEUE_FOO)" = 1 ] && [ "$(env_of squeue 1 SQUEUE_USER)" = bob ]'
	orun memalloc SQUEUE_FOO=1 SQSTUB_UID=1041 --
	need "... as fsill with MEM: JOBMEM's allocation call without it, the mirror call after it with it again (unexported for that call alone)" eval '
		rc_is 0 && [ "$(calls alloc)" = 1 ] && [ "$(calls mirror)" = 1 ] &&
		! grep "^CALL	squeue	" "$LOG" | grep "StateCompact" | grep "tres-alloc" | grep -q "SQUEUE_FOO" &&
		grep "^CALL	squeue	" "$LOG" | grep "tres-alloc" | grep -v "StateCompact" | grep -q "	SQUEUE_FOO=1"'
	orun empty SQUEUE_SORT=x --
	need "SQUEUE_SORT=x: rc 0, last 2h, no call carries it" eval '
		rc_is 0 && calls_are 1 1 0 1 && has "recently finished · last 2h" && ! grep "^CALL" "$LOG" | grep -q SQUEUE_SORT'
	orun empty SACCT_FEDERATION=1 SACCT_LOCAL=1 SACCT_FORMAT=x --
	need "SACCT_FEDERATION SACCT_LOCAL SACCT_FORMAT: S carries none, last 2h" eval '
		rc_is 0 && s_is -a && has "recently finished · last 2h" && ! grep "^CALL	sacct" "$LOG" | grep -q SACCT_'
	orun sacct-fails SACCT_FEDERATION=1 SACCT_FORMAT=x --
	need "... sacct failing: S carries none, the fallback after it both again (unset for sacct's call alone)" eval '
		rc_is 0 && calls_are 1 1 1 1 && ! grep "^CALL	sacct" "$LOG" | grep -q SACCT_ &&
		fb=$(grep "^CALL	squeue	.* -t all " "$LOG") && [[ $fb == *"	SACCT_FEDERATION=1"* ]] && [[ $fb == *"	SACCT_FORMAT=x"* ]]'
	job_run running-own SACCT_FEDERATION=1 SACCT_LOCAL=1 SACCT_FORMAT=x -- --no-color job 11950
	need "... sq job 11950 as at 1eb0218: rc 0, its sacct calls without them" eval '
		rc_is 0 && [ "$(calls sacct)" -ge 1 ] && ! grep "^CALL	sacct" "$LOG" | grep -q SACCT_'
	orun empty -- --noheader
	need "--noheader: S called, last 2h, no call holds --noheader" eval '
		rc_is 0 && calls_are 1 1 0 1 && q_is && has "recently finished · last 2h" && ! grep "^CALL" "$LOG" | grep -q -- --noheader'
}
c_opts_sort() {   # AC8
	T_TITLE="-S reaches squeue after sq's own sort and keeps sacct; '' and , accepted, a blank anywhere refused"
	local v
	for v in -i '' ,; do
		orun empty -- -S "$v"
		need "-S '$v': S called, last 2h, Q -S t,i -S '$v'" eval 'rc_is 0 && calls_are 1 1 0 1 && s_is -a && has "recently finished · last 2h" && q_is -S "$v"'
	done
	for v in ' ' $'\t' $'\n' ' ,' 'i, j'; do
		o_refused "-S needs a sort key list without blanks; e.g. sq -S -i" -- -S "$v"
	done
	o_refused "--sort needs a sort key list without blanks; e.g. sq --sort -i" -- --sort='a b'
}
c_opts_rd7_flags() {   # AC9
	T_TITLE="-a, --all, --hide, SQUEUE_ALL keep sacct as without them; --local and --federation reach sacct; MEM %m under --federation"
	local f
	for f in --all -a --hide SQUEUE_ALL=1; do
		case $f in -*) orun empty -- "$f" ;; *) orun empty "$f" -- ;; esac
		need "$f: S as without it (its own -a for all users only), last 2h" eval 'rc_is 0 && calls_are 1 1 0 1 && s_is -a && has "recently finished · last 2h"'
	done
	for f in --local SQUEUE_LOCAL=; do
		case $f in -*) orun empty -- "$f" ;; *) orun empty "$f" -- ;; esac
		need "$f: S holds --local, last 2h" eval 'rc_is 0 && calls_are 1 1 0 1 && s_is -a --local && has "recently finished · last 2h"'
	done
	for f in --federation SQUEUE_FEDERATION=; do
		case $f in -*) orun empty -- "$f" ;; *) orun empty "$f" -- ;; esac
		need "$f: S holds --federation, last 2h" eval 'rc_is 0 && calls_are 1 1 0 1 && s_is -a --federation && has "recently finished · last 2h"'
		case $f in -*) mem_run jobmem SQ_WIDTH=110 -- --color "$f" ;; *) mem_run jobmem SQ_WIDTH=110 "$f" -- --color ;; esac
		need "$f, jobmem as fsill: MEM %m, no allocation, mirror or sstat call, S with --federation" eval '
			rc_is 0 && [ "$(calls alloc)$(calls mirror)$(calls sstat)" = 000 ] && s_is -a --federation'
	done
	orun empty -- --local --federation --array
	need "--local --federation --array: S … --array --local --federation -o …" eval 'rc_is 0 && s_is -a --array --local --federation && q_is --local --federation -r'
}
c_opts_clusters() {   # AC10
	T_TITLE="letters run together are refused with one sentence, no advice; SUBCMD-v3's 'cannot tell' only where it pins it"
	local w apart="runs options together; write each option as its own word"
	for w in -ar -ah -av -al -aV -xc -cC -Pr -vx -vh -az -zx -foo -atR -aufsill -atPD,R -aupeter.smith -ai5 -as -a-u -ab=c; do
		o_refused "'$w' $apart" -- "$w"
	done
	o_refused "'-atR' $apart" -- -atR foo
	o_refused "'-ah' $apart" -- -ah x
	o_refused "'-hu' $apart" -- -hu fsill
	o_refused "'-ar' $apart" -- -ar -u x
	o_refused "'-ar' $apart" -- -ar ''
	o_refused "'-ar' $apart" -- -ar ' '
	o_refused "'-ab' $apart" -- "-a"$'\342\200\256'"b"
	o_refused "'-arrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr' $apart" -- "-a$(printf 'r%.0s' {1..200})"
	o_refused "cannot tell what 'i' belongs to after '-ao'; write the options apart, e.g. -a -o i" -- -ao i
	o_refused "cannot tell what '5' belongs to after '-aj'; write the options apart, e.g. -a -j 5" -- -aj 5
	o_refused "cannot tell what 'log' belongs to after '-xn'; write the options apart, e.g. -x -n log" -- -xn log
	o_refused "cannot tell what 'log' belongs to after '-xc'; write the options apart, e.g. -x -c log" -- -xc log 500
	o_twin
}
c_opts_short_words() {   # AC11
	T_TITLE="other short words: unknown letters, long names with one dash (N2a first), '=' after a valueless letter, no option letter at all (a tab, a surrogate, beyond U+10FFFF); the echo scrubbed, then cut to 40"
	local w
	for w in -z -e -5; do o_refused "$w is not one of the short options sq forwards; sq -h lists them" -- "$w"; done
	o_refused "subcommands come first: sq log …" -- -Z log 500
	for w in all me hide full color; do o_refused "'-$w' is not an option; did you mean --$w?" -- "-$w"; done
	o_refused "'-all=1' is not an option; did you mean --all? (it takes no value)" -- -all=1
	o_refused "'-me=x' is not an option; did you mean --me? (it takes no value)" -- -me=x
	o_refused "'-color=never' is not an option; did you mean --color? (it takes no value)" -- -color=never
	o_refused "'-help=x' is not an option; did you mean --help? (it takes no value)" -- -help=x
	for w in partition users qos noheader no-recent nodelist priority sib sort states jobs format; do
		o_refused "'-$w' is not an option; did you mean --$w?" -- "-$w"
	done
	o_refused "'-partition=gpu' is not an option; did you mean --partition=gpu?" -- -partition=gpu
	o_refused "'-name' is not an option; did you mean --name?" -- -name x
	o_refused "--steps lists job steps, which sq cannot frame safely; sq shows jobs" -- -steps
	o_refused "--iterate repeats squeue's own output; sq refreshes with 'watch -tc -n 5 sq'" -- -iterate
	o_refused "--json asks squeue for a machine-readable document, which sq cannot render; run 'squeue --json' for that" -- -json
	for w in usage autocomplete long verbose version start; do
		o_refused "--$w is not one of the long options sq forwards; sq -h lists them" -- "-$w"
	done
	orun empty -- -n -name
	need "-n -name: ROLE took the word, rc 0, Q -n -name" eval 'rc_is 0 && q_is -n -name'
	o_refused "-u needs a user name, not '-users'; e.g. sq -u $(login_of_stub)" -- -u -users
	o_refused "-x takes no value; write it on its own, e.g. sq -x" -- -x=
	o_refused "-a takes no value; write it on its own, e.g. sq -a" -- -a=b
	o_refused "-v prints squeue's own parameters into the output sq parses" -- -v=
	o_refused "'- a' holds a space, which is not an option letter" -- "- a"
	o_refused "'-x' holds U+202E, which is not an option letter" -- "-"$'\342\200\256'"x"
	o_refused "'-ä' holds U+00E4, which is not an option letter" LC_ALL=C -- "-ä"
	o_refused "'-␚' holds byte 0xE4, which is not an option letter" -- "-"$'\xe4'
	# R2 9 (OPTS L1): N2c names a tab, and no valid UTF-8 by its first byte:
	# a surrogate, a code point above U+10FFFF; the code points beside them by
	# their U+ name
	o_refused "'-' holds a tab, which is not an option letter" -- $'-\t'
	o_refused "'-␚␚␚' holds byte 0xED, which is not an option letter" -- $'-\xed\xa0\x80'
	local cp
	for cp in D7FF:$'\xed\x9f\xbf' E000:$'\xee\x80\x80' 10FFFF:$'\xf4\x8f\xbf\xbf'; do
		o_refused "'-${cp#*:}' holds U+${cp%%:*}, which is not an option letter" -- "-${cp#*:}"
	done
	o_refused "'-␚␚␚␚' holds byte 0xF4, which is not an option letter" -- $'-\xf4\x90\x80\x80'
	# R2 9b (OPTS L2): a refused word is scrubbed, then cut to 40 characters:
	# bidi controls and C0 among its first 40 go, and 40 clean ones show
	local b40; b40=$(printf 'b%.0s' {1..40})
	o_refused "'-ax${b40:0:37}' runs options together; write each option as its own word" -- "-ax"$'\u202e\u202e\u202e\u202e\u202e'"$b40"
	o_refused "'-ax${b40:0:37}' runs options together; write each option as its own word" -- "-ax"$'\x01\x02\x03'"$b40"
	o_refused "-i repeats squeue's own output; sq refreshes with 'watch -tc -n 5 sq'" -- -i
	o_refused "-s lists job steps, which sq cannot frame safely; sq shows jobs" -- -s
}
c_opts_equals() {   # AC12
	T_TITLE="a value attached with '=' is refused, its example the value when short, plain and valid, else the option's own"
	local login; login=$(login_of_stub)
	o_refused "-p takes its value without '='; e.g. sq -p batch" -- -p=batch
	o_refused "-p takes its value without '='; e.g. sq -p batch" -- -p=
	o_refused "-u takes its value without '='; e.g. sq -u fsill" -- -u=fsill
	o_refused "-u takes its value without '='; e.g. sq -u $login" -- -u=-x
	o_refused "-p takes its value without '='; e.g. sq -p batch" -- "-p=a b"
	o_refused "-j takes its value without '='; e.g. sq -j 5" -- -j=5
	o_refused "-S takes its value without '='; e.g. sq -S -i" -- -S=-i
	o_refused "-S takes its value without '='; e.g. sq -S -i" -- -S=
	o_refused "-o takes its value without '='; e.g. sq -o i" -- -o=i
	o_refused "-o takes its value without '='; e.g. sq -o i,j,u" -- -o=
	o_refused "-o takes its value without '='; e.g. sq -o i,j,u" -- -o=%s
	o_refused "-p takes its value without '='; e.g. sq -p batch" -- "-p=x;id"
	o_refused "-p takes its value without '='; e.g. sq -p batch" -- "-p=$(printf 'a%.0s' {1..41})"
	o_refused "-p takes its value without '='; e.g. sq -p batch" -- "-p="$'\342\200\256'"x"
	local w
	for w in "-n =x" "--name==x"; do
		orun empty -- $w
		need "$w: accepted, Q -n =x" eval 'rc_is 0 && q_is -n =x'
	done
}
c_opts_empty_blank() {   # AC13
	T_TITLE="an empty value, or one of only blanks and commas, is refused for every filter in every spelling, and for -o/--format"
	local spec key long v opt sp
	local -A vex=([-u]=$(login_of_stub) [-p]=batch [-A]=myaccount [-U]=myaccount [-q]=normal [-j]=12345 [-M]=mycluster
	              [-n]=myjob [-t]=R,PD [-w]=node01 [-L]=matlab [-R]=maint)
	local -A noun=([-u]='a user name' [-p]='a partition name' [-A]='an account name' [-U]='an account name' [-q]='a QoS name'
	               [-j]='a job id' [-M]='a cluster name' [-n]='a job name' [-t]='a state list' [-w]='a node list'
	               [-L]='a license name' [-R]='a reservation name')
	for spec in -u:--user -p:--partition -A:--accounts -U: -q:--qos -j:--jobs -M:--clusters -n:--name -t:--states \
	            -w:--nodelist -L:--license -R:--reservation; do
		key=${spec%%:*} long=${spec#*:}
		for v in '' ' ' $'\t' ',' ' , ' $'\n' $' \t,\r'; do
			for sp in short attached longeq longsp; do
				case $sp in
					short) opt=$key; set -- "$key" "$v" ;;
					attached) [ -n "$v" ] || continue; opt=$key; set -- "$key$v" ;;
					longeq) [ -n "$long" ] || continue; opt=$long; set -- "$long=$v" ;;
					longsp) [ -n "$long" ] || continue; opt=$long; set -- "$long" "$v" ;;
				esac
				if [ -z "$v" ]; then o_refused "$opt needs ${noun[$key]}, e.g. sq $opt ${vex[$key]}" -- "$@"
				else o_refused "$opt needs ${noun[$key]}, not just blanks or commas; e.g. sq $opt ${vex[$key]}" -- "$@"; fi
			done
		done
	done
	o_refused "-o needs a column list, e.g. -o i,j,u" -- -o ''
	o_refused "--format needs a column list, e.g. -o i,j,u" -- --format=
	o_refused "--format needs a column list, e.g. -o i,j,u" -- --format ''
	o_refused "-o needs a column list, not just blanks or commas; e.g. -o i,j,u" -- -o ' , '
	o_twin
}
c_opts_canonical() {   # AC14
	T_TITLE="every spelling reaches squeue as its short letter and the value as the next word (-j as --jobs=), sacct and the caption as the short form"
	local spec spelling canon short
	# spelling|the queue call's words|the short form, which gives sacct and the caption
	for spec in "--partition=gpu|-p gpu|-p gpu" "--partitions gpu|-p gpu|-p gpu" "-pgpu|-p gpu|-p gpu" \
	            "--account x|-A x|-A x" "--accounts=x|-A x|-A x" "-U x|-A x|-A x" "-Ux|-A x|-A x" \
	            "--job 5|--jobs=5|-j 5" "--jobs=5|--jobs=5|-j 5" "-j5|--jobs=5|-j 5" "-j 5|--jobs=5|-j 5" \
	            "--state R|-t R|-t R" "--states=R|-t R|-t R" "-tR|-t R|-t R" \
	            "--license m|-L m|" "--node n1|-w n1|" "--nodes=n1|-w n1|" "--nodelist n1|-w n1|" "--name=x|-n x|" \
	            "--reservation=x|-R x|" "--reservation x|-R x|" "--sort=-i|-S -i|-S -i" \
	            "--user x|-u x|-u x" "--users=x|-u x|-u x" "--cluster c|-M c|-M c" "--clusters=c|-M c|-M c" "--qos=q|-q q|-q q" \
	            "--all|-a|-a" "--array|-r|-r" "--priority|-P|-P" "--sib|--sibling|" "--sibling|--sibling|" \
	            "--me|--me|--me" "--hide|--hide|--hide" "--noconvert|--noconvert|--noconvert" \
	            "--federation|--federation|--federation" "--local|--local|--local"; do
		IFS='|' read -r spelling canon short <<< "$spec"
		local -a sw cw ow; read -r -a sw <<< "$spelling"; read -r -a cw <<< "$canon"; read -r -a ow <<< "$short"
		orun empty -- "${sw[@]}"
		need "$spelling: Q -h -S t,i $canon" eval 'rc_is 0 && q_is "${cw[@]}"'
		if [ -n "$short" ]; then
			local sline cap; sline=$(gawk -F'\t' '$1 == "CALL" && $2 == "sacct" { print $3 }' "$LOG" | sed -E 's/N[0-9a-f]{24}//'); cap=$(section recent | head -n 1)
			orun empty -- "${ow[@]}"
			need "$spelling: S and the caption as for $short" eval '
				[ "$sline" = "$(gawk -F"\t" "\$1 == \"CALL\" && \$2 == \"sacct\" { print \$3 }" "$LOG" | sed -E "s/N[0-9a-f]{24}//")" ] &&
				[ "$cap" = "$(section recent | head -n 1)" ]'
		else
			need "$spelling: the fallback, the caption naming ${sw[0]%%=*}" eval '
				calls_are 1 1 1 0 && caption_is "recently finished · recent only (sq does not translate ${sw[0]%%=*} for sacct)"'
		fi
	done
}
c_opts_dash_values() {   # AC15
	T_TITLE="-n -t -w -L -R -S take a value beginning with '-', which reaches squeue as its own word, byte for byte"
	local spec
	for spec in "-n -foo" "-t -x" "-w -n1" "-L -m" "-R -r" "-S -i"; do
		orun empty -- $spec
		need "$spec: rc 0, Q $spec" eval 'rc_is 0 && q_is $spec'
	done
	orun empty -- --sort=-i
	need "--sort=-i: rc 0, Q -S -i" eval 'rc_is 0 && q_is -S -i'
}
c_opts_kept_pins() {   # AC16
	T_TITLE="the refusals that stand: SHAPE (blanks first too), --me=x, --partition=, a value that looks like an option"
	local login; login=$(login_of_stub)
	o_refused "-u needs a user name, not '-x'; e.g. sq -u $login" -- -u -x
	o_refused "-u needs a user name, not ' -x'; e.g. sq -u $login" -- '-u -x'
	o_refused "--me takes no value; write it on its own, e.g. sq --me" -- --me=x
	o_refused "--partition needs a partition name, e.g. sq --partition batch" -- --partition=
	o_refused "-u needs a user name, not '--me'; e.g. sq -u $login" -- -u --me
	o_refused "-u needs a user name, not '--expand'; e.g. sq -u $login" -- -u --expand
	o_refused "-U needs an account name, not '-x'; e.g. sq -U myaccount" -- -U -x
	o_twin
}
c_opts_jobid() {   # AC17
	T_TITLE="-j takes job ids squeue takes, N or N_T, no leading zero, up to 2147483647; the -j N M hint only where N,M would be one"
	local v
	for v in 0 a 5, 5,,6 5abc '5 ' '123_[1-3]' 123+1 2147483648 05 6_03; do
		o_refused "-j needs job ids like 12345 or 12345_4, not '$v'; e.g. sq -j 12345" -- -j "$v"
	done
	o_refused "-j needs job ids like 12345 or 12345_4, not 'a'; e.g. sq -j 12345" -- -ja
	o_refused "--jobs needs job ids like 12345 or 12345_4, not '0'; e.g. sq -j 12345" -- --jobs=0
	o_refused "-j needs a job id, not just blanks or commas; e.g. sq -j 12345" -- -j ,
	for v in 5 5,6_3 2147483647 6_0; do
		orun empty -- -j "$v"
		need "-j $v: rc 0, Q --jobs=$v, S -j $v" eval 'rc_is 0 && q_is --jobs="$v" && s_is -a -j "$v"'
	done
	o_refused "'6' is not a subcommand; sq -h lists them (did you mean sq -j 5,6?)" -- -j 5 6
	o_refused "'6+1' is not a subcommand; sq -h lists them" -- -j 5 6+1
	o_refused "'0' is not a subcommand; sq -h lists them" -- -j 5 0
}
c_opts_repeat() {   # AC18
	T_TITLE="a filter set twice in any spelling is refused naming the second, its example a real list (-R: one reservation, named so); -u/--me and -A/-U are one key; the environment never repeats, -S may"
	local login; login=$(login_of_stub) tail="squeue would keep only the last one, so write one list instead, e.g. sq"
	o_refused "-u sets the same filter twice; $tail -u $login,alice" -- -u a -ub
	o_refused "--partition sets the same filter twice; $tail -p batch,gpu" -- -p a --partition=b
	o_refused "--states sets the same filter twice; $tail -t R,PD" -- -t R --states PD
	o_refused "-n sets the same filter twice; $tail -n myjob,otherjob" -- -n a -n b
	o_refused "--nodelist sets the same filter twice; $tail -w node01,node02" -- -w a --nodelist=b
	o_refused "-L sets the same filter twice; $tail -L matlab,ansys" -- -L a -L b
	o_refused "--reservation sets the same filter twice; squeue would keep only the last one, so name one reservation, e.g. sq -R maint" -- -R a --reservation b
	o_refused "-R sets the same filter twice; squeue would keep only the last one, so name one reservation, e.g. sq -R maint" -- -R a -R b
	o_refused "--me sets the same filter twice; $tail -u $login,alice" -- --me --me
	o_refused "--me sets the same filter twice; $tail -u $login,alice" -- -u b --me
	o_refused "-u sets the same filter twice; $tail -u $login,alice" -- --me -u b
	o_refused "-U sets the same filter twice; $tail -A acct1,acct2" -- -A a -U b
	orun empty SQUEUE_USERS=a -- -u b
	need "SQUEUE_USERS=a -u b: no repeat, Q -u b" eval 'rc_is 0 && q_is -u b'
	orun empty -- -S a -S b
	need "-S a -S b: no repeat, Q -S t,i -S a -S b" eval 'rc_is 0 && q_is -S a -S b'
}
c_opts_check_order() {   # AC19
	T_TITLE="each word is checked as it is read, so the first bad one wins; the environment after the column letters"
	o_refused "-u needs a user name, e.g. sq -u $(login_of_stub)" -- -u '' -h
	sq_run empty -- -h -u ''
	need "-h -u '': the help, rc 0" eval 'rc_is 0 && has "auto-fitting Slurm dashboard" && err_empty'
	o_refused "-p needs a partition name, e.g. sq -p batch" -- -p '' -z
	o_refused "-z is not one of the short options sq forwards; sq -h lists them" -- -z -p ''
	o_refused "-u needs a user name, e.g. sq -u $(login_of_stub)" -- -u '' log 5
	o_refused "%s is not a squeue field letter (in -o 'i,%s')" SQUEUE_USERS= -- -o i,%s
	o_twin
}
c_opts_sub_placement() {   # AC20
	T_TITLE="-a -r -P take no value, so a subcommand may follow them, as after --all; -U takes one"
	local fx f; fx=$(log_fx done <<'EOF'
StateCompact=CD
@file create wd/out_500.log done\n
EOF
)
	for f in -a --all -r -P; do
		sq_run "$fx" -- "$f" log --no-follow 500
		need "$f log 500: sq log runs, the file" eval 'rc_is 0 && [ "$(cat "$OUT")" = done ] && argv_has squeue -h --jobs=500 -t all'
	done
	o_refused "subcommands come first, before any option that takes a value: sq log …" -- -U x log 500
	o_refused "'6' is not a subcommand; sq -h lists them (did you mean sq -j 5,6?)" -- --jobs=5 6
}
c_opts_o_attached() {   # AC21
	T_TITLE="-oLIST and --format=LIST are sq's -o; -O and --Format stay refused"
	local rlo=$'\342\200\256' base
	orun wide -- -o i,j,u; base=$RUN/base; without_clock "$OUT" > "$base"
	orun wide -- -oi,j,u
	need "-oi,j,u: the screen of -o i,j,u" eval 'rc_is 0 && cmp -s "$base" <(without_clock "$OUT")'
	orun wide -- --format i,j; without_clock "$OUT" > "$base"
	orun wide -- --format=i,j
	need "--format=i,j: the screen of --format i,j" eval 'rc_is 0 && cmp -s "$base" <(without_clock "$OUT")'
	orun wide -- -o i; without_clock "$OUT" > "$base"
	orun wide -- -o%.10i
	need "-o%.10i: the screen of -o i" eval 'rc_is 0 && cmp -s "$base" <(without_clock "$OUT")'
	orun wide -- -o u; without_clock "$OUT" > "$base"
	orun wide -- "-o${rlo}u"
	need "-o+RLO+u: the screen of -o u" eval 'rc_is 0 && err_empty && cmp -s "$base" <(without_clock "$OUT")'
	o_refused "-Oi would override sq's own output format; write the column list as 'sq -o i,j,u'" -- -Oi
	o_refused "--Format=i would override sq's own output format; write the column list as 'sq -o i,j,u'" -- --Format=i
	o_refused "-O would override sq's own output format; write the column list as 'sq -o i,j,u'" -- -O i
}
c_opts_fallback_source() {   # AC22
	T_TITLE="the fallback's caption names the first entry sacct has no mapping for, by its source, without its value"
	local spec args src
	for spec in "-nxy|-n" "--name=x|--name" "-n x --sibling|-n" "--sibling -n x|--sibling"; do
		IFS='|' read -r args src <<< "$spec"
		orun noacct -- $args
		need "noacct, $args: the caption names $src" eval '
			rc_is 0 && calls_are 1 1 1 0 && caption_is "recently finished · recent only (sq does not translate $src for sacct)"'
	done
	orun noacct SQUEUE_SIB=1 -- -n x
	need "noacct, SQUEUE_SIB=1 -n x: the pre-loop variable comes first" eval '
		rc_is 0 && caption_is "recently finished · recent only (sq does not translate SQUEUE_SIB for sacct)"'
	sq_run noacct SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact --reservation=x
	need "COMPACT, --reservation=x: its one line names --reservation" \
		fin_line_is "recently finished (sq does not translate --reservation for sacct): 4188 qc FAILED 1"
	sq_run "$(silent_fixture squeue-all 1 'squeue: error: the fallback says why')" -- -n x
	need "both paths gone, -n x: 'finished jobs unavailable · sq does not translate -n for sacct'" \
		eval 'rc_is 0 && has "finished jobs unavailable · sq does not translate -n for sacct"'
}
c_opts_mem() {   # AC23
	T_TITLE="a cluster selection from any source keeps MEM at %m: SQUEUE_FEDERATION, SQUEUE_SIBLING, SLURM_CLUSTERS, -M"
	local f
	for f in SQUEUE_FEDERATION= SQUEUE_SIBLING=1 SLURM_CLUSTERS=c1; do
		mem_run jobmem SQ_WIDTH=110 "$f" -- --color
		need "jobmem, $f: no allocation, mirror or sstat call" eval 'rc_is 0 && [ "$(calls alloc)$(calls mirror)$(calls sstat)" = 000 ]'
		mem_run memalloc SQ_WIDTH=110 "$f" -- --color
		need "memalloc, $f: no allocation, mirror or sstat call" eval 'rc_is 0 && [ "$(calls alloc)$(calls mirror)$(calls sstat)" = 000 ]'
	done
	mem_run jobmem SQ_WIDTH=110 -- --color -M c1
	need "jobmem, -M c1: no allocation, mirror or sstat call" eval 'rc_is 0 && [ "$(calls alloc)$(calls mirror)$(calls sstat)" = 000 ]'
	mem_run memalloc SQ_WIDTH=110 -- --color -M c1
	need "memalloc, -M c1: no allocation, mirror or sstat call" eval 'rc_is 0 && [ "$(calls alloc)$(calls mirror)$(calls sstat)" = 000 ]'
}
c_opts_docs() {   # AC27
	T_TITLE="sq -h names every short letter and long name sq accepts as a word, the README each of OPTS's notes, and the help's examples run"
	local w missing= readme=${here%/*}/README.md
	sq_run empty -- -h
	for w in -u -p -A -U -q -j -M -n -t -w -L -R -S -a -r -P -o -c -C -x -h \
	         --user --users --partition --partitions --account --accounts --qos --job --jobs --cluster --clusters \
	         --name --state --states --node --nodes --nodelist --license --licenses --reservation --sort \
	         --all --hide --array --noconvert --noheader --priority --federation --local --sibling --sib --me \
	         --format --center --centre --center-all --centre-all --expand --no-recent --no-bell --color --colour \
	         --no-color --no-colour --compact --full --reserve --help; do
		plain | grep -qE -- "(^|[^-[:alnum:]])$w([^-[:alnum:]]|$)" || missing="$missing $w"
	done
	need "sq -h names each as a word${missing:+ (missing:$missing)}" eval 'rc_is 0 && [ -z "$missing" ]'
	need "sq -h: options are written apart, -h is --noheader, the environment counts, an empty one is refused, the one-dash cost" eval '
		has "short options are written apart (-a -r, not -ar)" && has "squeue'"'"'s -h is --noheader, which sq always" &&
		has "squeue'"'"'s own variables count as the flags they stand for, a flag winning" && has "empty is refused" &&
		has "a job named \"ame\" is -n ame, not -name" && has "SQUEUE_SIB and SQUEUE_SIBLING"'
	need "README: Usage, the flag table, Good to know (default view, sacct's unknown user, squeue's environment), Refused" eval '
		grep -qF "read by their full long" "$readme" && grep -qF "in squeue'"'"'s short spelling" "$readme" &&
		grep -qF "| \`-u\`, \`-p\`, \`-A\` (\`-U\`)" "$readme" && grep -qF "squeue'"'"'s default view (no \`--all\`, no \`-p\`)" "$readme" &&
		grep -qF "refuses an unknown user or QoS that squeue only warns about" "$readme" &&
		grep -qF "squeue'"'"'s environment may stop sq with a" "$readme" && grep -qF "sq'"'"'s own \`SQ_*\` variables" "$readme" &&
		grep -qF "costs the" "$readme" && grep -qF "Options run together are refused" "$readme" &&
		grep -qF "a job named \"ame\" is written \`-n ame\`" "$readme" && grep -qF "in any spelling" "$readme"'
	# the help's own examples
	orun empty -- -o i,j,T,M,P,N
	need "sq -o i,j,T,M,P,N: rc 0" eval 'rc_is 0 && err_empty'
	orun empty -- -u alice -p gpu
	need "sq -u alice -p gpu: rc 0, both filters" eval 'rc_is 0 && q_is -u alice -p gpu'
	orun empty -- -pgpu --partition=gpu
	need "-pgpu --partition=gpu: one filter twice, refused" eval 'rc_is 2'
	orun empty -- -a -r
	need "sq -a -r: rc 0, Q -a -r" eval 'rc_is 0 && q_is -a -r'
	o_refused "'-ar' runs options together; write each option as its own word" -- -ar
	o_refused "'-partition' is not an option; did you mean --partition?" -- -partition
	orun empty -- -n ame
	need "sq -n ame: the job name ame" eval 'rc_is 0 && q_is -n ame'
	orun empty -- -n -x
	need "sq -n -x: the job name -x" eval 'rc_is 0 && q_is -n -x'
	orun empty -- --noheader
	need "sq --noheader: rc 0, changes nothing" eval 'rc_is 0 && q_is'
	o_refused "SQUEUE_USERS is set but holds no user name; unset it, or set one, e.g. SQUEUE_USERS=$(login_of_stub)" SQUEUE_USERS= --
	for w in -c -C -x --center --centre --center-all --centre-all --expand --colour --no-colour --no-recent --no-bell --color --no-color --compact --full; do
		orun empty -- "$w"
		need "sq $w: rc 0" eval 'rc_is 0 && err_empty'
	done
}

# ============================================================================
# NODES-v4: where scontrol --json is unusable, sq job takes every figure sinfo
# can print from sinfo (machine text, framed by a third nonce), scontrol -o
# is asked only about sinfo's names (both sites), and only CPUEfctv and
# MemSpecLimit are read from it, where Slurm prints them (node_read)
# ============================================================================
# line_with LINE OLD NEW: LINE with its first OLD (literal text) made NEW,
# verbatim: no pattern, no backslash undone (a fixture's \x3d, \n stay)
line_with() {
	local pre=${1%%"$2"*}
	[ "$pre" != "$1" ] || { printf 'line_with: no "%s" in the line\n' "$2" >&2; return 1; }
	printf '%s' "$pre$3${1#*"$2"}"
}
# jfx_copy NAME FIXTURE [FILE=LINES...]: a copy of sq job fixture FIXTURE
# (its files as they are, @includes made absolute), FILE then holding these
# lines (printf %s, so fixture escapes reach the stub as written); prints its
# directory
jfx_copy() {
	local d=$T_DIR/fx-$1 src=$jfx/$2 f; shift 2
	mkdir -p "$d"
	for f in "$src"/*; do sed "s|^@include ../../_common/|@include $fixtures/_common/|" "$f" > "$d/${f##*/}"; done
	while [ $# -gt 0 ]; do printf '%s\n' "${1#*=}" > "$d/${1%%=*}"; shift; done
	printf '%s' "$d"
}
# dash_copy NAME [FILE=LINES...]: membar-busy, each file an @include of it,
# FILE holding these lines as written; prints its directory
dash_copy() {
	local d=$T_DIR/fx-$1 f; shift
	mkdir -p "$d"
	for f in sinfo sacct squeue scontrol-node; do printf '@include %s\n' "$fixtures/membar-busy/$f" > "$d/$f"; done
	while [ $# -gt 0 ]; do printf '%s\n' "${1#*=}" > "$d/${1%%=*}"; shift; done
	printf '%s' "$d"
}
# o_path DIR nojson|garbage: what makes --json unusable for the next run:
# Slurm without it (O_ENV, SQSTUB_NOJSON=1), or an answer of garbage, exit 0
# (DIR/scontrol-node.json); the two ways the -o path is reached
o_path() {
	rm -f "$1/scontrol-node.json"; O_ENV=SQSTUB_NOJSON=1
	[ "$2" = nojson ] || { printf 'garbage\n' > "$1/scontrol-node.json"; O_ENV=; }
}
# pinned_is FILE: stdout is the pinned screen FILE, dates and the run's
# directory aside (never written, also under --pin)
pinned_is() { cmp -s <(job_mask "$1") <(unrooted | job_mask /dev/stdin); }
# argv_is TOOL N WORD...: call N of TOOL got exactly these words
argv_is() {
	local want; want="$(printf '%q ' "${@:3}")"
	W=$want gawk -F'\t' -v t="$1" -v n="$2" '$1 == "CALL" && $2 == t && ++c == n { exit !($3 == ENVIRON["W"]) } END { if (c < n) exit 1 }' "$LOG"
}
# node_calls: the scontrol and sinfo calls of the log in order, one a line ("scontrol --json", "sinfo", "scontrol -o")
node_calls() { gawk -F'\t' '$1 == "CALL" && $2 == "sinfo" { print "sinfo" } $1 == "CALL" && $2 == "scontrol" { print "scontrol " ($3 ~ /^--json/ ? "--json" : "-o") }' "$LOG" | paste -sd,; }
# the -o line's own fixtures: fb2-bioinf's and fb2-bioinf-0's lines of
# badconstraints-11955 (bc_big, bc_small) and of resources-11964 (rs_big,
# rs_small), and membar-busy's (mb_big, mb_small)
nodes_lines() {
	bc_big=$(grep '^NodeName=fb2-bioinf ' "$jfx/badconstraints-11955/scontrol-node")
	bc_small=$(grep '^NodeName=fb2-bioinf-0 ' "$jfx/badconstraints-11955/scontrol-node")
	rs_big=$(grep '^NodeName=fb2-bioinf ' "$jfx/resources-11964/scontrol-node")
	rs_small=$(grep '^NodeName=fb2-bioinf-0 ' "$jfx/resources-11964/scontrol-node")
	mb_big=$(grep '^NodeName=fb2-bioinf ' "$fixtures/membar-busy/scontrol-node")
	mb_small=$(grep '^NodeName=fb2-bioinf-0 ' "$fixtures/membar-busy/scontrol-node")
}
# sq job's figure call answered by a sinfo file of its own: resources-11964's
# rows as sinfo prints them (fb2-bioinf in LocalQ and main, fb2-bioinf-0 in
# LocalQ and small), then these rows
rs_sinfo() {
	printf '%s\n' '@defaults Memory=1031000; AllocMem=327680; StateComplete=mixed; CPUsState=48/80/0/128' \
		'NodeList=fb2-bioinf; PartitionName=LocalQ' 'NodeList=fb2-bioinf; PartitionName=main' \
		'NodeList=fb2-bioinf-0; PartitionName=LocalQ; CPUsState=0/24/0/24; Memory=80000; AllocMem=0; StateComplete=idle' \
		'NodeList=fb2-bioinf-0; PartitionName=small; CPUsState=0/24/0/24; Memory=80000; AllocMem=0; StateComplete=idle' "$@"
}
rs_pinned=$jfx/screens/why__pending-resources.txt bc_pinned=$jfx/screens/why__pending-badconstraints.txt
bc_unknown='    fb2-bioinf       ?                ?  unknown: scontrol did not say'
# why_unknown NODE WHY: the node table row of NODE reads "? ? unknown: scontrol WHY"
why_unknown() { why_lines | grep -qE "^    $1 +\? +\? +unknown: scontrol $2\$"; }

c_nodes_o_calls() {   # AC 1, 2, 9, 14
	T_TITLE="NODES -o (no --json, or --json garbage): the --json screens of resources-11964, pending-est and badconstraints-11955; scontrol --json, then sinfo --local -h -N -O six fields framed by a third nonce (no SINFO_* reaching it), then scontrol -o show node fb2-bioinf,fb2-bioinf-0 under SLURM_TIME_FORMAT=standard; --json asks no sinfo; the dashboard asks its own sinfo once and scontrol -o its names, its -o collect as before"
	local c name fx id want d how n n1 n2 f fmt
	for c in "pending-resources resources-11964 11964" "pending-est pending-est 11962" "pending-badconstraints badconstraints-11955 11955"; do
		read -r name fx id <<< "$c"
		d=$(jfx_copy "calls-$fx" "$fx")
		why_run "$d" -- --no-color job "$id"; want=$RUN/screen; unrooted > "$want"
		need "$fx, --json: rc 0, stderr empty, one scontrol call, no sinfo call" eval '
			rc_is 0 && err_empty && [ "$(node_calls)" = "scontrol --json" ]'
		for how in nojson garbage; do
			o_path "$d" "$how"
			why_run "$d" $O_ENV SINFO_PARTITION=main SINFO_ALL=1 SINFO_FORMAT=%N SINFO_SORT=N SINFO_FEDERATION=1 SINFO_LOCAL=1 -- --no-color job "$id"
			n=$(gawk -F'\t' '$1 == "CALL" && $2 == "sinfo" { if (match($3, /CPUsState:0[A-Za-z0-9]+/)) print substr($3, RSTART + 11, RLENGTH - 11); exit }' "$LOG")
			n1=$(env_of sacct 1 SQ_NONCE) n2=$(env_of sacct 1 SQ_NONCE2) fmt=
			for f in CPUsState NodeList PartitionName Memory AllocMem StateComplete; do fmt="$fmt${fmt:+,}$f:0$n"; done
			need "$fx, -o ($how): rc 0, stderr empty, the --json screen (dates aside)" eval 'rc_is 0 && err_empty && cmp -s <(job_mask "$want") <(unrooted | job_mask /dev/stdin)'
			[ "$name" = pending-est ] || need "$fx, -o ($how): the pinned screen" pinned_is "$jfx/screens/why__$name.txt"
			need "$fx, -o ($how): scontrol --json, sinfo, scontrol -o, in that order" eval '[ "$(node_calls)" = "scontrol --json,sinfo,scontrol -o" ]'
			need "$fx, -o ($how): sinfo --local -h -N -O, the six fields framed by a nonce of 17+ letters and digits apart from the other two" eval '
				argv_is sinfo 1 --local -h -N -O "$fmt" && [[ $n =~ ^[A-Za-z][A-Za-z0-9]{16,}$ ]] && [ "$n" != "$n1" ] && [ "$n" != "$n2" ] && [ -n "$n1" ] && [ -n "$n2" ]'
			need "$fx, -o ($how): no SINFO_* reached sinfo (six exported)" eval '! gawk -F"\t" "\$1 == \"CALL\" && \$2 == \"sinfo\"" "$LOG" | grep -q SINFO_'
			need "$fx, -o ($how): scontrol -o show node fb2-bioinf,fb2-bioinf-0, SLURM_TIME_FORMAT=standard; --json and sinfo as before (unset)" eval '
				argv_is scontrol 2 -o show node fb2-bioinf,fb2-bioinf-0 && [ "$(env_of scontrol 2 SLURM_TIME_FORMAT)" = standard ] &&
				[ "$(env_of scontrol 1 SLURM_TIME_FORMAT)" = "(unset)" ] && [ "$(env_of sinfo 1 SLURM_TIME_FORMAT)" = "(unset)" ]'
		done
	done
	sq_run membar-busy SQSTUB_NOJSON=1 SQSTUB_HOST=FranzGB "$(timeout_as)" SQSTUB_TIMEOUT=log -- --full --no-color
	need "the dashboard, -o: the accepted screen, its own sinfo once, scontrol -o show node with its names, SLURM_TIME_FORMAT=standard there alone" eval '
		rc_is 0 && err_empty && membar_busy_is && [ "$(calls sinfo)" = 1 ] && argv_is scontrol 2 -o show node fb2-bioinf,fb2-bioinf-0 &&
		[ "$(env_of scontrol 2 SLURM_TIME_FORMAT)" = standard ] && [ "$(env_of scontrol 1 SLURM_TIME_FORMAT)" = "(unset)" ] && [ "$(env_of sinfo 1 SLURM_TIME_FORMAT)" = standard ]'
	need "... its -o collect as before: timeout -k 2 LEFT sh -c exec, the list last" eval '
		gawk -F"\t" "\$1 == \"TIMEOUT\" && / scontrol -o show node / { n++; ok = (\$2 ~ /-k 2 [0-9.]+ sh -c exec \"\\\$@\" 2>&3 3>&- scontrol scontrol -o show node fb2-bioinf,fb2-bioinf-0\$/) } END { exit !(n == 1 && ok) }" "$LOG"'
	sq_run membar-busy SQSTUB_HOST=FranzGB -- --full --no-color
	need "the dashboard, --json: the accepted screen, sinfo once, no -o" eval 'rc_is 0 && err_empty && membar_busy_is && [ "$(calls sinfo)" = 1 ] && [ "$(calls scontrol)" = 1 ]'
}

c_nodes_o_figures() {   # AC 3, 4, 13, 24
	T_TITLE="NODES -o figures: CPUEfctv 120 of CPUTot 128 reads 72 of 120, none reads T, 17.11's CPUErr reads T and 976.5G, CPUEfctv above T reads ?; sinfo rows of one name that differ read ?; MemSpecLimit twice in the spec segment, or no State after the memory run, reads ?; the -o argv carries raw bytes; N8: an unknown node or none known makes the lead Slurm's, the admin verdict needs every node known, BadConstraints says 'whose figures are known'"
	local d how
	nodes_lines
	for how in nojson garbage; do
		d=$(jfx_copy "efctv-$how" resources-11964)
		printf '%s\n' "$(line_with "$rs_big" CPUEfctv=128 CPUEfctv=120)" "$rs_small" > "$d/scontrol-node"
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "CPUEfctv=120, CPUTot=128 ($how): 72 of 120" eval 'rc_is 0 && err_empty && why_has "    fb2-bioinf    72 of 120  656.5G of 976.5G  too few CPUs free"'
		printf '%s\n' "$(line_with "$rs_big" "CPUEfctv=128 " "")" "$rs_small" > "$d/scontrol-node"
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "no CPUEfctv ($how): T, the pinned screen" eval 'rc_is 0 && err_empty && pinned_is "$rs_pinned"'
		printf '%s\n' "$(line_with "$rs_big" "CPUEfctv=128" "CPUEfctv=129")" "$rs_small" > "$d/scontrol-node"
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "CPUEfctv above T ($how): ?" eval 'rc_is 0 && err_empty && why_unknown fb2-bioinf "did not say"'
	done
	d=$(node_fx cpuerr "$(line_with "$bc_big" "CPUEfctv=128" "CPUErr=0")" "$bc_small")
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11955
	need "17.11's CPU run (CPUErr): T and 976.5G, the pinned screen" eval 'rc_is 0 && err_empty && why_has "    fb2-bioinf     128           976.5G  too few CPUs, too little memory" && pinned_is "$bc_pinned"'
	# sinfo rows of one name that differ outside PartitionName
	d=$(jfx_copy rows resources-11964 "sinfo=$(rs_sinfo | sed 's/^NodeList=fb2-bioinf; PartitionName=main$/NodeList=fb2-bioinf; PartitionName=main; Memory=1031001/')")
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "two sinfo rows of fb2-bioinf differing in Memory: ?" eval 'rc_is 0 && err_empty && why_unknown fb2-bioinf "did not say"'
	rs_sinfo > "$d/sinfo"
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "... the same rows alike: the pinned screen" eval 'rc_is 0 && err_empty && pinned_is "$rs_pinned"'
	# the spec segment
	d=$(node_fx cpuspec "$(line_with "$bc_big" " MemSpecLimit=31000" ' MemSpecLimit=31000 CPUSpecList=0-1 MemSpecLimit\x3d900000')" "$bc_small")
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11955
	need "a genuine MemSpecLimit and CPUSpecList=0-1 MemSpecLimit=900000: ?" eval 'rc_is 0 && err_empty && why_has "$bc_unknown"'
	d=$(node_fx nostate "$(line_with "$bc_big" " State=MIXED" "")" "$bc_small")
	rs_sinfo > "$d/sinfo"          # its rows (the same as resources-11964's): sinfo prints a state
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11955
	need "a memory run and no State after it: ?" eval 'rc_is 0 && err_empty && why_has "$bc_unknown"'
	# raw bytes reach scontrol as Slurm knows the name
	d=$(jfx_copy raw badconstraints-11955 "scontrol-node=$(sed -e 's/fb2-bioinf-0/@B@/g' -e 's/fb2-bioinf/n\\xe9x/g' -e 's/@B@/fb2-bioinf-0/g' "$jfx/badconstraints-11955/scontrol-node")")
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11955
	need "a Latin-1 name: the -o argv carries its raw bytes ($'n\\351x,fb2-bioinf-0'), the row reads n␚x" eval '
		rc_is 0 && err_empty && argv_is scontrol 2 -o show node $'"'"'n\351x,fb2-bioinf-0'"'"' && why_lines | grep -qE "^    n␚x +128 +976.5G "'
	# N8, both paths
	for how in json nojson; do
		local env=; [ $how = json ] || env=SQSTUB_NOJSON=1
		d=$(jfx_copy "n8a-$how" resources-11964)
		{ cat "$jfx/resources-11964/scontrol-node"; printf '@stderr scontrol: error: Unable to contact slurm controller (connect failure)\n@exit 1\n'; } > "$d/scontrol-node"
		why_run "$d" $env -- --no-color job 11964
		need "$how, scontrol failing: V1b's lead" eval 'rc_is 0 && why_has "  waits its turn: Slurm finds too little free now on the nodes it may use (LocalQ)"'
		printf '%s\n' "$(line_with "$rs_big" "RealMemory=1031000" "RealMemory=lots")" "$rs_small" > "$d/scontrol-node"
		why_run "$d" $env -- --no-color job 11964
		need "$how, fb2-bioinf garbled: V1b's lead, its row ?" eval '
			rc_is 0 && err_empty && why_has "  waits its turn: Slurm finds too little free now on the nodes it may use (LocalQ)" && why_lines | grep -qE "^    fb2-bioinf +\\? +\\? +unknown"'
		printf '%s\n' "$(line_with "$rs_big" "State=MIXED" "State=MIXED+DRAIN")" "$(line_with "$rs_small" "RealMemory=80000" "RealMemory=lots")" > "$d/scontrol-node"
		why_run "$d" $env -- --no-color job 11964
		need "$how, fb2-bioinf drained and fb2-bioinf-0 unknown: V1b's lead, not the admin verdict" eval '
			rc_is 0 && err_empty && why_has "  waits its turn: Slurm finds too little free now on the nodes it may use (LocalQ)" && ! why_lines | grep -q "waits for an admin"'
		d=$(node_fx "n8b-$how" "$(line_with "$bc_big" "RealMemory=1031000" "RealMemory=lots")" "$bc_small")
		why_run "$d" $env -- --no-color job 11955
		need "$how, badconstraints with fb2-bioinf garbled: L4b's line" eval '
			rc_is 0 && err_empty && why_has "  can never start: no node it may use (LocalQ) whose figures are known is that big" && why_has "$bc_unknown"'
	done
}

# the forgeries of the attacks (nodes-attack-int/-fmt), each written inside a
# value, its key-like text with "=" as \x3d (stub.sh): NAME|OLD|NEW, OLD the
# text of fb2-bioinf's line it goes into
nodes_forgeries_genuine=(
	'a1|2026  RealMemory=|2026  RealMemory\x3d1031000 AllocMem\x3d0 MemSpecLimit\x3d700000 Reason\x3dx  RealMemory='
	'a1b|OS=Linux|OS=Linux MemSpecLimit\x3d500000 Reason\x3dx'
	'a3|Arch=x86_64|Arch=x86_64 MemSpecLimit\x3d900000'
	'A4|Arch=x86_64|Arch=x86_64 CPUEfctv\x3d9999 OS\x3dx'
	'osnl|OS=Linux|OS=Linux\n'
)
nodes_forgeries_runs=(
	'a1full|2026  RealMemory=|2026 RealMemory\x3d1 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1 MemSpecLimit\x3d0 State\x3dIDLE  RealMemory='
	'archrun|Arch=x86_64|Arch=x86_64 CPUAlloc\x3d0 CPUEfctv\x3d999 CPUTot\x3d999'
	'A2|OS=Linux|OS=Linux RealMemory\x3d1 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1 MemSpecLimit\x3d0 State\x3dIDLE\n'
)
# forged_line VAR "NAME|OLD|NEW" LINE: LINE with that forgery, into VAR
forged_line() {
	local name old new
	IFS='|' read -r name old new <<< "$2"
	printf -v "$1" '%s' "$(line_with "$3" "$old" "$new")"
}
c_nodes_o_forged() {   # AC 5, 6, 7, 8
	T_TITLE="NODES -o forgeries: text in OS/Arch naming figures (forge2, osdash, a1, a1b, a3, A4, A13, an OS of a newline) reads genuine, as --json; a whole run there (a1full, archrun, A2) or in a Comment (A16, the stated regression) makes the node ?, the dashboard RealMemory with the caption; the HIGH-1 splits (S1/S2: the pair check's note; S3: ? and twice; S4: the caption), F3 (a name not found that begins a record) and M3 (a not-found line inside the forger's text) fail closed; forge1's ghost never shows a row"
	local spec name line d how json n
	nodes_lines
	for spec in "${nodes_forgeries_genuine[@]}"; do
		name=${spec%%|*}
		forged_line line "$spec" "$bc_big"
		d=$(node_fx "g-$name" "$line" "$bc_small")
		why_run "$d" -- --no-color job 11955
		need "$name, --json: the pinned screen" eval 'rc_is 0 && err_empty && pinned_is "$bc_pinned"'
		for how in nojson garbage; do
			o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11955
			need "$name, -o ($how): genuine, the pinned screen" eval 'rc_is 0 && err_empty && pinned_is "$bc_pinned"'
		done
		forged_line line "$spec" "$mb_big"
		d=$(dash_copy "gd-$name" "scontrol-node=$line"$'\n'"$mb_small")
		sq_run "$d" SQSTUB_HOST=FranzGB -- --full --no-color; json=$RUN/out
		sq_run "$d" SQSTUB_HOST=FranzGB SQSTUB_NOJSON=1 -- --full --no-color
		need "$name, the dashboard -o: the accepted screen, as --json" eval 'rc_is 0 && err_empty && membar_busy_is && cmp -s <(without_clock "$json") <(without_clock "$OUT")'
	done
	# forge2 (triage 3): fb2-bioinf-0's OS naming RealMemory, AllocMem, CPUAlloc, CPUEfctv
	d=$(jfx_copy forge2 resources-11964)
	printf '%s\n' "$rs_big" "$(line_with "$rs_small" "#146-Ubuntu SMP" '#146-Ubuntu RealMemory\x3d2000000 AllocMem\x3d0 CPUAlloc\x3d0 CPUEfctv\x3d256 SMP')" > "$d/scontrol-node"
	for how in json nojson garbage; do
		if [ $how = json ]; then rm -f "$d/scontrol-node.json"; O_ENV=; else o_path "$d" $how; fi
		why_run "$d" $O_ENV -- --no-color job 11964
		need "forge2, $how: fb2-bioinf-0 its own 75G, the pinned screen" eval 'rc_is 0 && err_empty && pinned_is "$rs_pinned"'
	done
	# osdash (triage 3): fb2-bioinf's OS naming MemSpecLimit=900000
	d=$(dash_copy osdash "scontrol-node=$(line_with "$mb_big" "OS=Linux" 'OS=Linux MemSpecLimit\x3d900000')"$'\n'"$mb_small")
	for how in "" SQSTUB_NOJSON=1; do
		sq_run "$d" $how -- --full
		need "osdash${how:+, -o}: FULL 265/977G" eval 'rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed" && [ -z "$(membar_note)" ]'
		sq_run "$d" $how SQ_HEIGHT=4 -- --compact
		need "osdash${how:+, -o}: COMPACT 335/1052G" eval 'rc_is 0 && err_empty && [ "$(digest_line)" = "nodes: 1 mixed, 1 allocated · 82/152 cpu · 335/1052G mem" ]'
	done
	# A13: no MemSpecLimit, an InstanceType naming one, after State
	d=$(dash_copy a13 "scontrol-node=$(line_with "$mb_big" " MemSpecLimit=31000" "") InstanceType=a MemSpecLimit\\x3d500000"$'\n'"$mb_small")
	for how in "" SQSTUB_NOJSON=1; do
		sq_run "$d" $how -- --full
		need "A13${how:+, -o}: 26% 265/1007G, no caption" eval 'rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" && [ -z "$(membar_note)" ]'
	done
	# whole runs in free text: the node unknown, the dashboard says why
	for spec in "${nodes_forgeries_runs[@]}" "A16"; do
		name=${spec%%|*}
		if [ "$name" = A16 ]; then line="$bc_big Comment=see: $bc_small"; else forged_line line "$spec" "$bc_big"; fi
		d=$(node_fx "r-$name" "$line" "$bc_small")
		why_run "$d" -- --no-color job 11955
		need "$name, --json: the pinned screen" eval 'rc_is 0 && err_empty && pinned_is "$bc_pinned"'
		for how in nojson garbage; do
			o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11955
			need "$name, -o ($how)$([ $name = A16 ] && echo ', the regression N12 states (1eb0218 read it genuine)'): fb2-bioinf unknown" eval 'rc_is 0 && err_empty && why_has "$bc_unknown"'
		done
		if [ "$name" = A16 ]; then line="$mb_big Comment=see: $mb_small"; else forged_line line "$spec" "$mb_big"; fi
		d=$(dash_copy "rd-$name" "scontrol-node=$line"$'\n'"$mb_small")
		sq_run "$d" SQSTUB_NOJSON=1 -- --full
		need "$name, the dashboard -o: 26% 265/1007G, M7e's caption" eval '
			rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" &&
			[ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bioinf: scontrol gave no usable MemSpecLimit" ]'
	done
	# HIGH-1: a newline plus NodeName= in text before the figures
	local s1 s2 s3 s4
	s1='OS=Linux RealMemory\x3d2000000 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1 State\x3dIDLE Partitions\x3dLocalQ,main  BootTime\x3dx\nNodeName=fb2-fake '
	s2='Arch=x86_64 CPUAlloc\x3d0 CPUEfctv\x3d999 CPUTot\x3d999 RealMemory\x3d2000000 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1 State\x3dIDLE Partitions\x3dLocalQ,main  BootTime\x3dx\nNodeName=fb2-fake '
	s3='OS=Linux RealMemory\x3d2000000 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1 State\x3dIDLE Partitions\x3dLocalQ,main  BootTime\x3dx\nNodeName=fb2-bioinf-0 '
	s4='OS=Linux RealMemory\x3d1 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1 MemSpecLimit\x3d900000 State\x3dIDLE\nNodeName=x '
	for name in S1 S2 S3; do
		case $name in S1) line=$(line_with "$bc_big" "OS=Linux " "$s1") ;; S2) line=$(line_with "$bc_big" "Arch=x86_64 " "$s2") ;; S3) line=$(line_with "$bc_big" "OS=Linux " "$s3") ;; esac
		d=$(node_fx "h-$name" "$line" "$bc_small")
		why_run "$d" -- --no-color job 11955
		need "$name, --json: the pinned screen" eval 'rc_is 0 && err_empty && pinned_is "$bc_pinned"'
		for how in nojson garbage; do
			o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11955
			if [ $name = S3 ]; then
				need "S3, -o ($how): fb2-bioinf ? (did not say), fb2-bioinf-0 ? (listed it twice)" eval '
					rc_is 0 && err_empty && why_unknown fb2-bioinf "did not say" && why_unknown fb2-bioinf-0 "listed it twice"'
			else
				need "$name, -o ($how): D4's note, no rows" eval '
					rc_is 0 && err_empty && why_notes | head -n 1 | grep -qxF "the nodes are unknown: scontrol lists fb2-fake in LocalQ, sinfo does not" && ! why_lines | grep -q "^    fb2-bioinf"'
			fi
		done
	done
	d=$(dash_copy h-S4 "scontrol-node=$(line_with "$mb_big" "OS=Linux " "$s4")"$'\n'"$mb_small")
	sq_run "$d" SQSTUB_NOJSON=1 -- --full
	need "S4, the dashboard -o: 26% 265/1007G with M7e's caption, never 128G" eval '
		rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" && ! mem_part fb2-bioinf | grep -q /128G &&
		[ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bioinf: scontrol gave no usable MemSpecLimit" ]'
	# F3: a forged NodeName=nosuch that sinfo lists (in LocalQ) and scontrol does not know
	d=$(jfx_copy f3 resources-11964 "sinfo=$(rs_sinfo 'NodeList=nosuch; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle')")
	printf '%s\n' "$(line_with "$rs_big" "OS=Linux " 'OS=Linux\nNodeName=nosuch ')" "$rs_small" > "$d/scontrol-node"
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "F3, -o ($how): asked about nosuch too, not found (rc 1, used): fb2-bioinf ? and nosuch ?, fb2-bioinf-0 its own" eval '
			rc_is 0 && err_empty && argv_is scontrol 2 -o show node fb2-bioinf,fb2-bioinf-0,nosuch && why_unknown fb2-bioinf "did not say" && why_unknown nosuch "did not say" &&
			why_lines | grep -qE "^    fb2-bioinf-0 +24 of 24 +75G of 75G +never fits: too few CPUs, too little memory$"'
	done
	# F3 in the superset direction (the review's rv_f3pred, rv_f3): a name sinfo lists and
	# scontrol does not know begins a forged record; its record and the one before it fail
	# closed, so neither the forger's runs in fb2-bioinf's OS nor the forged record's own
	# figures reach a screen
	local f3fx='NodeList=nosuch; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle'
	local f3row='CPUsState=0/8/0/8; NodeList=nosuch; FreeMem=7000; Memory=8000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.00; AllocMem=0'
	local f3pred='OS=Linux RealMemory\x3d1031000 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1 MemSpecLimit\x3d900000 State\x3dIDLE\nNodeName\x3dnosuch '
	local f3rec='\nNodeName\x3dnosuch CPUAlloc\x3d0 CPUEfctv\x3d2 CPUTot\x3d8 RealMemory\x3d8000 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1 MemSpecLimit\x3d7000 State\x3dIDLE'
	d=$(jfx_copy f3pred resources-11964 "sinfo=$(rs_sinfo "$f3fx")")
	printf '%s\n' "$(line_with "$rs_big" "OS=Linux " "$f3pred")" "$rs_small" > "$d/scontrol-node"
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "F3, the forger's runs before a not-found name's record, -o ($how): fb2-bioinf ? (never MemSpecLimit 900000), nosuch ?" eval '
			rc_is 0 && err_empty && why_unknown fb2-bioinf "did not say" && why_unknown nosuch "did not say" && ! why_lines | grep -qE "^    fb2-bioinf +80 of 128"'
	done
	d=$(dash_copy f3pred "scontrol-node=$(line_with "$mb_big" "OS=Linux " "$f3pred")"$'\n'"$mb_small" "sinfo=@include $fixtures/membar-busy/sinfo
$f3row")
	sq_run "$d" SQSTUB_NOJSON=1 -- --full
	need "F3, the same on the dashboard: fb2-bioinf at RealMemory with the caption, never /128G" eval '
		rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" && ! mem_part fb2-bioinf | grep -q /128G &&
		membar_note | grep -q "^↳ memory counts RealMemory on fb2-bioinf and 1 more node: "'
	d=$(jfx_copy f3rec resources-11964 "sinfo=$(rs_sinfo "$f3fx")")
	printf '%s\n' "$rs_big Comment=x$f3rec" "$rs_small" > "$d/scontrol-node"
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "F3, a complete forged record of a not-found name in fb2-bioinf's Comment, -o ($how): nosuch ? (never 'of 2'), fb2-bioinf ?" eval '
			rc_is 0 && err_empty && why_unknown nosuch "did not say" && ! why_lines | grep -q " of 2 " && why_unknown fb2-bioinf "did not say"'
	done
	d=$(dash_copy f3rec "scontrol-node=$mb_big Comment=x$f3rec"$'\n'"$mb_small" "sinfo=@include $fixtures/membar-busy/sinfo
$f3row")
	sq_run "$d" SQSTUB_NOJSON=1 -- --full
	need "F3, the same on the dashboard: nosuch at RealMemory (0/8G, never 0/1G), fb2-bioinf too, the caption" eval '
		rc_is 0 && err_empty && mem_part nosuch | grep -q " 0/8G mem idle$" && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" &&
		membar_note | grep -q "^↳ memory counts RealMemory on fb2-bioinf and 1 more node: "'
	# M3: the forger's complete runs, then a not-found line of the first node, then the genuine tail
	d=$(jfx_copy m3 resources-11964)
	printf '%s\n' "$(line_with "$rs_big" "OS=Linux " 'OS=Linux CPUAlloc\x3d0 CPUEfctv\x3d999 CPUTot\x3d999 RealMemory\x3d2000000 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1 MemSpecLimit\x3d0 State\x3dIDLE\nNode fb2-bioinf not found\n')" "$rs_small" > "$d/scontrol-node"
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "M3, -o ($how): fb2-bioinf ?, never the forged figures, fb2-bioinf-0 its own" eval '
			rc_is 0 && err_empty && why_unknown fb2-bioinf "did not say" && ! has 999 && ! has 1.9T &&
			why_lines | grep -qE "^    fb2-bioinf-0 +24 of 24 +75G of 75G +never fits: too few CPUs, too little memory$"'
	done
	# ghosts (forge1 of triage 3), job 11964
	local ghost='NodeName=fb2-fake CPUAlloc=0 CPUTot=256 RealMemory=2000000 AllocMem=0 State=IDLE Partitions=LocalQ'
	for spec in "forge1:$ghost" "boot:$ghost  BootTime=x" "copy:${rs_small//fb2-bioinf-0/fb2-fake}" "small:${ghost/LocalQ/small}  BootTime=x" "named:${rs_big}"; do
		name=${spec%%:*} line=${spec#*:}
		d=$(jfx_copy "ghost-$name" resources-11964)
		printf '%s\n' "$rs_big" "$rs_small Comment=x\\n$line" > "$d/scontrol-node"
		rm -f "$d/scontrol-node.json"; why_run "$d" -- --no-color job 11964
		need "ghost $name, --json: the pinned screen, no sinfo call" eval 'rc_is 0 && err_empty && pinned_is "$rs_pinned" && [ "$(calls sinfo)" = 0 ]'
		for how in nojson garbage; do
			o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
			case $name in
				forge1|small) need "ghost $name, -o ($how): fb2-bioinf-0 ?, fb2-bioinf its own, no ghost row, no note" eval '
					rc_is 0 && err_empty && why_unknown fb2-bioinf-0 "did not say" && why_has "    fb2-bioinf    80 of 128  656.5G of 976.5G  too few CPUs free" &&
					! has fb2-fake && ! why_notes | grep -q "unknown"' ;;
				boot|copy) need "ghost $name, -o ($how): D4's note naming fb2-fake in LocalQ, no rows" eval '
					rc_is 0 && err_empty && why_notes | head -n 1 | grep -qxF "the nodes are unknown: scontrol lists fb2-fake in LocalQ, sinfo does not" && ! why_lines | grep -q "^    fb2-bioinf"' ;;
				named) need "ghost named fb2-bioinf, -o ($how): F2, fb2-bioinf twice, fb2-bioinf-0 before it ?" eval '
					rc_is 0 && err_empty && why_unknown fb2-bioinf "listed it twice" && why_unknown fb2-bioinf-0 "did not say"' ;;
			esac
		done
	done
}

c_nodes_o_pairs() {   # AC 9, 10, 24
	T_TITLE="NODES -o pair check and gate: a pair run naming the job's partition whose node sinfo lacks there is D4's note (several partitions: the one named); an honest Reason naming another partition changes nothing; an empty sinfo answer is W6's line and no -o call; nodes sinfo lists that scontrol does not know read ? (not found, rc 1 used); no node in the job's partition is W5b's line on -o, 'no node is in partition' on --json; N6's name cut to 40 columns, controls as ?; names that cannot be listed reach no list and read ?, the dashboard's caption; the dashboard lists its own names whatever SINFO_* says"
	local d how line long shown
	nodes_lines
	# several partitions: the ghost names small, the job is in LocalQ,small
	d=$(jfx_copy pairs resources-11964)
	sed -i 's/^\(JobID=11964;.*\)Partition=LocalQ;/\1Partition=LocalQ,small;/' "$d/squeue-queue"
	sed -i 's/^\(JobID=11964;.*\)$/\1; Partition=LocalQ,small/' "$d/squeue-all"
	printf '%s\n' "$rs_big" "$(line_with "$rs_small" "OS=Linux " 'OS=Linux\nNodeName=ghost Partitions\x3dsmall  BootTime\x3dx ')" > "$d/scontrol-node"
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "Partition=LocalQ,small, a ghost run naming small ($how): the note names small" eval '
			rc_is 0 && err_empty && why_notes | head -n 1 | grep -qxF "the nodes are unknown: scontrol lists ghost in small, sinfo does not"'
	done
	# an honest Reason naming another partition, the job in LocalQ
	d=$(jfx_copy honest resources-11964)
	printf '%s\n' "$rs_big Reason=moved Partitions=small  BootTime=x [root@2026-10-21T10:00:00]" "$rs_small" > "$d/scontrol-node"
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "an honest Reason 'moved Partitions=small  BootTime=x' ($how): the pinned screen" eval 'rc_is 0 && err_empty && pinned_is "$rs_pinned"'
	done
	# sinfo answering nothing, rc 0
	d=$(jfx_copy empty resources-11964 "sinfo=# no node")
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "an empty sinfo answer, rc 0: W6's line, no scontrol -o" eval '
		rc_is 0 && err_empty && [ "$(why_notes | head -n 1)" = "the nodes are unknown: sinfo listed no node" ] && [ "$(node_calls)" = "scontrol --json,sinfo" ]'
	# sinfo listing both, scontrol knowing neither: not found, rc 1, used
	d=$(jfx_copy none resources-11964 "sinfo=$(rs_sinfo)" "scontrol-node=# no node")
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "sinfo listing both, scontrol knowing neither ($how): both not found, rc 1 and used: every row ?" eval '
			rc_is 0 && err_empty && why_unknown fb2-bioinf "did not say" && why_unknown fb2-bioinf-0 "did not say" && ! why_notes | grep -q "nodes are unknown"'
	done
	# a third node sinfo lists and scontrol does not know
	d=$(jfx_copy third resources-11964 "sinfo=$(rs_sinfo 'NodeList=fb2-extra; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle')")
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "a third node sinfo lists, scontrol does not know ($how): its row ?, the others theirs" eval '
			rc_is 0 && err_empty && why_unknown fb2-extra "did not say" && why_lines | grep -qE "^    fb2-bioinf +80 of 128 +656.5G of 976.5G +too few CPUs free$"'
	done
	# no node in the job's partition
	d=$(jfx_copy nopart resources-11964)
	sed -i 's/^\(JobID=11964;.*\)Partition=LocalQ;/\1Partition=gpu;/' "$d/squeue-queue"
	sed -i 's/^\(JobID=11964;.*\)$/\1; Partition=gpu/' "$d/squeue-all"
	why_run "$d" -- --no-color job 11964
	need "no node in partition gpu, --json: 'no node is in partition gpu'" eval 'rc_is 0 && err_empty && [ "$(why_notes)" = "no node is in partition gpu" ]'
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11964
		need "no node in partition gpu, -o ($how): W5b's line" eval 'rc_is 0 && err_empty && [ "$(why_notes)" = "sinfo lists no node in partition gpu" ]'
	done
	# N6's name: scrubbed, controls as ?, cut to 40 columns
	long='g\x01ghostghostghostghostghostghostghostghostghostghost' shown=$(printf 'g?%s' ghostghostghostghostghostghostghostghostghostghost | cut -c1-39)…
	d=$(jfx_copy long resources-11964)
	printf '%s\n' "$rs_big" "$(line_with "$rs_small" "OS=Linux " "OS=Linux\\nNodeName=$long Partitions\\x3dLocalQ  BootTime\\x3dx ")" > "$d/scontrol-node"
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "a ghost of 52 characters, the second \\001: named in 40 columns, … last, the control character a ?" eval '
		rc_is 0 && err_empty && [ "$(why_notes | head -n 1)" = "the nodes are unknown: scontrol lists $shown in LocalQ, sinfo does not" ]'
	# names scontrol cannot be asked by: none reaches the list
	d=$(jfx_copy hygiene resources-11964 "sinfo=$(rs_sinfo 'NodeList=t\tb; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle' \
		'NodeList=c\x01d; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle' \
		'NodeList=a,b; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle' \
		'NodeList=n[1-2]; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle' \
		'NodeList=-x; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle' \
		'NodeList=; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle')")
	why_run "$d" SQSTUB_NOJSON=1 COLUMNS=120 -- --no-color job 11964
	need "sinfo names with a tab, \\001, ',', '[', a leading '-', and an empty one: none in the list, each row ?, the others theirs" eval '
		rc_is 0 && err_empty && argv_is scontrol 2 -o show node fb2-bioinf,fb2-bioinf-0 &&
		why_unknown "t\\?b" "did not say" && why_unknown "c\\?d" "did not say" && why_unknown "a,b" "did not say" && why_unknown "n\\[1-2\\]" "did not say" &&
		why_unknown "-x" "did not say" && why_unknown "" "did not say" && why_lines | grep -qE "^    fb2-bioinf +80 of 128 +656.5G of 976.5G +too few CPUs free$"'
	d=$(dash_copy dhygiene "sinfo=@include $fixtures/membar-busy/sinfo
CPUsState=0/8/0/8; NodeList=t\\tb; FreeMem=7000; Memory=8000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.00; AllocMem=0
CPUsState=0/8/0/8; NodeList=-x; FreeMem=7000; Memory=8000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.00; AllocMem=0
CPUsState=0/8/0/8; NodeList=a[1]; FreeMem=7000; Memory=8000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.00; AllocMem=0")
	sq_run "$d" SQSTUB_NOJSON=1 -- --full
	need "the dashboard: those names reach no list; RealMemory with the caption for them, the others their own" eval '
		rc_is 0 && err_empty && argv_is scontrol 2 -o show node fb2-bioinf,fb2-bioinf-0 &&
		mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed" && mem_part_is fb2-bioinf-0 "███████████████░ 93% 70/75G mem allocated" &&
		[ "$(membar_note)" = "↳ memory counts RealMemory on t?b and 2 more nodes: scontrol did not list them" ]'
	# every name sinfo lists unlistable: no -o call at all (not an unlisted one), every row ?
	d=$(jfx_copy unlistable resources-11964 "sinfo=@defaults Memory=8000; AllocMem=0; StateComplete=idle; CPUsState=0/8/0/8
NodeList=a,b; PartitionName=LocalQ
NodeList=-x; PartitionName=LocalQ")
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "sq job, every sinfo name unlistable: no scontrol -o call, each row ?" eval '
		rc_is 0 && err_empty && [ "$(node_calls)" = "scontrol --json,sinfo" ] && why_unknown "a,b" "did not say" && why_unknown "-x" "did not say"'
	# the dashboard lists the names of its own sinfo, whatever SINFO_* filters
	for how in "" SINFO_PARTITION=main; do
		sq_run membar-busy SQSTUB_NOJSON=1 SQSTUB_HOST=FranzGB $how -- --full --no-color
		need "the dashboard${how:+, $how exported}: its sinfo once, scontrol -o its names, no -o %N call, the accepted screen" eval '
			rc_is 0 && err_empty && [ "$(calls sinfo)" = 1 ] && argv_is scontrol 2 -o show node fb2-bioinf,fb2-bioinf-0 && ! grep -q -- "-o %N" "$LOG" && membar_busy_is'
	done
	d=$(dash_copy dthird "sinfo=@include $fixtures/membar-busy/sinfo
CPUsState=0/8/0/8; NodeList=fb2-extra; FreeMem=7000; Memory=8000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.00; AllocMem=0")
	for how in "" SQSTUB_NOJSON=1; do
		sq_run "$d" $how -- --full
		need "the dashboard${how:+, -o}: a third node scontrol lacks reads RealMemory, 'scontrol did not list it'; sinfo once" eval '
			rc_is 0 && err_empty && [ "$(calls sinfo)" = 1 ] && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed" &&
			mem_part fb2-extra | grep -q " 0/8G mem idle$" && [ "$(membar_note)" = "↳ memory counts RealMemory on fb2-extra: scontrol did not list it" ]'
	done
}

c_nodes_o_fail() {   # AC 11, 24 (timed)
	T_TITLE="NODES -o failures: sinfo failing (stderr, exit, signal, a record without its nonce) is 'sinfo failed (...)' with no -o call and no wait; -o failing after sinfo answered is scontrol's text byte for byte; exit 1 with nothing on stderr and no not-found line is 'scontrol failed (exit 1)'; a not-found answer with a stderr line fails; a --json timeout asks neither; the dashboard's MEMNOTE as before"
	local d start why='sinfo: error: Unable to contact slurm controller (connect failure)' swhy='scontrol: error: Unable to contact slurm controller (connect failure)'
	d=$(jfx_copy sfail resources-11964 "sinfo=@stderr $why
@exit 1")
	start=$(date +%s%N); why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "sinfo failing with stderr: W1's line, V1b's lead, no -o call, done within 1.5 s" eval '
		rc_is 0 && err_empty && [ "$(why_notes)" = "the nodes are unknown: sinfo failed ($why)" ] &&
		why_has "  waits its turn: Slurm finds too little free now on the nodes it may use (LocalQ)" && [ "$(calls scontrol)" = 1 ] &&
		[ $(( ($(date +%s%N) - start) / 1000000 )) -lt 1500 ]'
	printf '@exit 1\n' > "$d/sinfo"; why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "sinfo exit 1, nothing said: '(exit 1)'" eval 'rc_is 0 && [ "$(why_notes)" = "the nodes are unknown: sinfo failed (exit 1)" ] && [ "$(calls scontrol)" = 1 ]'
	printf '@signal 9\n' > "$d/sinfo"; why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "sinfo killed: '(signal 9)'" eval 'rc_is 0 && [ "$(why_notes)" = "the nodes are unknown: sinfo failed (signal 9)" ] && [ "$(calls scontrol)" = 1 ]'
	rs_sinfo '@raw not a record' > "$d/sinfo"; why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "a record without its nonce: W3b's '(no readable answer)'" eval 'rc_is 0 && [ "$(why_notes)" = "the nodes are unknown: sinfo failed (no readable answer)" ] && [ "$(calls scontrol)" = 1 ]'
	d=$(jfx_copy ofail resources-11964)
	{ cat "$jfx/resources-11964/scontrol-node"; printf '@stderr %s\n@exit 1\n' "$swhy"; } > "$d/scontrol-node"
	start=$(date +%s%N); why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "sinfo answering, -o exit 1 with stderr: scontrol's line byte for byte, done within 1.5 s" eval '
		rc_is 0 && err_empty && [ "$(why_notes)" = "the nodes are unknown: scontrol failed ($swhy)" ] && [ "$(node_calls)" = "scontrol --json,sinfo,scontrol -o" ] &&
		[ $(( ($(date +%s%N) - start) / 1000000 )) -lt 1500 ]'
	{ cat "$jfx/resources-11964/scontrol-node"; printf '@exit 1\n'; } > "$d/scontrol-node"
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "-o exit 1, nothing on stderr, no not-found line: 'scontrol failed (exit 1)'" eval 'rc_is 0 && err_empty && [ "$(why_notes)" = "the nodes are unknown: scontrol failed (exit 1)" ]'
	d=$(jfx_copy nfstderr resources-11964 "sinfo=$(rs_sinfo 'NodeList=fb2-extra; PartitionName=LocalQ; CPUsState=0/8/0/8; Memory=8000; AllocMem=0; StateComplete=idle')")
	{ cat "$jfx/resources-11964/scontrol-node"; printf '@stderr scontrol: warning: x\n'; } > "$d/scontrol-node"
	why_run "$d" SQSTUB_NOJSON=1 -- --no-color job 11964
	need "a not-found answer with a stderr line: the call fails (L10), scontrol's text" eval 'rc_is 0 && err_empty && [ "$(why_notes)" = "the nodes are unknown: scontrol failed (scontrol: warning: x)" ]'
	d=$(jfx_copy jtmo resources-11964)
	{ printf '@hang 10\n'; cat "$jfx/resources-11964/scontrol-node"; } > "$d/scontrol-node"
	why_run "$d" SQ_TIMEOUT=2 -- --no-color job 11964
	need "a --json timeout: no sinfo, no -o, 'scontrol failed (no response after 2s)'" eval '
		rc_is 0 && [ "$(node_calls)" = "scontrol --json" ] && [ "$(why_notes)" = "the nodes are unknown: scontrol failed (no response after 2s)" ]'
	d=$(mem_fixture membar-busy scontrol-node "@include $fixtures/membar-busy/scontrol-node\n@stderr slurm_load_node error: down\n@exit 1")
	sq_run "$d" SQSTUB_NOJSON=1 -- --full
	need "the dashboard, -o failing: the MEMNOTE of 1eb0218 byte for byte (serr the whole text now)" eval '
		rc_is 0 && err_empty && [ "$(membar_note)" = "↳ memory counts RealMemory: scontrol failed (slurm_load_node error: down)" ]'
}

c_nodes_o_bounds() {   # AC 12 (timed)
	T_TITLE="NODES -o bounds: sinfo and -o within what --json left of one budget, never waiting twice: -o gets what sinfo left (1.5 to 2.0 of 3 s; 2.5 to 3.0 of 6 s with sinfo taking 3), sinfo at least 0.1 s; timeouts named by the first bound"
	local d start v
	d=$(jfx_copy b1 resources-11964)
	printf '@hang 1\n@exit 1\n' > "$d/scontrol-node.json"
	{ cat "$jfx/resources-11964/scontrol-node"; printf '@hang 10\n'; } > "$d/scontrol-node"
	start=$(date +%s%N); why_run "$d" "$(timeout_as)" SQSTUB_TIMEOUT=log SQ_TIMEOUT=3 -- --no-color job 11964
	need "SQ_TIMEOUT=3, --json 1 s, sinfo at once, -o hanging: -o bound 1.5 to 2.0, done within 4.5 s, 'no response after 3s'" eval '
		rc_is 0 && err_empty && v=$(timeout_of scontrol 2) && gawk -v v="$v" "BEGIN { exit !(v >= 1.5 && v <= 2.0) }" &&
		[ $(( ($(date +%s%N) - start) / 1000000 )) -lt 4500 ] && [ "$(why_notes)" = "the nodes are unknown: scontrol failed (no response after 3s)" ]'
	d=$(jfx_copy b2 resources-11964 "sinfo=@hang 3
$(rs_sinfo)")
	printf '@exit 1\n' > "$d/scontrol-node.json"
	{ cat "$jfx/resources-11964/scontrol-node"; printf '@hang 10\n'; } > "$d/scontrol-node"
	start=$(date +%s%N); why_run "$d" "$(timeout_as)" SQSTUB_TIMEOUT=log SQ_TIMEOUT=6 -- --no-color job 11964
	need "SQ_TIMEOUT=6, --json failing at once, sinfo taking 3 s, -o hanging: -o bound 2.5 to 3.0, done within 7.5 s (twice would be 9)" eval '
		rc_is 0 && err_empty && v=$(timeout_of scontrol 2) && gawk -v v="$v" "BEGIN { exit !(v >= 2.5 && v <= 3.0) }" &&
		[ $(( ($(date +%s%N) - start) / 1000000 )) -lt 7500 ] && [ "$(why_notes)" = "the nodes are unknown: scontrol failed (no response after 6s)" ]'
	d=$(jfx_copy b3 resources-11964)
	printf '@hang 2.9\n@exit 1\n' > "$d/scontrol-node.json"
	why_run "$d" "$(timeout_as)" SQSTUB_TIMEOUT=log SQ_TIMEOUT=3 -- --no-color job 11964
	need "SQ_TIMEOUT=3, --json failing after 2.9 s: sinfo's bound exactly 0.100000" eval 'rc_is 0 && [ "$(timeout_of sinfo)" = 0.100000 ]'
	d=$(jfx_copy b4 resources-11964 "sinfo=@hang 10")
	why_run "$d" "$(timeout_as)" SQSTUB_TIMEOUT=log SQSTUB_NOJSON=1 SQ_TIMEOUT=2 -- --no-color job 11964
	need "sinfo hanging: 'sinfo failed (no response after 2s)', no -o call" eval '
		rc_is 0 && [ "$(why_notes)" = "the nodes are unknown: sinfo failed (no response after 2s)" ] && [ "$(calls scontrol)" = 1 ]'
}

# stub_run FIXTURE TOOL ARGS...: the stub alone (its log the current LOG),
# stdout into OUT, stderr into ERR, RC
stub_run() {
	local fx=$1; shift
	[[ $fx == /* ]] || fx=$fixtures/$fx
	SQSTUB_LOG=$LOG SQSTUB_FIXTURE=$fx "$here/bin/$@" > "$OUT" 2> "$ERR"; RC=$?
	T_CALLS=$((T_CALLS + 1))
}
c_stub_nodes() {   # AC 15 (a)-(f), (h)
	T_TITLE="the stub (N11): keys of a record only raw, before Reason=/Comment=/Extra= (\\x3d is text: -o prints the = it decodes, --json keeps the record's own); a key sq maps twice, or a NodeName again without a sinfo file, refused; a line made from sinfo has the whole memory run and State=IDLE, its --json as before; sq job's figure call made from scontrol-node's records (one row per partition, A/I/O/T, DRAIN to other, through @include, its directives not acting), a sinfo file winning; SINFO_* and --local logged; show node LIST in its order, not found on stdout and exit 1"
	local d n
	sq_env empty --; : > "$LOG"
	nodes_lines
	d=$T_DIR/fx-twice; mkdir -p "$d"; printf '%s\n' "$(line_with "$rs_big" "OS=Linux" "OS=Linux RealMemory=2000000")" > "$d/scontrol-node"
	stub_run "$d" scontrol -o show node
	need "a mapped key twice before the free text: refused, rc 97" eval '[ "$RC" = 97 ] && grep -q "^STUBERROR.*RealMemory= twice" "$LOG"'
	: > "$LOG"; printf '%s\n' "$rs_big" "$rs_big" > "$d/scontrol-node"
	stub_run "$d" scontrol --json show node
	need "a NodeName again, no sinfo file: refused, rc 97" eval '[ "$RC" = 97 ] && grep -q "^STUBERROR.*NodeName=fb2-bioinf again" "$LOG"'
	: > "$LOG"; printf '# a sinfo of its own\n' > "$d/sinfo"
	stub_run "$d" scontrol -o show node
	need "... with a sinfo file of its own: printed, rc 0" eval '[ "$RC" = 0 ] && [ "$(grep -c "^NodeName=fb2-bioinf " "$OUT")" = 2 ]'
	rm -f "$d/sinfo"; : > "$LOG"
	printf '%s\n' "$(line_with "$rs_small" "OS=Linux" 'OS=Linux RealMemory\x3d2000000')" > "$d/scontrol-node"
	stub_run "$d" scontrol -o show node
	need "\\x3d in a value: -o prints RealMemory=2000000 there and the record's own 80000" eval '[ "$RC" = 0 ] && grep -q "OS=Linux RealMemory=2000000 .* RealMemory=80000 " "$OUT"'
	stub_run "$d" scontrol --json show node
	need "... the made --json has 80000" eval '[ "$RC" = 0 ] && grep -qx " *\"real_memory\": 80000," "$OUT" && ! grep -q 2000000 "$OUT"'
	stub_run empty scontrol -o show node
	need "a line made from sinfo: the whole memory run, then State=IDLE" eval '
		[ "$RC" = 0 ] && [ "$(head -n 1 "$OUT")" = "NodeName=node01 CPUAlloc=0 CPUTot=32 CPULoad=0.01 RealMemory=128000 AllocMem=0 FreeMem=120000 Sockets=1 Boards=1 State=IDLE" ]'
	stub_run empty scontrol --json show node
	need "... its --json as before: no state, no sockets" eval '[ "$RC" = 0 ] && grep -q "\"state\": \[\]" "$OUT" && ! grep -qi sockets "$OUT"'
	n=Nabcdefghijklmnopq
	local fmt="CPUsState:0$n,NodeList:0$n,PartitionName:0$n,Memory:0$n,AllocMem:0$n,StateComplete:0$n"
	local rows; rows=$(printf '%s\n' "48/80/0/128${n}fb2-bioinf${n}LocalQ${n}1031000${n}327680${n}mixed${n}" "48/80/0/128${n}fb2-bioinf${n}main${n}1031000${n}327680${n}mixed${n}" \
		"0/24/0/24${n}fb2-bioinf-0${n}LocalQ${n}80000${n}0${n}idle${n}" "0/24/0/24${n}fb2-bioinf-0${n}small${n}80000${n}0${n}idle${n}")
	stub_run "$jfx/resources-11964" sinfo --local -h -N -O "$fmt"
	need "sq job's figure call made from resources-11964's records: fb2-bioinf in LocalQ and main (48/80/0/128), fb2-bioinf-0 in LocalQ and small (0/24/0/24)" eval '[ "$RC" = 0 ] && [ "$(cat "$OUT")" = "$rows" ]'
	d=$T_DIR/fx-inc; mkdir -p "$d"; printf '@include %s\n@exit 1\n' "$jfx/resources-11964/scontrol-node" > "$d/scontrol-node"
	stub_run "$d" sinfo --local -h -N -O "$fmt"
	need "... the same through @include, its @exit 1 not acting" eval '[ "$RC" = 0 ] && [ "$(cat "$OUT")" = "$rows" ]'
	printf '%s\n' "$(line_with "$rs_big" State=MIXED State=MIXED+DRAIN)" > "$d/scontrol-node"
	stub_run "$d" sinfo --local -h -N -O "$fmt"
	need "... DRAIN moves T-A to other: 48/0/80/128, mixed+drain" eval '[ "$RC" = 0 ] && [ "$(head -n 1 "$OUT")" = "48/0/80/128${n}fb2-bioinf${n}LocalQ${n}1031000${n}327680${n}mixed+drain${n}" ]'
	printf '@defaults CPUsState=1/1/0/2; Memory=9; AllocMem=0; StateComplete=idle\nNodeList=own; PartitionName=p\n' > "$d/sinfo"
	stub_run "$d" sinfo --local -h -N -O "$fmt"
	need "... a fixture sinfo file wins" eval '[ "$RC" = 0 ] && [ "$(cat "$OUT")" = "1/1/0/2${n}own${n}p${n}9${n}0${n}idle${n}" ]'
	: > "$LOG"; SINFO_FOO=bar stub_run "$d" sinfo --local -h -N -O "$fmt"
	need "SINFO_FOO and --local logged" eval 'grep "^CALL	sinfo	--local " "$LOG" | grep -q "	SINFO_FOO=bar"'
	stub_run "$jfx/resources-11964" scontrol -o show node fb2-bioinf-0,fb2-bioinf,nosuch
	need "show node b,a,nosuch: b, a, then 'Node nosuch not found' on stdout, exit 1" eval '
		[ "$RC" = 1 ] && [ "$(cut -d" " -f1 "$OUT" | paste -sd" ")" = "NodeName=fb2-bioinf-0 NodeName=fb2-bioinf Node" ] && [ "$(tail -n 1 "$OUT")" = "Node nosuch not found" ] && [ ! -s "$ERR" ]'
	stub_run "$jfx/resources-11964" scontrol -o show node fb2-bioinf,fb2-bioinf
	need "show node a,a: a twice, exit 0" eval '[ "$RC" = 0 ] && [ "$(grep -c "^NodeName=fb2-bioinf " "$OUT")" = 2 ]'
	stub_run "$jfx/resources-11964" scontrol --json show node fb2-bioinf
	need "--json show node LIST: refused" eval '[ "$RC" = 97 ]'
}
c_stub_fast() {   # AC 15 (g) (timed)
	T_TITLE="the stub's -o fast path: a 10 MB answer without a backslash printed within 1 s, as written"
	local d=$T_DIR/fx-big start
	mkdir -p "$d"
	sq_env empty --
	gawk 'BEGIN { s = "x"; while (length(s) < 10000) s = s s; for (i = 1; i <= 640; i++) printf "NodeName=n%04d CPUAlloc=0 CPUTot=1 RealMemory=1 AllocMem=0 FreeMem=1 Sockets=1 Boards=1 State=IDLE Partitions=p Comment=%s\n", i, substr(s, 1, 16000) }' > "$d/scontrol-node"
	start=$(date +%s%N); stub_run "$d" scontrol -o show node
	need "$(( $(wc -c < "$d/scontrol-node") / 1048576 )) MB, -o: rc 0, byte for byte, within 1 s" eval '
		[ "$RC" = 0 ] && cmp -s "$d/scontrol-node" "$OUT" && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 1000 ]'
}

c_nodes_o_cost() {   # AC 16 (timed)
	T_TITLE="NODES -o cost, each within 10 s under the 3G cap, stderr empty: node_read (cut out of sq) on 1000 records of 64 KB, 200000 continuation lines, a 5 MB OS of ␚ with 3000 runs, and node_names on 5000 names; end to end, 1000 filler nodes with 8 KB Comments, sq job's pinned fb2-bioinf row and the dashboard's 265/977G"
	local w=$T_DIR/cost r start d i
	mkdir -p "$w"
	sed -n -e '/^# ---- the character classes/,/^# ---- character classes end/p' -e '/^# ---- the node readers/,/^# ---- node readers end/p' "$sq" > "$w/readers.awk"
	nodes_lines; sq_env empty --
	reader() {   # reader ANSWER GATE: node_read's figures, a node a line, within 10 s under the cap
		start=$(date +%s%N)
		O=$1 G=$2 systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 env LC_ALL=$utf8 gawk -f "$w/readers.awk" -e 'END { node_read(ENVIRON["O"], ENVIRON["G"])
			for (n = 1; n <= NN; n++) print NODE_NAME[n], NODE_CPUS[n], NODE_REALMEM[n], NODE_SPECMEM[n], ((n in NODE_BAD) ? NODE_BAD[n] : "ok") }' /dev/null > "$w/out" 2> "$w/err"
		r=$?; T_CALLS=$((T_CALLS + 1)); [ $r = 0 ] && [ ! -s "$w/err" ] && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 10000 ]
	}
	gawk 'BEGIN { s = "x"; while (length(s) < 65536) s = s s; s = substr(s, 1, 65536)
		for (i = 1; i <= 1000; i++) { printf "NodeName=n%04d CPUAlloc=0 CPUTot=8 RealMemory=%d AllocMem=0 FreeMem=1 Sockets=1 Boards=1 MemSpecLimit=%d State=IDLE Partitions=p Comment=%s\n", i, 100000 + i, i, s; print "n" sprintf("%04d", i) > "/dev/stderr" } }' > "$w/a1" 2> "$w/g1"
	need "1000 records of 64 KB: record 500's MemSpecLimit (500)" eval 'reader "$w/a1" "$w/g1" && grep -qx "n0500 8 100500 500 ok" "$w/out" && [ "$(wc -l < "$w/out")" = 1000 ]'
	{ printf '%s\n' "$bc_big"; gawk 'BEGIN { for (i = 1; i <= 200000; i++) print "       continuation " i }'; printf '%s\n' "$bc_small"; } > "$w/a2"; printf 'fb2-bioinf\nfb2-bioinf-0\n' > "$w/g2"
	need "200000 continuation lines: the genuine spec (31000)" eval 'reader "$w/a2" "$w/g2" && grep -qx "fb2-bioinf 128 1031000 31000 ok" "$w/out"'
	LC_ALL=C gawk -v big="$bc_big" -v small="$bc_small" 'BEGIN { s = "\342\220\232"; while (length(s) < 5000000) s = s s; s = substr(s, 1, 4999998)
		r = " CPUAlloc=0 CPUTot=1 RealMemory=1 AllocMem=0 FreeMem=1 Sockets=1 Boards=1"; t = ""; for (i = 1; i <= 3000; i++) t = t r
		sub(/OS=Linux/, "OS=Linux" s t, big); print big; print small }' > "$w/a3"
	need "a 5 MB OS of ␚ with 3000 runs: garbled" eval 'reader "$w/a3" "$w/g2" && grep -qx "fb2-bioinf -1 -1 -1 garbled" "$w/out"'
	n=Nabcdefghijklmnopq
	gawk -v n="$n" 'BEGIN { for (i = 1; i <= 5000; i++) printf "1/1/0/2%sfiller-node-%05d%sLocalQ%s1000%s0%sidle%s\n", n, i, n, n, n, n, n }' > "$w/s4"
	start=$(date +%s%N)
	F=$w/s4 N=$n systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 env LC_ALL=C gawk -f "$w/readers.awk" -e 'END { k = node_names(ENVIRON["F"], ENVIRON["N"], 6, 1); print k, length(NODE_LIST) }' /dev/null > "$w/out" 2> "$w/err"
	need "node_names on 5000 names: all of them, 89999 bytes, within 10 s" eval '[ "$(cat "$w/out")" = "5000 89999" ] && [ ! -s "$w/err" ] && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 10000 ]'
	tr ',' '\n' < <(gawk -F"$n" '{ printf "%s%s", (NR > 1 ? "," : ""), $2 }' "$w/s4") > "$w/g4"
	gawk 'BEGIN { for (i = 1; i <= 5000; i++) printf "NodeName=filler-node-%05d CPUAlloc=0 CPUTot=2 RealMemory=1000 AllocMem=0 FreeMem=1 Sockets=1 Boards=1 State=IDLE Partitions=LocalQ\n", i }' > "$w/a4"
	need "... and node_read on their answer: 5000 nodes, within 10 s" eval 'reader "$w/a4" "$w/g4" && [ "$(grep -c " ok$" "$w/out")" = 5000 ]'
	# end to end through the stub's fast path
	gawk 'BEGIN { s = "x"; while (length(s) < 8192) s = s s; s = substr(s, 1, 8192)
		for (i = 1; i <= 1000; i++) printf "NodeName=filler%04d CPUAlloc=0 CPUTot=2 RealMemory=1000 AllocMem=0 FreeMem=1 Sockets=1 Boards=1 State=IDLE Partitions=LocalQ  BootTime=x Comment=%s\n", i, s }' > "$w/fillers"
	d=$(jfx_copy cost resources-11964)
	{ printf '%s\n' "$rs_big" "$rs_small"; cat "$w/fillers"; } > "$d/scontrol-node"
	start=$(date +%s%N); why_run "$d" SQSTUB_NOJSON=1 SQ_TIMEOUT=10 -- --no-color job 11964
	need "sq job, 1000 filler nodes in LocalQ with 8 KB Comments: fb2-bioinf's pinned row, within 10 s" eval '
		rc_is 0 && err_empty && why_has "    fb2-bioinf    80 of 128  656.5G of 976.5G  too few CPUs free" && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 10000 ]'
	d=$(dash_copy cost "scontrol-node=$(printf '%s\n' "$mb_big" "$mb_small"; cat "$w/fillers")" \
		"sinfo=@include $fixtures/membar-busy/sinfo
$(gawk 'BEGIN { for (i = 1; i <= 1000; i++) printf "CPUsState=0/2/0/2; NodeList=filler%04d; FreeMem=900; Memory=1000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.00; AllocMem=0\n", i }')")
	start=$(date +%s%N); sq_run "$d" SQSTUB_NOJSON=1 SQ_TIMEOUT=10 SQ_HEIGHT=1100 -- --full
	need "the dashboard, the same 1000 in its sinfo: fb2-bioinf 265/977G, within 10 s" eval '
		rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed" && [ $(( ($(date +%s%N) - start) / 1000000 )) -lt 10000 ]'
}

c_nodes_nopart() {   # AC 22
	T_TITLE="R-NOPART: a node in no partition after fb2-bioinf, which sinfo does not list: never asked about, so sq job 11955 and the dashboard are as pinned; with the list over 100000 bytes the call goes without it, scontrol lists every node, and fb2-bioinf reads ? (the residual N12 states)"
	local d spare fillers
	nodes_lines
	spare=$(line_with "${bc_small//fb2-bioinf-0/spare}" " Partitions=LocalQ,small" "")
	d=$(node_fx nopart "$bc_big" "$spare" "$bc_small")
	for how in nojson garbage; do
		o_path "$d" $how; why_run "$d" $O_ENV -- --no-color job 11955
		need "sq job 11955, -o ($how): spare never asked about, the pinned screen" eval 'rc_is 0 && err_empty && argv_is scontrol 2 -o show node fb2-bioinf,fb2-bioinf-0 && pinned_is "$bc_pinned"'
	done
	d=$(dash_copy nopart "scontrol-node=$mb_big"$'\n'"$(line_with "${mb_small//fb2-bioinf-0/spare}" " Partitions=LocalQ,small" "")"$'\n'"$mb_small")
	sq_run "$d" SQSTUB_NOJSON=1 SQSTUB_HOST=FranzGB -- --full --no-color
	need "the dashboard, -o: the accepted screen" eval 'rc_is 0 && err_empty && membar_busy_is'
	fillers=$(gawk 'BEGIN { for (i = 1; i <= 6000; i++) printf "NodeName=filler-node-%05d CPUAlloc=0 CPUTot=2 RealMemory=1000 AllocMem=0 FreeMem=1 Sockets=1 Boards=1 State=IDLE Partitions=other\n", i }')
	d=$(node_fx nopartbig "$bc_big" "$spare" "$bc_small" "$fillers")
	why_run "$d" SQSTUB_NOJSON=1 SQ_TIMEOUT=10 -- --no-color job 11955
	need "a list of 6002 names (over 100000 bytes): no list, the partition-less record joins fb2-bioinf, which reads ?" eval '
		rc_is 0 && err_empty && argv_is scontrol 2 -o show node && why_has "$bc_unknown"'
}

c_nodes_caption() {   # AC 23
	T_TITLE="the caption (N10, D7(a)): a node scontrol listed twice (M7c), did not list, gave no usable MemSpecLimit for (garbled, M7e; at or above RealMemory), several (M7f): one line under the nodes, FULL and COMPACT, on --json as on -o; none under CR_CORE; the whole-answer note wins; COMPACT keeps its height"
	local d dj fx env how kind want mode
	nodes_lines
	for kind in twice nolist garbled big; do
		# the -o answer (scontrol-node), and the --json one where the made
		# document cannot hold that flaw (a twice listed node, a member twice)
		case $kind in
			twice)   d=$(dash_copy "c-$kind" "scontrol-node=$mb_big Comment=x\\n$mb_big"$'\n'"$mb_small")
			         dj=$(json_fx membar-busy '{ print } /^    \{$/ && !s { s = 1 } s == 1 { buf = buf $0 "\n" } /^    \},$/ && s == 1 { s = 2; printf "%s", buf }') ;;
			nolist)  d=$(dash_copy "c-$kind" "scontrol-node=$mb_small"); dj=$d ;;
			garbled) d=$(dash_copy "c-$kind" "scontrol-node=$(line_with "$mb_big" "OS=Linux" 'OS=Linux RealMemory\x3d1 AllocMem\x3d0 FreeMem\x3d1 Sockets\x3d1 Boards\x3d1')"$'\n'"$mb_small")
			         dj=$(json_fx membar-busy "$json_add" NODE=fb2-bioinf KEY=specialized_memory J=0) ;;
			big)     d=$(dash_copy "c-$kind" "scontrol-node=$(line_with "$mb_big" "MemSpecLimit=31000" "MemSpecLimit=1031000")"$'\n'"$mb_small"); dj=$d ;;
		esac
		case $kind in
			twice)  want="scontrol listed it twice" ;; nolist) want="scontrol did not list it" ;; *) want="scontrol gave no usable MemSpecLimit" ;;
		esac
		for how in json nojson; do
			for mode in full compact; do
				if [ $how = json ]; then fx=$dj env=; else fx=$d env=SQSTUB_NOJSON=1; fi
				if [ $mode = full ]; then sq_run "$fx" $env -- --full --no-color; else sq_run "$fx" $env SQ_HEIGHT=12 -- --compact --no-color; fi
				need "$kind, $how, $mode: fb2-bioinf at RealMemory, fb2-bioinf-0 its own, the caption right under them" eval '
					rc_is 0 && err_empty && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 26% 265/1007G mem mixed" && mem_part_is fb2-bioinf-0 "███████████████░ 93% 70/75G mem allocated" &&
					[ "$(plain | sed -n 5p)" = "  ↳ memory counts RealMemory on fb2-bioinf: $want" ]'
				[ $mode = full ] || need "$kind, $how, compact: within 12 lines, the footer last" eval 'lines_within 12 && plain | tail -n 1 | grep -qE "^ +5 jobs "'
			done
		done
	done
	# several: two kinds, and one kind
	# a name scontrol does not know that begins a (forged) record of its own, the first line:
	# not found, so "did not list it", never "no usable MemSpecLimit" (F3 garbles that record)
	d=$(dash_copy nfrec "scontrol-node=@raw NodeName=nosuch CPUAlloc=0 CPUTot=8 RealMemory=8000 AllocMem=0 FreeMem=1 Sockets=1 Boards=1 MemSpecLimit=7000 State=IDLE
@include $fixtures/membar-busy/scontrol-node" "sinfo=@include $fixtures/membar-busy/sinfo
CPUsState=0/8/0/8; NodeList=nosuch; FreeMem=7000; Memory=8000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.00; AllocMem=0")
	sq_run "$d" SQSTUB_NOJSON=1 -- --full
	need "a not-found name that begins a record, -o: RealMemory (0/8G) with 'scontrol did not list it', the others their own" eval '
		rc_is 0 && err_empty && mem_part nosuch | grep -q " 0/8G mem idle$" && mem_part_is fb2-bioinf "████░░░░░░░░░░░░ 27% 265/977G mem mixed" &&
		[ "$(membar_note)" = "↳ memory counts RealMemory on nosuch: scontrol did not list it" ]'
	d=$(dash_copy several "scontrol-node=$(line_with "$mb_big" "MemSpecLimit=31000" "MemSpecLimit=lots")")
	for how in "" SQSTUB_NOJSON=1; do
		sq_run "$d" $how -- --full
		need "fb2-bioinf no usable, fb2-bioinf-0 not listed${how:+, -o}: one line, 'and 1 more node', the mixed kinds' text" eval '
			rc_is 0 && membar_note | grep -qxE "↳ memory counts RealMemory on fb2-bioinf and 1 more node: scontrol gave no usable MemSpecLimit( for them| ?…)"'
	done
	d=$(dash_copy three "sinfo=@include $fixtures/membar-busy/sinfo
CPUsState=0/8/0/8; NodeList=extra1; FreeMem=7000; Memory=8000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.00; AllocMem=0
CPUsState=0/8/0/8; NodeList=extra2; FreeMem=7000; Memory=8000; StateLong=idle; Reason=none; TimeStamp=Unknown; CPUsLoad=0.00; AllocMem=0" "scontrol-node=$mb_small")
	for how in "" SQSTUB_NOJSON=1; do
		sq_run "$d" $how SQ_WIDTH=200 -- --full
		need "three not listed${how:+, -o}: 'on fb2-bioinf and 2 more nodes: scontrol did not list them'" eval '
			rc_is 0 && [ "$(membar_note)" = "↳ memory counts RealMemory on fb2-bioinf and 2 more nodes: scontrol did not list them" ]'
	done
	d=$(mem_fixture membar-crcore scontrol-node "$(grep '^NodeName=fb2-bioinf-0 ' "$fixtures/membar-crcore/scontrol-node")")
	for how in "" SQSTUB_NOJSON=1; do
		sq_run "$d" $how SQSTUB_HOST=FranzGB -- --full --no-color
		need "CR_CORE, fb2-bioinf not listed${how:+, -o}: no caption, the screen as accepted" eval '
			rc_is 0 && [ -z "$(membar_note)" ] && cmp -s <(without_clock "$fixtures/membar-crcore/full-w120.txt") <(without_clock "$OUT")'
	done
	d=$(mem_fixture membar-busy scontrol-node "$mb_small\n@stderr slurm_load_node error: down\n@exit 1")
	for how in "" SQSTUB_NOJSON=1; do
		sq_run "$d" $how -- --full
		need "a node not listed and the answer failing${how:+, -o}: the whole-answer note" eval '
			rc_is 0 && [ "$(membar_note)" = "↳ memory counts RealMemory: scontrol failed (slurm_load_node error: down)" ] && membar_real'
	done
	for how in "" SQSTUB_NOJSON=1; do
		sq_run bars-edges $how -- --full
		need "nodes of RealMemory 0 and no MemSpecLimit (none kept, nothing unusable)${how:+, -o}: no caption" eval 'rc_is 0 && err_empty && [ -z "$(membar_note)" ]'
	done
}

# ---- WHOLE: a line is made of parts, each whole or absent ------------------
# (whole-design.md, WHOLE-v3).  whole_check W H reads the screen of the last
# run, cellified (cplain: one character a column), and prints one line per
# breach of the rules every COMPACT screen keeps, ACs 1-3 and 10:
#   wide        a line wider than W
#   tall        more than H lines (a pipe)
#   digit       a digit right before "…", a unit right after a digit ("2h…",
#               "4G…"), a digit and ":" before it ("1-02:11:…"), or a cut state
#               word ("RUNN…"); allowed: a first word of digits and .,:/+- the
#               guard could not back up ("↳ 2026-10…"), and the last resort
#   footer      the footer (last line) outside its forms (F-A, H9)
#   title       the title outside its forms (T-A, H1)
#   titlemax    the title not in the first form that fits (Franz: "if it
#               fits, the long variant is preferred"), from the clock it shows
#   footmax     with COUNTS ("JOBS RUNNING PENDING OTHER"), the footer not in
#               the first form of H9 that fits, the margin given only where
#               the same counts do not fit with it
#   sgr         (with --color) a line whose last SGR is not ESC[0m
# and one "lastcut N" for each row whose JOBID cell (the first) the last
# resort cut inside a number (AC 5: whether it may act there is the caller's
# to say).  NARROW (below 21 columns, where the last resort cuts any line at
# the edge, E-L2): only wide, tall, sgr, titlemax and footmax, the last two
# where their first fitting form fits at all.  The margin is 2 (no SQ_CENTER)
whole_check() {
	local w=$1 h=$2 narrow=${3:-} counts=${4:-}
	cplain | LC_ALL=$utf8 gawk -v w="$w" -v h="$h" -v host="$whole_host" -v narrow="$narrow" -v counts="$counts" '
		{ L[NR] = $0 }
		END {
			if (NR > h) print "tall " NR
			for (i = 1; i <= NR; i++) {
				x = L[i]; gsub(/\356\200\200/, "", x)                  # the fillers out, for the text
				if (length(L[i]) > w) print "wide " i ": " x
				if (narrow) continue
				if (x ~ /^ *[0-9]+… /) { print "lastcut " i; continue }
				y = x
				if (match(y, /^ *([↳⚠] +)?[0-9.,:\/+-]+…/)) y = substr(y, RSTART + RLENGTH)   # a first word of digits
				if (y ~ /[0-9]…/ || y ~ /(^|[ (])[0-9][0-9.]*[A-Za-z][A-Za-z]?…/ || y ~ /[0-9]:…/ ||
				    y ~ /(PEND|RUNN|COMPL|FAIL|CANC|TIMEO|OUT_|NODE_|PREE|SUSP|BOOT_|DEADL)[A-Z_]*…/)
					print "digit " i ": " x
			}
			for (i = 1; i <= NR && L[i] == ""; i++) ;
			t = L[i]; gsub(/\356\200\200/, "", t)
			C = ""                                      # the title, its first form that fits
			if (match(t, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9] [A-Z]+$/)) C = substr(t, RSTART)
			else if (t ~ /^ *▌/) C = "00:00:00 UTC"     # a title without its clock: the suite runs under TZ=UTC
			if (C != "") {
				F[0] = "▌ SLURM " host "  " C; F[1] = "▌ " host "  " C; F[2] = "▌ " host " " C; F[3] = "▌ " C; F[4] = C
				for (k = 0; k < 4 && length(F[k]) > w - 2; k++) ;
				if (length(F[k]) <= w - 2 && t != "  " F[k]) print "titlemax: " t " (not " F[k] ")"
			}
			if (counts != "") {                         # the footer, its first form of H9 that fits
				split(counts, Q, " ")
				nf = split("3 0 1 4|2 0 1 4|1 0 1 4|1 1 1 4|1 1 1 4 m|1 1 2 4|1 1 2 4 m|1 1 2 3|1 1 2 3 m|1 1 2 2|1 1 2 2 m", FF, "|")
				for (k = 1; k <= nf; k++) {
					split(FF[k], T, " "); g = sprintf("%*s", T[1], "")
					P[1] = Q[1] (Q[1] == 1 ? " job" : " jobs"); P[2] = Q[2] (T[2] ? " R" : " running"); P[3] = Q[3] (T[2] ? " PD" : " pending"); P[4] = Q[4] " other"
					want = ""; for (j = T[3]; j <= T[4]; j++) want = want (want != "" ? g : "") P[j]
					if (length(want) <= w - 2 + (T[5] == "m" ? 2 : 0)) break
				}
				if (k > nf) k = nf
				want = (T[5] == "m" ? "" : "  ") want
				if (length(want) <= w && L[NR] != want) print "footmax: " L[NR] " (not " want ")"
			}
			if (narrow) exit
			N = "([0-9]+|\\?)"
			f = L[NR]
			if (f !~ "^ *(" N " jobs? +" N " running +" N " pending +" N " other|(" N " jobs? +)?" N " R( +" N " PD( +" N " other)?)?)$")
				print "footer: " f
			for (i = 1; i <= NR && L[i] == ""; i++) ;
			t = L[i]; gsub(/\356\200\200/, "", t)
			C = "[0-9][0-9]:[0-9][0-9]:[0-9][0-9] [A-Z]+"
			if (t ~ /SLURM|▌/ || t ~ "^ *" C "$")
				if (t !~ "^ *(▌ SLURM " host "  " C "|▌ " host "  ?" C "|▌ " C "|" C ")$") print "title: " t
		}'
	if grep -q "$ESC\[" "$OUT"; then
		LC_ALL=C gawk -v esc="$ESC" '{ n = split($0, P, esc "\\["); if (n > 1 && P[n] !~ /^0m/) print "sgr " NR }' "$OUT"
	fi
}
whole_host=FranzGB
whole_date='[0-9]{4}-[0-9]{2}-[0-9]{2}'      # a start estimate a year or more ahead
# whole_widths FIXTURE "W..." H [sq args...]: whole_check over those widths at
# height H, the breaches as "W:what" into WBAD, the last resort into WCUT
whole_widths() {
	local fx=$1 widths=$2 h=$3 wd r counts; shift 3
	WBAD= WCUT=
	counts=$(whole_counts "$fx" "$@")
	for wd in $widths; do
		sq_run "$fx" SQSTUB_HOST=$whole_host SQ_WIDTH="$wd" SQ_HEIGHT="$h" -- --compact "$@"
		{ rc_is 0 && err_empty; } || WBAD="$WBAD $wd:rc$RC"
		while IFS= read -r r; do
			case $r in lastcut*) WCUT="$WCUT $wd:${r#lastcut }" ;; *) WBAD="$WBAD $wd:${r// /_}" ;; esac
		done < <(whole_check "$wd" "$h" "" "$counts")
	done
}
# whole_counts FIXTURE [sq args]: the four counts of the FULL footer, "JOBS RUNNING PENDING OTHER"
whole_counts() {
	local fx=$1; shift
	sq_run "$fx" SQSTUB_HOST=$whole_host SQ_WIDTH=250 -- --full "$@"
	plain | tail -n 1 | gawk '{ print $1, $3, $5, $7 }'
}
# R2 15: a count of one takes the singular, at every place sq prints a count
# with a plural noun: the footer's total, and sq job's throttle of an array
c_plural_one() {
	T_TITLE="one of a kind is singular: the footer of a queue of one job says '1 job' in each form that has the total; sq job's throttle %1 is 'at most 1 task at once', in a task's verdict and in the array's pending line; a job of one CPU in the why section's rows is '1 CPU ', aligned"
	local w want d
	sq_run trailing-junk --
	need "FULL: the footer '1 job  1 running  0 pending  0 other'" eval 'rc_is 0 && footer_is 1 1 0 0 && plain | tail -n 1 | grep -qE "^ *1 job +1 running"'
	for want in "40:  1 job  1 running  0 pending  0 other" "30:  1 job 1 R 0 PD 0 other" "24:  1 job 1 R 0 PD 0 other" "18:  1 R 0 PD 0 other"; do
		w=${want%%:*}
		sq_run trailing-junk SQ_WIDTH="$w" SQ_HEIGHT=12 -- --compact --no-color
		need "COMPACT W=$w: the footer '${want#*:}'" eval 'rc_is 0 && [ "$(plain | tail -n 1)" = "${want#*:}" ]'
	done
	d=$(pend_fx one ArrayJobID=800 ArrayTaskID=5-9%1 Reason=JobArrayTaskLimit)
	why_run "$d" -- --no-color job 800_7
	need "a task of an array throttled to %1: 'at most 1 task at once'" eval 'rc_is 0 && [ "$(why_lines | head -n 1)" = "  waits its turn: its array runs at most 1 task at once; this one starts when one of them ends" ]'
	d=$T_DIR/fx-arr1; mkdir -p "$d"; cp "$jfx/array-11367/passwd" "$jfx/array-11367/sacct" "$d/"
	sed 's/ArrayTaskID=215-216%5;/ArrayTaskID=215-216%1;/' "$jfx/array-11367/squeue-all" > "$d/squeue-all"
	why_run "$d" -- --no-color job 11367
	need "the array's pending record throttled to %1: '2 pending: the array runs at most 1 task at once'" eval 'rc_is 0 && why_lines | grep -qxF "  2 pending: the array runs at most 1 task at once"'
	# the why section's job rows: a job of one CPU says "1 CPU ", its columns where "16 CPUs" has them
	d=$(jfx_copy cpu1-ahead pending-est); sed -i 's/^\(JobID=11958;.*\)NumCPUs=64;/\1NumCPUs=1;/' "$d/squeue-queue"
	why_run "$d" -- --no-color job 11962
	need "a job ahead of one CPU: '11958  amadvi      1 CPU     500G  PENDING'" eval 'rc_is 0 && why_lines | grep -qF "    11958  amadvi      1 CPU     500G  PENDING (Resources), submitted "'
	d=$(jfx_copy cpu1-blocker resources-11964); sed -i 's/^\(JobID=11950;.*\)NumCPUs=16;/\1NumCPUs=1;/' "$d/squeue-queue"
	why_run "$d" -- --no-color job 11964
	need "a job to end first of one CPU: '11950  fsill      1 CPU      64G', beside '32 CPUs'" eval 'rc_is 0 && why_lines | grep -qxF "    11950  fsill      1 CPU      64G  21h46m left" &&
		why_lines | grep -qxF "    11875  schroder  32 CPUs    256G  no time limit"'
}
# R2 16: LEFT's INVALID (past its limit, being killed) is bold red wherever
# the queue is drawn: under UTF-8, under a gawk in C, and on a screen whose
# cells are measured by columns (WIDE, a name beyond ASCII)
c_invalid_colour() {
	T_TITLE="LEFT INVALID is bold red under UTF-8, under a gawk in C and on a WIDE screen, FULL and COMPACT; the C screen's other colours as before"
	local d=$T_DIR/fx-wide mode f
	no_utf8_locale "$T_DIR/nobin"
	mkdir -p "$d"
	for f in sinfo sacct squeue; do   # durx, one job name made wide (ö)
		sed "s|@include ../_common/|@include $fixtures/_common/|; s/j=forever;/j=f\xc3\xb6rever;/" "$fixtures/durx/$f" > "$d/$f"
	done
	for mode in --full --compact; do
		sq_run durx -- "$mode" --color
		need "UTF-8 $mode: INVALID bold red" eval 'rc_is 0 && LC_ALL=C grep -q "$ESC\[1;31m *INVALID$ESC\[0m" "$OUT"'
		cp "$OUT" "$T_DIR/utf8$mode"
		sq_run durx LC_ALL=C PATH="$T_DIR/nobin:$here/bin:$PATH" -- "$mode" --color
		need "gawk in C $mode: INVALID bold red, the screen byte for byte UTF-8's" eval 'rc_is 0 && LC_ALL=C grep -q "$ESC\[1;31m *INVALID$ESC\[0m" "$OUT" &&
			cmp -s <(without_clock "$T_DIR/utf8$mode") <(without_clock "$OUT")'
		sq_run "$d" -- "$mode" --color
		need "WIDE (a name with ö) $mode: INVALID bold red" eval 'rc_is 0 && LC_ALL=C grep -q "$ESC\[1;31m *INVALID$ESC\[0m" "$OUT"'
	done
}
# run.sh itself, stopped: under -j its one line counts the cases finished,
# also those not shown yet (a case later in order done before an earlier one)
c_suite_interrupt() {
	T_TITLE="run.sh -j 3 stopped by SIGTERM while wide_c_mode runs and two later cases are done: rc 143, one line 'interrupted by SIGTERM, 2 of 3 cases done, 0 shown', its work dir gone"
	local pid
	mkdir -p "$T_DIR/tmp"
	TMPDIR=$T_DIR/tmp bash "$here/run.sh" -j 3 wide_c_mode refuse_t_empty refuse_s > "$T_DIR/run.out" 2> "$T_DIR/run.err" &
	pid=$!
	need "the two later cases finish first" waits_for 60 eval '[ "$(find "$T_DIR/tmp" -path "*/.results/*.status" 2>/dev/null | wc -l)" -ge 2 ]'
	kill -TERM "$pid"; wait "$pid"; RC=$?
	T_CALLS=$((T_CALLS + 1))   # the stubs answered the nested run's cases (their verdicts check that)
	need "rc 143, stderr the one line, nothing shown, the work dir gone" eval 'rc_is 143 && [ "$(grep -c . "$T_DIR/run.err")" = 1 ] &&
		grep -qxF "run.sh: interrupted by SIGTERM, 2 of 3 cases done, 0 shown" "$T_DIR/run.err" && ! grep -q "^PASS" "$T_DIR/run.out" &&
		[ -z "$(find "$T_DIR/tmp" -mindepth 1 -maxdepth 1 -name "sq-tests.*")" ]'
}
c_whole_widths() {   # WHOLE ACs 1-3, 5, 10 at W 21..80
	T_TITLE="COMPACT at every width 21..80 (H 30, with and without colour): no line wider than W, no screen taller than H, no digit, unit or state word cut, footer and title each in the first of its forms that fits, every line's colour closed; the last resort only on realid's 10-digit ids below 23 columns"
	local fx args
	for fx in busy24 mix30 noacct memalloc-r oddfin membar-busy est realid huge guard guard2 nboot bars-busy elapsed24 tiny fs10 big40 "opt -o_i,j,T,Q,D,V,e,P,a,R"; do
		args=${fx#* }; [ "$args" = "$fx" ] && args= || args=${args//_/ }; fx=${fx%% *}
		# shellcheck disable=SC2086
		whole_widths "$fx" "$(seq 21 80)" 30 --no-color $args
		need "$fx: every screen at W 21..80 keeps the rules (breaches:${WBAD:- none})" test -z "$WBAD"
		case $fx in
			realid) need "realid: the last resort only in the JOBID cell below 23 columns (at:${WCUT:- none})" \
			             eval '[ -n "$WCUT" ] && ! printf "%s\n" $WCUT | grep -qvE "^2[12]:"' ;;
			*) need "$fx: the last resort never acts from 21 columns (it did at:${WCUT:- none})" test -z "$WCUT" ;;
		esac
		whole_widths "$fx" "21 24 30 37 44 52 60" 30 --color $args
		need "$fx --color: the same, and every line's last SGR ESC[0m (breaches:${WBAD:- none})" test -z "$WBAD"
	done
}
c_whole_narrow() {   # WHOLE AC 1 and 10 below 21 columns (E-L2), pipe and pty
	T_TITLE="COMPACT below 21 columns, W 1..20 at H 2, 5, 8, 12, in a pipe and on a terminal: rc 0, no line wider than W, no screen taller than H (H-1 on a terminal), every line's colour closed, the title and the footer in the first form that fits"
	local fx wd h bad= r counts
	for fx in busy24 noacct realid huge big40; do
		counts=$(whole_counts "$fx" --no-color)
		for wd in $(seq 1 20); do
			for h in 2 5 8 12; do
				sq_run "$fx" SQSTUB_HOST=$whole_host SQ_WIDTH="$wd" SQ_HEIGHT="$h" -- --compact --color
				{ rc_is 0 && err_empty; } || bad="$bad $fx:$wd:$h:rc$RC"
				while IFS= read -r r; do bad="$bad $fx:$wd:$h:${r// /_}"; done < <(whole_check "$wd" "$h" narrow "$counts")
			done
		done
	done
	need "every pipe screen below 21 columns fits (breaches:${bad:- none})" test -z "$bad"
	bad=
	for wd in 12 16; do
		PTY=1 PTY_ROWS=12 PTY_COLS=$wd sq_run busy24 TERM=xterm-256color -SQ_WIDTH -SQ_HEIGHT -- --compact
		[ "$(cplain | LC_ALL=$utf8 gawk '{ if (length($0) > m) m = length($0) } END { print m+0 }')" -le "$wd" ] || bad="$bad $wd:wide"
		lines_within 11 || bad="$bad $wd:tall"
		plain | grep -v '^$' | tail -n 1 | grep -qE '^ *[0-9]+ R' || bad="$bad $wd:footer"
	done
	need "busy24 on a terminal at W 12 and 16: every line within W, at most 11 lines, the footer present (breaches:${bad:- none})" test -z "$bad"
}
# whole_parts NODES: what the last screen shows, as one line of parts for
# the monotone check (AC 4) and the node lines (AC 3); NODES "name=state ..."
# from a FULL run (whole_nodes).  Prints "title=R foot=P/C fin=R:M q=COLS
# f=COLS node=F dur=D", and "badnode NAME LINE" for a node line that does not
# end in its whole long or short state.  R the title form (0 widest), P the
# footer counts shown, C 1 with codes, fin the finished caption (2 long, 1
# short, 0 none) and its marker (the parenthetical, or -), COLS the columns
# of the queue and the finished table by name (ST as STATE, a header cut to
# its floor by the first name it starts), F the node form (1 bars or figures,
# 2 percentages, 3 name and state, 4 name and short state, 5 digest), D 1
# where a duration of the queue is short (5h59m), 0 in Slurm's form, -1 none
whole_short='allocated alloc mixed mix draining drng drained drain completing comp reserved resv future futr failing failg planned plnd unknown unk perfctrs npc reboot boot powering_down powring_dn powered_down powered_dn power_down pow_dn power_up pow_up cancel_reboot canc_r resume resm reboot_issued boot^'
whole_nodes() {   # whole_nodes FIXTURE: "name=state ..." of a FULL screen
	sq_run "$1" SQ_WIDTH=250 -- --full --no-color
	plain | gawk '/^ +[^ ]+ .* cpu .* mem +[^ ]+$/ { printf "%s=%s ", $1, $NF }'
}
whole_parts() {
	cplain | LC_ALL=$utf8 gawk -v nodes="$1" -v short="$whole_short" -v host="$whole_host" '
		BEGIN {
			n = split(nodes, NL, " "); for (i = 1; i <= n; i++) { split(NL[i], P, "="); ST[P[1]] = P[2] }
			n = split(short, S, " "); for (i = 1; i < n; i += 2) SH[S[i]] = S[i+1]
			nq = split("JOBID NAME USER STATE TIME LEFT LIMIT CPU MEM NODE/REASON REASON PRIO NODES SUBMIT START END PART ACCOUNT QOS COMMAND WORKDIR", QH, " ")
			nf = split("JOBID NAME STATE EXIT ELAPSED AGO", FH, " ")
		}
		{ gsub(/\356\200\200/, ""); L[NR] = $0 }
		function cols(line, H, nh,   w, m, i, j, o, x) {
			m = split(line, w, " ")
			for (i = 1; i <= m; i++) {
				x = (w[i] == "ST") ? "STATE" : w[i]
				for (j = 1; j <= nh && index(H[j], x) != 1; j++) ;
				o = o (o == "" ? "" : ",") (j <= nh ? H[j] : "?" x)
			}
			return o
		}
		function shortst(s,   b, sf) { b = s; sf = ""; if (match(s, /[^a-z_]+$/)) { b = substr(s, 1, RSTART - 1); sf = substr(s, RSTART) }; return ((b in SH) ? SH[b] : b) sf }
		END {
			for (i = 1; i <= NR && L[i] == ""; i++) ;
			t = L[i]; tr = (t ~ /SLURM/) ? 0 : (t ~ ("▌ " host "  ")) ? 1 : (t ~ ("▌ " host " ")) ? 2 : (t ~ /▌/) ? 3 : 4
			f = L[NR]; fc = (f ~ / R( |$)/); fp = gsub(/[0-9?]+ (jobs|running|pending|other|R|PD)/, "&", f)
			fin = 0; mk = "-"; node = 0; dur = -1; q = f2 = ""
			for (i = 1; i <= NR; i++) {
				x = L[i]
				if (match(x, /^ *(recently finished|finished)( \([^)]*\))?:? /)) {
					fin = (x ~ /^ *recently/) ? 2 : 1
					if (match(x, /\([^)]*\)/)) mk = substr(x, RSTART, RLENGTH)
					gsub(/ /, "_", mk)
					afterfin = 1
				}
				if (x ~ /^ *(JOBI|JOBID) /) {
					if (afterfin && f2 == "") f2 = cols(x, FH, nf)
					else if (q == "") { q = cols(x, QH, nq); inq = 1; continue }
				}
				if (inq && x == "") inq = 0
				if (inq && x ~ /(^| )[0-9]+[dhm][0-9][0-9][hms]( |$)/) dur = 1
				else if (inq && !dur && x ~ /(^| )([0-9]+-)?[0-9]+:[0-9][0-9](:[0-9][0-9])?( |$)/) dur = 0
				split(x, w, " ")
				if (w[1] in ST) {
					s = ST[w[1]]
					if (x ~ /[█░▒▓·]/ || x ~ /[0-9]+\/[0-9]+ +cpu/) fm = 1
					else if (x ~ /% cpu/) fm = 2
					else if (w[2] == s && w[3] == "") fm = 3
					else if (w[2] == shortst(s) && w[3] == "") fm = 4
					else { print "badnode " w[1] " " x; fm = 9 }
					if (fm <= 2 && substr(x, length(x) - length(s)) != " " s) print "badnode " w[1] " " x
					if (fm > node) node = fm
				}
				if (x ~ /^ *nodes: /) dig = 1
			}
			if (!node && dig) node = 5
			printf "title=%d foot=%d/%d fin=%d:%s q=%s f=%s node=%d dur=%d\n", tr, fp, fc, fin, mk, q, f2, node, dur
		}'
}
# whole_mono FIXTURE H "W..." [sq args]: the parts at each width, and every
# step W -> W+1 that shows fewer (AC 4): a later title form, fewer footer
# counts or codes where words stood, a shorter finished caption or marker, a
# column gone from either table, a narrower node form, short durations where
# Slurm's stood at the same columns (H0: a column that goes hands its width
# to the long durations too).  The breaches into WMONO, bad node lines into WNODE
whole_mono() {
	local fx=$1 h=$2 widths=$3 nodes wd p prev= pw=; shift 3
	WMONO= WNODE=
	nodes=$(whole_nodes "$fx")
	for wd in $widths; do
		sq_run "$fx" SQSTUB_HOST=$whole_host SQ_WIDTH="$wd" SQ_HEIGHT="$h" -- --compact --no-color "$@"
		p=$(whole_parts "$nodes")
		while read -r k rest; do [ "$k" = badnode ] && WNODE="$WNODE $wd:$rest"; done <<< "$p"
		p=$(grep -v '^badnode' <<< "$p")
		if [ -n "$prev" ]; then
			WMONO="$WMONO$(gawk -v a="$prev" -v b="$p" -v wa="$pw" -v wb="$wd" '
				function get(s, k,   m) { return match(s, k "=[^ ]*") ? substr(s, RSTART + length(k) + 1, RLENGTH - length(k) - 1) : "" }
				function sub_of(x, y,   X, n, i) { n = split(x, X, ","); for (i = 1; i <= n; i++) if (index("," y ",", "," X[i] ",") == 0) return 0; return 1 }
				BEGIN {
					if (get(b, "title") > get(a, "title")) o = o " title"
					split(get(a, "foot"), FA, "/"); split(get(b, "foot"), FB, "/")
					if (FB[1] < FA[1] || (FB[1] == FA[1] && FB[2] > FA[2])) o = o " footer"
					split(get(a, "fin"), NA, ":"); split(get(b, "fin"), NB, ":")
					if (NB[1] < NA[1] || length(NB[2]) < length(NA[2]) && NA[2] != "-" || NB[2] == "-" && NA[2] != "-") o = o " fincaption"
					if (!sub_of(get(a, "q"), get(b, "q"))) o = o " qcols"
					if (!sub_of(get(a, "f"), get(b, "f"))) o = o " fcols"
					if (get(b, "node") > get(a, "node") && get(a, "node") > 0) o = o " node"
					if (get(a, "dur") == 0 && get(b, "dur") == 1 && get(a, "q") == get(b, "q")) o = o " durations"   # at equal columns: a dropped column may give its width to the long form
					if (o != "") printf " %s>%s:%s", wa, wb, substr(o, 2)
				}')"
		fi
		prev=$p pw=$wd
	done
}
c_whole_monotone() {   # WHOLE AC 3, 4 (the parts of a line, by width)
	T_TITLE="COMPACT W 21..80 at H 40: a wider screen never shows fewer parts (the title, the footer counts, the finished caption and marker, the columns of both tables, the node form, the durations long once long at the same columns); every node line ends in its whole long or short state; v3.1's sets too (throttled, jobmem-arrays, pending-strided, lists, guard, firstw with and without -o)"
	local fx args
	for fx in busy24 mix30 noacct memalloc-r oddfin membar-busy bars-busy nboot est big40 "opt -o_i,j,T,Q,D,V,e,P,a,R" \
	          throttled jobmem-arrays pending-strided lists guard firstw "firstw -o_i,j,T,R"; do
		args=${fx#* }; [ "$args" = "$fx" ] && args= || args=${args//_/ }; fx=${fx%% *}
		# shellcheck disable=SC2086
		whole_mono "$fx" 40 "$(seq 21 80)" $args
		need "$fx: no part lost from W to W+1 (lost:${WMONO:- none})" test -z "$WMONO"
		need "$fx: every node line ends in its whole state (not:${WNODE:- none})" test -z "$WNODE"
	done
}
c_whole_full() {   # WHOLE AC 6 (R-H3, R-H4, decision 4)
	T_TITLE="FULL at W 40..120: every column of the widest screen in both tables, STATE long (no ST, no state code in the finished rows), Slurm's durations in the queue, no digit, unit or state word cut"
	local fx wd p want bad
	for fx in busy24 mix30 noacct memalloc-r oddfin exits-fallback est fs10 bars-busy; do
		sq_run "$fx" SQ_WIDTH=250 SQ_HEIGHT=50 -- --full --no-color; want=$(whole_parts "" | grep -o 'q=[^ ]* f=[^ ]*')
		bad=
		for wd in 40 60 80 100 120; do
			sq_run "$fx" SQ_WIDTH="$wd" SQ_HEIGHT=50 -- --full --no-color
			rc_is 0 && err_empty || bad="$bad $wd:rc$RC"
			p=$(whole_parts "")
			[ "$(grep -o 'q=[^ ]* f=[^ ]*' <<< "$p")" = "$want" ] || bad="$bad $wd:columns($(grep -o 'q=[^ ]* f=[^ ]*' <<< "$p"))"
			! grep -q 'dur=1' <<< "$p" || bad="$bad $wd:durations"
			plain | gawk '/^ *(JOBI|JOBID) / && seen++ { f = 1; next } f && /^ *[^ ]+ +[^ ]+ +(CD|F|CA|OOM|TO|NF|PR|SE|BF|DL|RV|ST)( |$)/ { bad = 1 } END { exit bad }' || bad="$bad $wd:statecode"
			bad="$bad$(whole_check "$wd" 1000 | grep -v '^wide\|^tall\|^lastcut\|^footer\|^title' | sed "s/^/ $wd:/" | tr '\n' ' ')"
		done
		need "$fx FULL: no column dropped, no short form taken, nothing cut but text (breaches:${bad:- none})" eval '[ -z "${bad// /}" ]'
	done
}
c_whole_c_mode() {   # WHOLE AC 9
	T_TITLE="no UTF-8 locale (gawk in C): COMPACT on ASCII fixtures at W 21..60 step 3, with and without colour, byte for byte the UTF-8 screen"
	local nobin=$T_DIR/nobin fx wd col want bad=
	no_utf8_locale "$nobin"
	for fx in busy24 noacct oddfin mix30 memalloc-r nboot; do
		for wd in $(seq 21 3 60); do
			for col in --no-color --color; do
				# a start estimate today reads HH:MM, which a minute rolling over between the runs moves
				sq_run "$fx" SQ_WIDTH="$wd" SQ_HEIGHT=30 -- --compact $col; want=$RUN/screen; without_clock "$OUT" | mask_estimates > "$want"
				sq_run "$fx" SQ_WIDTH="$wd" SQ_HEIGHT=30 LC_ALL=C "PATH=$nobin:$here/bin:$PATH" -- --compact $col
				{ rc_is 0 && err_empty && cmp -s "$want" <(without_clock "$OUT" | mask_estimates); } || bad="$bad $fx:$wd$col"
			done
		done
	done
	need "C mode equals UTF-8 byte for byte (not:${bad:- none})" test -z "$bad"
}
# the job ids a screen shows (queue and finished rows, the one finished line;
# the footer, the last line, aside),
# a bracket or task id by its base: one per line
whole_ids() {
	plain | sed '$d' | gawk 'match($0, /^ *((recently )?finished[^:]*: )?[0-9]+(_[^ ]*)? /) {
		x = substr($0, RSTART, RLENGTH); sub(/^ *((recently )?finished[^:]*: )?/, "", x); sub(/ $/, "", x)
		if (index(x, "_")) x = substr(x, 1, index(x, "_")); print x }' | sort -u
}
c_whole_height() {   # WHOLE AC 4 in H, AC 11 (H11, decision 8)
	T_TITLE="COMPACT H 2..60: no screen taller than H, and every job id a screen shows at H it shows at H+1 too (big40 at W 40 and 120, n12busy at 100, busy24, mix30, noacct, nboot at 80; big40 and busy24 with --reserve 3)"
	local run fx wd h prev ids lost= tall= args widths
	for run in "big40 40,120" "n12busy 100" "busy24 80" "mix30 80" "noacct 80" "nboot 80" "big40 120 --reserve_3" "busy24 80 --reserve_3"; do
		read -r fx widths args <<< "$run"; args=${args//_/ }
		for wd in ${widths//,/ }; do
			prev=
			for h in $(seq 2 60); do
				# shellcheck disable=SC2086
				sq_run "$fx" SQ_WIDTH="$wd" SQ_HEIGHT="$h" -- --compact --no-color $args
				lines_within "$h" || tall="$tall $fx:$wd:$h"
				ids=$(whole_ids)
				[ -z "$prev" ] || [ -z "$(comm -23 <(printf '%s\n' "$prev") <(printf '%s\n' "$ids"))" ] || lost="$lost $fx${args:+($args)}:$wd:$((h-1))>$h"
				prev=$ids
			done
		done
	done
	need "no screen taller than H (at:${tall:- none})" test -z "$tall"
	need "a taller screen never loses a job id (lost at:${lost:- none})" test -z "$lost"
}
# a line of the last screen, its runs of blanks as one: words_line TEXT
words_line() { plain | sed -E 's/ +/ /g; s/^ //; s/ $//' | grep -qxF -- "$1"; }
words_has()  { plain | sed -E 's/ +/ /g' | grep -qF -- "$1"; }
c_whole_pins() {   # WHOLE AC 8: the pinned cases, each its rule
	T_TITLE="WHOLE's pins: the estimate (H5), the durations (H-1), the drops before the code (R-H3), the finished line (N-B, R-H1, E-M3), the JOBID cell (E-M4), the node forms (R-M2, M-3, H3), -o columns (O-A), the footer margin (R-M5), the guard (E-M2), the height cap (H11), MEM never cut (R-L5), v1's pins"
	local wd h
	# H5, E-M1, H-2: the estimate a number, the reason cut at whole words
	for wd in 66 70 74; do
		sq_run mixed SQ_WIDTH=$wd -- --full --no-color
		need "mixed FULL W=$wd: the estimate alone, → DATE" eval 'rc_is 0 && plain | grep -qE " 4G → '"$whole_date"'$"'
	done
	sq_run mixed SQ_WIDTH=80 -- --full --no-color
	need "mixed FULL W=80: (Resources) → DATE" eval 'plain | grep -qE " 4G \(Resources\) → '"$whole_date"'$"'
	sq_run est SQ_WIDTH=110 -- --full --no-color
	need "est W=110: the reason whole" matches "\(ReqNodeNotAvail, UnavailableNodes:node02\) → $whole_date"
	for wd in 100 102; do
		sq_run est SQ_WIDTH=$wd -- --full --no-color
		need "est W=$wd: the key kept, its item gone" eval 'plain | grep -qE " \(ReqNodeNotAvail, UnavailableNodes:… → '"$whole_date"'$"'
	done
	sq_run est SQ_WIDTH=96 -- --full --no-color
	need "est W=96: the first item whole, then …" eval 'plain | grep -qE " \(ReqNodeNotAvail, … → '"$whole_date"' *$"'
	sq_run est SQ_WIDTH=70 -- --full --no-color
	need "est W=70: the estimate alone" eval 'plain | grep -qE " 4G → '"$whole_date"'$"'
	for wd in 104 108; do
		sq_run mix30 SQ_WIDTH=$wd SQ_HEIGHT=30 -- --compact --no-color
		need "mix30 COMPACT 30 lines W=$wd: (ReqNodeNotAvail, UnavailableNodes:…" eval 'plain | grep -qE "\(ReqNodeNotAvail, UnavailableNodes:…$"'
	done
	sq_run estreal SQ_WIDTH=150 SQ_HEIGHT=30 -- --compact --no-color
	need "estreal W=150: the reasons whole" eval 'has "(ReqNodeNotAvail, UnavailableNodes:fb2-bioinf,fb2-bioinf-0) → " && ! has "…"'
	# H-1 (c), R-H4: the durations
	sq_run memalloc-r SQ_WIDTH=60 -- --full --no-color
	need "memalloc-r FULL W=60: TIME and LEFT in Slurm's form, STATE long" eval 'words_has "PENDING 0:00 1-00:00:00 8 48G" && ! rows queue | grep -qE "[0-9]+[dh][0-9]{2}[hm] "'
	sq_run memalloc-r SQ_WIDTH=50 SQ_HEIGHT=30 -- --compact --no-color
	need "memalloc-r COMPACT W=50: the short form 1d19h" words_has " 1d19h "
	sq_run memalloc-r SQ_WIDTH=100 SQ_HEIGHT=30 -- --compact --no-color
	need "memalloc-r COMPACT W=100: Slurm's 1-19:47:27" eval 'words_has " 1-19:47:27 " && ! words_has " 1d19h "'
	# R-H3: the code only after the drops; L-4 the header floor
	sq_run busy24 SQ_WIDTH=52 SQ_HEIGHT=30 -- --compact --no-color
	need "busy24 52x30: CPU gone, STATE long" words_line "JOBID NAME USER STATE TIME LEFT MEM NODE/R"
	sq_run busy24 SQ_WIDTH=16 SQ_HEIGHT=30 -- --compact --no-color
	need "busy24 W=16: the code, ST" eval 'plain | grep -qE "^ *JOBID ST "'
	sq_run busy24 SQ_WIDTH=36 SQ_HEIGHT=16 -- --compact --no-color
	need "busy24 36x16: JOBID NAME STATE LEFT NODE/R" words_line "JOBID NAME STATE LEFT NODE/R"
	# N-B, R-H1: the finished line
	sq_run noacct SQ_WIDTH=56 SQ_HEIGHT=30 -- --compact --no-color --reservation=maint
	need "noacct --reservation=maint W=56: the short marker names the filter" words_line "finished (--reservation: no sacct): 4188 qc FAILED 1"
	sq_run mix30 SQ_WIDTH=28 SQ_HEIGHT=14 -- --compact --no-color
	need "mix30 28x14: the state long while it fits" eval 'matches "PENDING" && ! matches "^ *[0-9]+ +PD "'
	# E-M3: EXIT's forms
	sq_run fs10 SQ_WIDTH=21 SQ_HEIGHT=30 -- --compact --no-color
	need "fs10 W=21: 987654 CA 0/sig15" words_line "987654 CA 0/sig15"
	sq_run fs10 SQ_WIDTH=24 SQ_HEIGHT=14 -- --compact --no-color
	need "fs10 24x14: the table 987654 CA 0/sig15" words_line "987654 CA 0/sig15"
	# E-M4: the cut inside the JOBID cell, the other columns at their floors
	sq_run realid SQ_WIDTH=24 SQ_HEIGHT=30 -- --compact --no-color
	need "realid W=24: 4294967294_… R node01" words_line "4294967294_… R node01"
	sq_run realid SQ_WIDTH=21 SQ_HEIGHT=30 -- --compact --no-color
	need "realid W=21: the cut inside the JOBID cell, ST and the reason at their floors" eval 'words_line "JOBID ST NODE/" && words_line "429496729… R node…"'
	# R-M2, M-3, H3: the node forms and the digest
	sq_run membar-busy SQ_WIDTH=22 SQ_HEIGHT=30 -- --compact --no-color
	need "membar-busy W=22: fb2-bioinf-0 alloc" words_line "fb2-bioinf-0 alloc"
	for wd in 24 30; do
		sq_run bars-idle SQ_WIDTH=$wd SQ_HEIGHT=5 -- --compact --no-color
		need "bars-idle ${wd}x5: nodes: 2 idle · …" words_line "nodes: 2 idle · …"
	done
	sq_run nboot SQ_WIDTH=28 SQ_HEIGHT=30 -- --compact --no-color
	need "nboot W=28: nodes: 1 powring_dn, … · …" words_line "nodes: 1 powring_dn, … · …"
	sq_run nboot SQ_WIDTH=30 SQ_HEIGHT=30 -- --compact --no-color
	need "nboot W=30: the short states" eval 'words_line "gpu-a100-node07 boot^" && words_line "gpu-a100-node08 powring_dn"'
	sq_run nboot SQ_WIDTH=36 SQ_HEIGHT=30 -- --compact --no-color
	need "nboot W=36: the long states" eval 'words_line "gpu-a100-node07 reboot^" && words_line "gpu-a100-node08 powering_down"'
	# O-A: the columns a -o adds go before the code
	sq_run opt SQ_WIDTH=30 SQ_HEIGHT=30 -- --compact --no-color -o '%i %j %T %Q %D %V %e %P %a %R'
	need "opt W=30: JOBID NAME STATE NODE/RE" words_line "JOBID NAME STATE NODE/RE"
	sq_run opt SQ_WIDTH=40 SQ_HEIGHT=30 -- --compact --no-color -o '%i %j %T %Q %D %V %e %P %a %R'
	need "opt W=40: JOBID NAME STATE PRIO NODE/R" words_line "JOBID NAME STATE PRIO NODE/R"
	# R-M5: the margin before a count
	sq_run huge SQ_WIDTH=26 SQ_HEIGHT=30 -- --compact --no-color
	need "huge W=26: every count, without the margin" eval '[ "$(plain | tail -n 1)" = "12345 R 1100000 PD 1 other" ]'
	sq_run huge SQ_WIDTH=24 SQ_HEIGHT=30 -- --compact --no-color
	need "huge W=24: other gone, the margin back" eval '[ "$(plain | tail -n 1)" = "  12345 R 1100000 PD" ]'
	# E-M2: the guard
	sq_run guard SQ_WIDTH=21 SQ_HEIGHT=30 -- --compact --no-color
	need "guard W=21: ↳ swap --mem=…" words_line "↳ swap --mem=…"
	sq_run guard SQ_WIDTH=24 SQ_HEIGHT=30 -- --compact --no-color
	need "guard W=24: ↳ swap --mem=4G …" words_line "↳ swap --mem=4G …"
	sq_run guard2 SQ_WIDTH=19 SQ_HEIGHT=30 -- --compact --no-color
	need "guard2 W=19: ↳ ticket#… (v3.1 LC: from W=21 ticket#4711-…, whole_v31)" words_line "↳ ticket#…"
	# H11, H-3: the height cap
	for h in 22 43; do
		sq_run big40 SQ_WIDTH=120 SQ_HEIGHT=$h -- --compact --no-color
		need "big40 120x$h: the digest, no job row" eval 'matches "^ *nodes: " && ! matches "^ +[0-9]{3,}[ _]" && ! matches "jobs running"'
	done
	sq_run big40 SQ_WIDTH=120 SQ_HEIGHT=44 -- --compact --no-color
	need "big40 120x44: the node lines, no job row" eval '! matches "^ *nodes: " && ! matches "^ +[0-9]{3,}[ _]"'
	sq_run big40 SQ_WIDTH=120 SQ_HEIGHT=50 -- --compact --no-color
	need "big40 120x50: … 5 jobs running" has "… 5 jobs running"
	sq_run big40 SQ_WIDTH=120 SQ_HEIGHT=53 -- --compact --no-color
	need "big40 120x53: the running rows" eval 'matches "^ +[0-9]{3,} .* RUNNING " && lacks "jobs running"'
	sq_run n12busy SQ_WIDTH=100 SQ_HEIGHT=19 -- --compact --no-color
	need "n12busy 100x19: the digest, the 3 stuck rows, the failure" eval 'matches "^ *nodes: 12 mixed" && [ "$(whole_ids | paste -sd" ")" = "4188 4201 4202 4207" ]'
	sq_run n12busy SQ_WIDTH=100 SQ_HEIGHT=20 -- --compact --no-color
	need "n12busy 100x20: the 12 node lines and the same rows" eval '[ "$(plain | grep -cE "^ +n[0-9]{2} ")" = 12 ] && [ "$(whole_ids | paste -sd" ")" = "4188 4201 4202 4207" ]'
	# R-L5: MEM never cut
	sq_run memalloc-tresfail SQ_WIDTH=53 SQ_HEIGHT=16 -- --compact --no-color
	need "memalloc-tresfail 53x16: 16 lines, MEM whole" eval 'rc_is 0 && [ "$(plain | wc -l)" = 16 ] && words_has " !100G " && ! matches "[0-9.]+…G|!1…"'
	# v1's pins
	for wd in 60 80; do
		sq_run oddfin SQ_WIDTH=$wd SQ_HEIGHT=30 -- --compact --no-color
		need "oddfin W=$wd: ELAPSED whole" eval 'matches "ELAPSED" && ! rows recent | gawk "{ print \$(NF-1) }" | grep -q "…"'
	done
	sq_run exits-fallback SQ_WIDTH=30 SQ_HEIGHT=30 -- --compact --no-color
	need "exits-fallback W=30: 137 whole" words_has " 137"
	for wd in 21 22 23 24 25; do
		sq_run busy24 SQ_WIDTH=$wd SQ_HEIGHT=30 -- --compact --no-color
		need "busy24 W=$wd: the clock whole in the title" eval 'plain | head -n 1 | grep -qE "[0-9]{2}:[0-9]{2}:[0-9]{2} [A-Z]+$"'
	done
	for wd in 21 30 40 50 60; do
		sq_run busy24 SQ_WIDTH=$wd SQ_HEIGHT=30 -- --compact --no-color
		need "busy24 W=$wd: down* whole" eval 'plain | grep -qE " down\*$"'
	done
}
c_whole_captions() {   # WHOLE AC 13 (R-L7): NODES' MEMNOTE under H8 and W8
	T_TITLE="the MEMNOTE caption cut by H8, the node it names never cut (W8): scnolist at 44 and 56, nodes-cntrl at 44"
	sq_run scnolist SQ_WIDTH=44 SQ_HEIGHT=30 -- --compact --no-color
	need "scnolist W=44: ↳ memory counts RealMemory …, the cut before ' on NODE'" words_line "↳ memory counts RealMemory …"
	sq_run scnolist SQ_WIDTH=56 SQ_HEIGHT=30 -- --compact --no-color
	need "scnolist W=56: … on fb2-bioinf-0: scontrol …" words_line "↳ memory counts RealMemory on fb2-bioinf-0: scontrol …"
	sq_run nodes-cntrl SQ_WIDTH=44 SQ_HEIGHT=30 -- --compact --no-color
	need "nodes-cntrl W=44: ↳ memory counts RealMemory on node? and …" words_line "↳ memory counts RealMemory on node? and …"
}
c_whole_docs() {   # WHOLE AC 12 (H12)
	T_TITLE="sq -h and the README: COMPACT fits every measured width, below 21 columns too, by shorter forms of whole parts, a line cut only below its shortest form; FULL wraps; the README keeps 'Numbers are never cut while anything else can give'"
	local readme=${here%/*}/README.md
	sq_run empty -- -h
	need "sq -h: COMPACT fits every width, FULL wraps" eval 'rc_is 0 && plain | tr "\n" " " | sed -E "s/ +/ /g" |
		grep -qF "COMPACT fits every width it can measure, below 21 columns too: its lines take shorter forms of whole parts (sinfo'"'"'s short node states, durations as 5h59m once the text columns are at 8, fewer columns, Slurm'"'"'s state codes last), and a line is cut only below its shortest form. FULL takes none of these forms: its long lines wrap."'
	need "sq -h: no 'Below about 60 columns'" lacks "Below about 60 columns"
	need "README: COMPACT fits every width, a line cut only below its shortest form, FULL wraps; no floor of 60 columns" eval '
		tr "\n" " " < "$readme" | sed -E "s/ +/ /g" | grep -qF "COMPACT fits every width it can measure, below 21 columns too" &&
		tr "\n" " " < "$readme" | sed -E "s/ +/ /g" | grep -qF "A line is cut only below its shortest form. FULL takes none of these forms: its long lines wrap." &&
		! grep -qF "cannot shrink below about 60 columns" "$readme"'
	need "README: 'Numbers are never cut while anything else can give' stays" grep -qF "Numbers are never cut while anything else can give." "$readme"
	stubs_answer
}

# a line of the last screen as printed, blanks and all: line_is TEXT
line_is() { plain | grep -qxF -- "$1"; }
# WHOLE fix round 1 (review MEDIUM 3): each line kind takes the first of its
# forms that fits (the title and the footer: whole_check's titlemax and
# footmax in whole_widths and whole_narrow; the node form here), and the
# orders inside a line kind, each pinned at a width where it alone decides
c_whole_forms() {   # WHOLE H2: the node lines' first form that fits
	T_TITLE="the node lines take the first form that fits: busy24 W=38 'name P% cpu  M% mem  state' (37: name and state), W=60 the figures without bars, W=70 the bars; pct W=40 the percentages a 5-digit one widens (39: name and state)"
	sq_run busy24 SQ_WIDTH=37 SQ_HEIGHT=30 -- --compact --no-color
	need "busy24 W=37: name and state" words_line "node01 allocated"
	sq_run busy24 SQ_WIDTH=38 SQ_HEIGHT=30 -- --compact --no-color
	need "busy24 W=38: the percentages" line_is "  node01 100% cpu   88% mem  allocated"
	sq_run busy24 SQ_WIDTH=60 SQ_HEIGHT=30 -- --compact --no-color
	need "busy24 W=60: the figures, no bars" line_is "  node01 100%  128/128 cpu    88%  443/503G mem    allocated"
	sq_run busy24 SQ_WIDTH=70 SQ_HEIGHT=30 -- --compact --no-color
	need "busy24 W=70: the bars" matches "^  node01 █+ 100%  128/128 cpu   [█░]+  88%  443/503G mem  allocated$"
	sq_run pct SQ_WIDTH=39 SQ_HEIGHT=30 -- --compact --no-color
	need "pct W=39: name and state (the percentages need their excess)" words_line "node01 allocated"
	sq_run pct SQ_WIDTH=40 SQ_HEIGHT=30 -- --compact --no-color
	need "pct W=40: the percentages, 15000% widening the line" line_is "  node01 100% cpu  15000% mem  allocated"
}
c_whole_orders() {   # WHOLE H6, H7, E-M3, R-M1: the orders inside a line kind
	T_TITLE="the finished table drops ELAPSED, AGO, NAME before the state code and the code before EXIT, cuts the canceller before the exits; the finished line gives the name before the marker, the caption before the code, cuts a name to 3 at least, and the id takes its F2 forms; the queue's id keeps ×N and its terms in order (bars-busy W 63/64, 72/73)"
	local wd
	# H6.3: ELAPSED, AGO, NAME go in that order
	sq_run oddfin SQ_WIDTH=33 SQ_HEIGHT=30 -- --compact --no-color
	need "oddfin W=33: AGO gone with ELAPSED and NAME, STATE long" words_line "JOBID STATE EXIT"
	sq_run fs10 SQ_WIDTH=30 SQ_HEIGHT=30 -- --compact --no-color
	need "fs10 W=30: the canceller cut, AGO gone" eval 'words_line "JOBID STATE EXIT" && words_line "987654 CANCELLED 0/sig15 by…"'
	# H6.4 after the drops: the code is taken only where the table is still too wide
	sq_run fs10 SQ_WIDTH=22 SQ_HEIGHT=30 -- --compact --no-color
	need "fs10 W=22: the code, JOBID at its width after the drops" line_is "  987654   CA  0/sig15"
	sq_run exits SQ_WIDTH=25 SQ_HEIGHT=30 -- --compact --no-color
	need "exits W=25: the code beside JOBID's next form" line_is "  6200_…  F           2,…"
	# E-M3: the canceller gives before the exits
	sq_run exits SQ_WIDTH=59 SQ_HEIGHT=30 -- --compact --no-color
	need "exits W=59: the canceller gone, the exits and the id's terms kept" eval 'words_line "6200_[…] ×6 sweep FAILED 2,… 1m00s 1m" && words_line "6110 killed CANCELLED 0/err53 1m00s 15m"'
	sq_run exits SQ_WIDTH=64 SQ_HEIGHT=30 -- --compact --no-color
	need "exits W=64: by… beside the id's whole terms" eval 'words_line "6200_[0-5] ×6 sweep FAILED 2,… 1m00s 1m" && words_line "6110 killed CANCELLED 0/err53 by… 1m00s 15m"'
	# H7: the finished line's order
	sq_run noacct SQ_WIDTH=28 SQ_HEIGHT=14 -- --compact --no-color --reservation=maint
	need "noacct --reservation=maint 28x14: the name gone, then the marker" words_line "finished: 4188 FAILED 1"
	for wd in 21 24; do
		sq_run noacct SQ_WIDTH=$wd SQ_HEIGHT=14 -- --compact --no-color
		need "noacct ${wd}x14: the caption gone before the code" words_line "4188 FAILED 1"
	done
	for wd in 27 28; do
		sq_run mix30 SQ_WIDTH=$wd SQ_HEIGHT=14 -- --compact --no-color
		need "mix30 ${wd}x14: a name of fewer than 3 columns goes whole" words_line "finished: 5097 FAILED 2"
	done
	for c in "24:9876543210_… ×3 F 4,…" "25:9876543210_… FAILED 4,…" "30:9876543210_[…] ×3 FAILED 4,…" \
	         "34:9876543210_[1-2,4] ×3 FAILED 4,…" "35:finished: 9876543210_… FAILED 4,…" "40:finished: 9876543210_[…] ×3 FAILED 4,…"; do
		sq_run oddfin SQ_WIDTH=${c%%:*} SQ_HEIGHT=14 -- --compact --no-color
		need "oddfin ${c%%:*}x14: the finished line ${c#*:} (R-M1 c, H0's late-part trade)" words_line "${c#*:}"
	done
	# R-M1 (AC 4): the queue's id keeps ×N, its terms come back in order
	for c in "63:5001_[…] ×7 assemb… alice RUNNING 3h12m 4d20h 16 90G fb2-bi…" "64:5001_[…] ×7 assemb… alice RUNNING 3h12m 4d20h 16 90G fb2-bio…" \
	         "72:5001_[0-6] ×7 assemble alice RUNNING 3h12m 4d20h 16 90G fb2-bioinf" "73:5001_[0-6] ×7 assemble alice RUNNING 3h12m 4d20h 16 90G fb2-bioinf"; do
		sq_run bars-busy SQ_WIDTH=${c%%:*} SQ_HEIGHT=30 -- --compact --no-color
		need "bars-busy W=${c%%:*}: ${c#*:}" words_line "${c#*:}"
	done
}
c_whole_guard() {   # WHOLE H8, H5, H4 L-3 and the long durations back, each where it alone decides
	T_TITLE="the guard repeats (went x 12:30:45), drops a digit word ended by ':' (9:30), no bare count ends a cut (CPUsLoad (2), the reason beside an estimate ends at no digit word but keeps a whole list item (node01,…), '… n jobs' takes its short name, L-3 gives the guard's blanks to another text column, the long durations come back after a drop, the short ones only after the FLEX columns are at 8"
	local wd
	for wd in 21 22 23; do
		sq_run guard3 SQ_WIDTH=$wd SQ_HEIGHT=30 -- --compact --no-color
		need "guard3 W=$wd: ↳ went x … (the guard twice: 12:30:… then 12:…)" words_line "↳ went x …"
	done
	sq_run guard3 SQ_WIDTH=21 SQ_HEIGHT=30 -- --compact --no-color
	need "guard3 W=21: ↳ maint at … (the digit word 9: goes)" words_line "↳ maint at …"
	sq_run guard3 SQ_WIDTH=105 SQ_HEIGHT=30 -- --compact --no-color
	need "guard3 W=105: the reason beside the estimate ends before node01 (H5)" matches " \(ReqNodeNotAvail, UnavailableNodes:… → $whole_date$"
	sq_run estdig SQ_WIDTH=104 SQ_HEIGHT=30 -- --compact --no-color
	need "estdig W=104: beside the estimate a list item ending in a digit stays whole before ',' (L2: node01,…)" matches " \(ReqNodeNotAvail, UnavailableNodes:node01,… → $whole_date$"
	sq_run cpusload-garbage SQ_WIDTH=49 SQ_HEIGHT=30 -- --compact --no-color
	need "cpusload-garbage W=49: no bare count ends the caption" words_line "↳ sinfo gave no usable figure for CPUsLoad …"
	sq_run faults SQ_WIDTH=24 SQ_HEIGHT=12 -- --compact --no-color
	need "faults 24x12: … 5 jobs blocked (the short name)" words_line "… 5 jobs blocked"
	sq_run estreal SQ_WIDTH=59 SQ_HEIGHT=30 -- --compact --no-color
	need "estreal W=59: NAME gives the guard's blanks to NODE/REASON (L-3)" words_line "JOBID NAME USER STATE TIME LEFT CPU MEM NODE/REAS"
	sq_run est SQ_WIDTH=41 SQ_HEIGHT=40 -- --compact --no-color
	need "est 41x40: USER gone, LEFT back in Slurm's form" eval 'words_line "JOBID NAME STATE LEFT MEM NODE/REA" && words_line "1201 prep PENDING 1:00:00 4G (ReqNod…"'
	sq_run durx SQ_WIDTH=54 SQ_HEIGHT=40 -- --compact --no-color
	need "durx 54x40: TIME gone, LEFT back in Slurm's form" words_line "9004 sec alice RUNNING 0:01 4G node01"
	# H4.2: the short durations only after the FLEX columns are at 8
	for wd in 64 72; do
		sq_run longplain SQ_WIDTH=$wd SQ_HEIGHT=30 -- --compact --no-color
		need "longplain ${wd}x30: TIME 0:00, FLEX to 8 sufficed" eval 'rows queue | grep -qE "^ *123456789 +plain +alice PENDING 0:00 50:00 "'
	done
	sq_run oddarr SQ_WIDTH=80 SQ_HEIGHT=30 -- --compact --no-color
	need "oddarr 80x30: TIME 0:00, FLEX to 8 sufficed" eval 'rows queue | grep -qE "^ *4242 +plain +alice PENDING 0:00 50:00 "'
}
# WHOLE-v3.1 FINAL's pins (whole-design.md): M1 and L-2 (the filter by its own
# token), M2 a, b (ii) and L-5 (the durations), L2 (whole list items), L3
# (ST), LC (the longest clean prefix), NK and DOT (names)
c_whole_v31() {
	T_TITLE="WHOLE-v3.1: the marker names SQUEUE_NAMES, -n, --me (no login); a duration keeps Slurm's form where it fits and never turns short at W+1 (throttled, jobmem-arrays, pending-strided, busy24/noacct 71-78); whole list items stay (lists 96/97, shrink-name); the finished code column ST; guard2's longest clean prefix; names: chr1:…, guard's job 900"
	local c wd nologin=$T_DIR/nologin
	sq_run noacct SQUEUE_NAMES=qc SQ_WIDTH=60 SQ_HEIGHT=14 -- --compact --no-color
	need "SQUEUE_NAMES=qc 60x14: (SQUEUE_NAMES: no sacct)" words_line "finished (SQUEUE_NAMES: no sacct): 4188 qc FAILED 1"
	sq_run noacct SQUEUE_NAMES=qc SQ_WIDTH=44 SQ_HEIGHT=14 -- --compact --no-color
	need "SQUEUE_NAMES=qc 44x14: (SQUEUE_NAMES)" words_line "finished (SQUEUE_NAMES): 4188 qc FAILED 1"
	sq_run noacct SQ_WIDTH=60 SQ_HEIGHT=14 -- --compact --no-color -n qc
	need "-n qc 60x14: (-n: no sacct)" words_line "finished (-n: no sacct): 4188 qc FAILED 1"
	mkdir -p "$nologin"
	printf '#!/bin/sh\n[ "$1" = -un ] && exit 1\nexec %q "$@"\n' "$here/bin/id" > "$nologin/id"; chmod +x "$nologin/id"
	for c in "40:finished (--me): 4188 qc FAILED 1" "56:finished (--me: no login): 4188 qc FAILED 1"; do
		sq_run noacct "PATH=$nologin:$here/bin:$PATH" SQ_WIDTH=${c%%:*} SQ_HEIGHT=12 -- --compact --no-color --me
		need "--me without a login, ${c%%:*}x12: ${c#*:}" words_line "${c#*:}"
	done
	# M2: never short at W+1 where long at W, and no short cell wider than its long form
	for wd in 36 37 38 41 42 47 48 64 65 66 67; do
		sq_run throttled SQ_WIDTH=$wd SQ_HEIGHT=40 -- --compact --no-color
		need "throttled ${wd}x40: LEFT 50:00 in Slurm's form" eval 'rows queue | grep -q " 50:00 " && ! rows queue | grep -q "50m00s"'
	done
	for c in "37:8000_… ×8 sweep PENDING 50:00 (Job…" "38:8000_… sweep PENDING 50:00 4G (Job…" "66:8000_[2-9%2] ×8 sweep alice PENDING 0:00 50:00 1 4G (JobArr…"; do
		sq_run throttled SQ_WIDTH=${c%%:*} SQ_HEIGHT=40 -- --compact --no-color
		need "throttled ${c%%:*}x40: ${c#*:}" words_line "${c#*:}"
	done
	for wd in 65 66; do
		sq_run jobmem-arrays SQ_WIDTH=$wd SQ_HEIGHT=40 -- --compact --no-color
		need "jobmem-arrays ${wd}x40: 1h00m 50:00 at both widths" words_has "6000_[0-2] ×3 fold fsill RUNNING 1h00m 50:00 "
	done
	for c in "65:7001_[…] ×7 sweep alice PENDING 0s 1h00m 1 4G (Resources)" "66:7001_[0-12:2] ×7 sweep alice PENDING 0s 1h00m 1 4G (Resour…"; do
		sq_run pending-strided SQ_WIDTH=${c%%:*} SQ_HEIGHT=40 -- --compact --no-color
		need "pending-strided ${c%%:*}x40: short at both widths" words_line "${c#*:}"
	done
	for wd in 71 72 73 77; do
		for c in busy24 noacct; do
			sq_run $c SQ_WIDTH=$wd SQ_HEIGHT=40 -- --compact --no-color
			need "$c ${wd}x40: 3990_[0-13] ×14 with 5h59m, 0:00 beside 1d00h (L-5)" eval 'words_has "3990_[0-13] ×14 align alice RUNNING 5h59m 6h00m 1 4G node01" && { [ $c = noacct ] || words_has "4201 assemble fsill PENDING 0:00 1d00h 1 4G"; }'
		done
	done
	sq_run busy24 SQ_WIDTH=78 SQ_HEIGHT=40 -- --compact --no-color
	need "busy24 78x40: Slurm's durations back" words_has "3990_[0-13] ×14 align alice RUNNING 5:59:00 6:00:00 1 4G node01"
	# L2, L-4: whole list items
	sq_run lists SQ_WIDTH=96 SQ_HEIGHT=30 -- --compact --no-color
	need "lists W=96: sweep_[1,4,7,… and n01,n02,n03,n04,n05" eval 'words_has "6101 sweep_[1,4,7,… alice" && words_has "6102 run_1,000,000 alice RUNNING 10:00 50:00 1 4G n01,n02,n03,n04,n05"'
	sq_run lists SQ_WIDTH=97 SQ_HEIGHT=30 -- --compact --no-color
	need "lists W=97: NAME gains 10, NODE/REASON gives n05" eval 'words_has "6101 sweep_[1,4,7,10,… alice" && words_has "1 4G n01,n02,n03,n04,…"'
	sq_run shrink-name SQ_WIDTH=80 SQ_HEIGHT=30 -- --compact --no-color
	need "shrink-name W=80: the whole items stay in both tables" eval 'words_has "1101 sweep_[1,4,7,10,13,16,19,… alice" && words_has "1001 sweep_[1,4,7,10,13,16,19,22,25,28,31,34,37,… COMPLETED"'
	# L3
	sq_run fs10 SQ_WIDTH=23 SQ_HEIGHT=30 -- --compact --no-color
	need "fs10 W=23: the finished code column ST" eval 'line_is "  JOBID    ST   EXIT   " && line_is "  987654   CA   0/sig15"'
	# LC: the longest clean prefix
	for c in "19:↳ ticket#…" "21:↳ ticket#4711-…" "26:↳ ticket#4711-2026-…"; do
		sq_run guard2 SQ_WIDTH=${c%%:*} SQ_HEIGHT=30 -- --compact --no-color
		need "guard2 W=${c%%:*}: ${c#*:}" words_line "${c#*:}"
	done
	# NK, DOT: names
	sq_run firstw SQ_WIDTH=29 SQ_HEIGHT=40 -- --compact --no-color
	need "firstw W=29: chr1:… (':' is no key in a name), x9:…, 1-… (a cut time backs up)" eval 'words_line "7005 chr1:… RUNNING node01" && words_line "7009 x9:… RUNNING node01" && words_line "7002 1-… RUNNING node01"'
	sq_run firstw SQ_WIDTH=28 SQ_HEIGHT=40 -- --compact --no-color
	need "firstw W=28: a '.' between digits is in the run (DOT): v…, 10.0…, 3.14…" eval 'words_line "7003 v… RUNNING node01" && words_line "7004 10.0… RUNNING node01" && words_line "7006 3.14… RUNNING node01"'
	for c in "27:900 run … RUNNING node…" "35:900 run -… RUNNING 50:00 node01" "46:900 run -… alice RUNNING 50:00 4G node01"; do
		sq_run guard SQ_WIDTH=${c%%:*} SQ_HEIGHT=30 -- --compact --no-color
		need "guard W=${c%%:*}: job 900 ${c#*:} ('--mem' a key in names)" words_line "${c#*:}"
	done
}
# Franz's 20 accepted screens (decision 17, screens/final/: busy24 at 8-60
# lines, elapsed24, emptyfin, mix30 at 16-45 lines at 110 columns, noacct,
# quiet40, tiny), with and without colour, byte for byte as the base drew
# them, but elapsed24-h24's one accepted line (UnavailableNodes:node0… ->
# UnavailableNodes:…, X-A); the clock aside, and a start estimate's date and
# minutes, which move with the day (AC 8, review LOW 5)
c_whole_accepted() {
	T_TITLE="the 20 accepted screens, with and without colour, byte for byte, the clock aside (elapsed24-h24 with its accepted line UnavailableNodes:…)"
	local c fx w h ext col
	for c in busy24:100:8 busy24:100:12 busy24:100:16 busy24:100:20 busy24:100:24 busy24:100:30 busy24:100:40 busy24:100:43 \
	         busy24:100:44 busy24:100:52 busy24:100:60 elapsed24:100:24 emptyfin:100:24 mix30:110:16 mix30:110:18 mix30:110:30 \
	         mix30:110:45 noacct:100:24 quiet40:100:40 tiny:100:10; do
		IFS=: read -r fx w h <<< "$c"
		for col in no-color color; do
			ext=txt; [ $col = color ] && ext=ansi
			sq_run "$fx" SQSTUB_HOST=FranzGB SQ_WIDTH=$w SQ_HEIGHT=$h -- --compact --$col
			need "$fx ${w}x$h --$col: the accepted screen" eval '
				rc_is 0 && err_empty && cmp -s <(without_clock "$fixtures/$fx/accepted-w$w-h$h.$ext" | mask_estimates) <(without_clock "$OUT" | mask_estimates)'
		done
	done
	sq_run elapsed24 SQSTUB_HOST=FranzGB SQ_WIDTH=100 SQ_HEIGHT=24 -- --compact --no-color
	need "elapsed24 100x24: its accepted line" eval 'plain | grep -qE " \(ReqNodeNotAvail, UnavailableNodes:…$"'
}
# the gawk argument limit (WHOLE AC 14): Linux takes no single argument over
# MAX_ARG_STRLEN (32 pages, 131072 bytes), and the dashboard's program alone
# comes near it; over it, sq dies with "Argument list too long" before it
# draws anything.  A gawk on PATH ahead of the real one logs every call's
# longest argument, and for a call with --source how many parts it has
c_gawk_arg_limit() {
	T_TITLE="no argument of any gawk call sq makes is over 64 KiB (half of Linux's 128 KiB MAX_ARG_STRLEN), over the dashboard FULL and COMPACT (memory columns, 17 000 own running jobs, scontrol -o, C), sq job (why, sstat, arrays, scontrol -o) and sq log; the dashboard's program reaches gawk as four --source parts, sq job's as five; each run draws its screen"
	local shim=$T_DIR/argbin real fx limit=65536; real=$(command -v gawk)
	mkdir -p "$shim"
	# each call: its --source parts, its longest argument, and what ran it
	cat > "$shim/gawk" <<-SHIM
		#!/usr/bin/env bash
		LC_ALL=C; longest=0 parts=0
		for a; do [ \${#a} -le \$longest ] || longest=\${#a}; [ "\$a" != --source ] || parts=\$((parts + 1)); done
		printf '%s %s %s\n' "\$parts" "\$longest" "\${GAWK_RUN:-?}" >> "$T_DIR/arglens"
		exec "$real" "\$@"
	SHIM
	chmod +x "$shim/gawk"
	: > "$T_DIR/arglens"
	local -a argenv=(PATH="$shim:$here/bin:$PATH")
	sq_run busy24 "${argenv[@]}" GAWK_RUN=dash SQ_HEIGHT=24 SQ_WIDTH=100 -- --compact --no-color
	need "a COMPACT run on the logging gawk draws its screen, the footer last" eval 'rc_is 0 && err_empty && plain | tail -n 1 | grep -qE "^ +151 jobs +128 running"'
	sq_run memalloc "${argenv[@]}" GAWK_RUN=dash SQSTUB_UID=1041 SQ_WIDTH=110 SQ_HEIGHT=30 -- --full --color
	need "memalloc FULL as fsill (the memory columns, sstat): rc 0, the footer last" eval 'rc_is 0 && err_empty && plain | tail -n 1 | grep -qE "^ +[0-9]+ jobs? "'
	no_utf8_locale "$T_DIR/nobin"
	sq_run mix30 GAWK_RUN=dash LC_ALL=C PATH="$T_DIR/nobin:$shim:$here/bin:$PATH" SQ_WIDTH=60 SQ_HEIGHT=30 -- --compact --no-color
	need "mix30 COMPACT under a gawk in C: rc 0, the footer last" eval 'rc_is 0 && err_empty && plain | tail -n 1 | grep -qE "^ *[0-9]+ (jobs?|R) "'
	for fx in finished-11912:11912 pending-est:11962 running-own:11950 array-11367:11367 resources-11964:11964; do
		job_run "${fx%%:*}" "${argenv[@]}" GAWK_RUN=job -- --no-color job "${fx#*:}"
		need "sq job ${fx#*:} (${fx%%:*}): rc 0, its report" eval 'rc_is 0 && plain | head -n 1 | grep -q "^▌ ${fx#*:}"'
	done
	# the caller's own running jobs reach sstat -j and the reading's gawk; 17 000
	# of them are a list of 136 KB, over Linux's 128 KiB for one argument (the
	# stub log %q-quotes the commas)
	fx=$T_DIR/fx-many; mkdir -p "$fx"
	for f in "$fixtures"/memalloc/*; do [ -f "$f" ] && sed "s|^@include \.\./|@include $fixtures/|" "$f" > "$fx/${f##*/}"; done
	gawk 'BEGIN { for (i = 1; i <= 17000; i++) printf "JobID=%d; tres_alloc=cpu=1,mem=1G,node=1,billing=1\n", 2000000 + i }' >> "$fx/squeue-alloc"
	sq_run "$fx" "${argenv[@]}" GAWK_RUN=dash SQSTUB_UID=1041 SQ_WIDTH=110 SQ_HEIGHT=30 -- --full --no-color
	need "17 000 own running jobs: rc 0, stderr empty (no 'Argument list too long'), flye read 83/100G" eval '
		rc_is 0 && err_empty && rows queue | grep -qE "^ +11895 +flye +fsill +RUNNING .* 83/100G "'
	need "... sstat asked in 3 calls, each -j list at most 65536 bytes, every id once" eval '
		[ "$(calls sstat)" = 3 ] && gawk -F"\t" "\$1 == \"CALL\" && \$2 == \"sstat\" { if (!match(\$3, /-j [^ ]+/)) bad = 1; l = substr(\$3, RSTART + 3, RLENGTH - 3); gsub(/\\\\/, \"\", l); if (length(l) > 65536) bad = 1; n += split(l, X, \",\") } END { exit bad || n != 17000 + 6 }" "$LOG"'
	fx=$(jfx_copy arglen-o resources-11964); o_path "$fx" nojson
	why_run "$fx" "${argenv[@]}" GAWK_RUN=job $O_ENV -- --no-color job 11964
	need "sq job 11964 on scontrol -o (no --json): rc 0, its report" eval 'rc_is 0 && plain | head -n 1 | grep -q "^▌ 11964"'
	sq_run memalloc "${argenv[@]}" GAWK_RUN=dash SQSTUB_NOJSON=1 SQSTUB_UID=1041 SQ_WIDTH=110 SQ_HEIGHT=30 -- --full --no-color
	need "memalloc FULL on scontrol -o (no --json): rc 0, the footer last" eval 'rc_is 0 && plain | tail -n 1 | grep -qE "^ +[0-9]+ jobs? "'
	fx=$(log_fx arglen <<'LOGFX'
StateCompact=CD
@file create wd/out_500.log line\n
LOGFX
)
	sq_run "$fx" "${argenv[@]}" GAWK_RUN=log -- log --no-follow 500
	need "sq log: rc 0, the file" eval 'rc_is 0 && out_is "line
"'
	need "the dashboard's call has four --source parts (the libraries, its functions, its rules)" eval '
		[ "$(gawk "\$3 == \"dash\" && \$1 > 0 { print \$1 }" "$T_DIR/arglens" | sort -u)" = 4 ]'
	need "sq job's report call has five --source parts (the libraries, the report, its why)" eval '
		[ "$(gawk "\$3 == \"job\" && \$1 > 0 { print \$1 }" "$T_DIR/arglens" | sort -u)" = 5 ]'
	need "no argument of any of the $(grep -c . "$T_DIR/arglens") gawk calls over $limit bytes (longest: $(sort -k2 -n "$T_DIR/arglens" | tail -n 1 | cut -d" " -f2,3))" eval '
		[ -s "$T_DIR/arglens" ] && gawk -v limit=$limit "\$2 > limit { bad = 1 } END { exit bad }" "$T_DIR/arglens"'
}

# ============================================================================
cases=(
	empty mixed array_fold fold_split drain_reason hostile_names trailing_junk
	squeue_fails squeue_hangs squeue_ignores_term collector_killed tool_missing timeout_leading_zero squeue_garbage queue_cut both_fail
	finished user_filter backslash_text control_text scrub_sites scrub_not_utf8 scrub_bounded scrub_counts scrub_read_bound scrub_sigpipe scrub_stream tables_not_utf8 tables_pass_cost tables_c1 width_table wide_clip wide_twin_text wide_twin_seps wide_twin_ascii wide_compact_fin wide_compact_fin_c fin_caption_fills wide_fin_cut wide_twin_parts wide_c_floor wide_c_mode locale_big5 wide_tmux bidi_sites silent_failure real_reason_wins bell_text bell_not_utf8 bell_statedir bell_notty bell_state_odd centre sacct_fallback sacct_flags
	refuse_t_empty refuse_states_eq state_filter_queue_only accept_S_empty refuse_s refuse_json refuse_O
	colour layout_size
	pending_range pending_commas pending_throttle pending_no_id_column
	pending_strided pending_long
	malformed_step0 malformed_dots malformed_reversed malformed_multi malformed_dash malformed_huge
	finished_throttled finished_malformed fallback_throttled fallback_malformed
	more_sacct more_fallback more_repeated bitstr
	shrink_pending shrink_fold shrink_finished shrink_floor
	shrink_locale locale_pinned locale_eucjp_notool locale_missing locale_missing_screens locale_not_utf8 month_english posixly_correct clock_step ago_days cancel_names shrink_name shrink_extent
	pty_xterm pty_unknown_term pty_stdin_null pty_columns_wins pty_env_both pty_unsized no_tty
	compact_tiny_h10 compact_busy24_h8 compact_busy24_h12 compact_busy24_h16
	compact_busy24_h20 compact_busy24_h24 compact_busy24_h30 compact_busy24_h40
	compact_busy24_h43 compact_busy24_h44 compact_busy24_h52 compact_busy24_h60
	compact_elapsed24_h24 compact_emptyfin_h24 compact_noacct_h24 compact_filter_line compact_quiet40_h40
	compact_mix30_h16 compact_mix30_h18 compact_mix30_h30 compact_mix30_h45
	compact_manystuck_h16 compact_manystuck_h24 compact_manystuck_h40
	compact_manysmall_h40 compact_unlisted_h24 compact_throttled compact_quiet40_h10
	compact_sweep_busy24 compact_sweep_mix30 compact_sweep_manystuck compact_sweep_manysmall
	compact_sweep_quiet40 compact_sweep_faults
	recent_max_full full_recent_fits compact_recent_max compact_no_folding compact_colour compact_oldfail compact_fold_elapsed compact_low_heights full_flag compact_full_both
	reserve_refused compact_reserve reservation_forwarded
	sq_compact_env sq_compact_bad sq_compact_zero_pty auto_compact auto_full compact_prompt_row display_docs
	compact_no_size compact_error_screens
	bars_idle bars_busy bars_waste bars_over bars_overfull bars_down bars_round bars_edges
	bars_width_sweep
	digest_fit node_figures digest_n10 id_cells id_pins id_cells_wide_c
	membar_screens membar_detect membar_call membar_fail membar_partial membar_over membar_down membar_forged membar_json membar_fallback nodes_not_utf8 nodes_ctl_o
	exit_labels exit_compact exit_garbage exit_fallback
	nodes_dup_apart nodes_dup_adjacent nodes_dup_digest nodes_dup_drained node_one_dup nodes_dup_compact nodes_dup_cntrl nodes_dup_unreadable nodes_dup_differ
	jobmem_screens jobmem_gates jobmem_throttle jobmem_outcomes jobmem_forms jobmem_compact_arrays
	jobmem_lists memalloc_screens memalloc_call memalloc_fail memalloc_fold memalloc_narrow memalloc_floor_M
	sub_dispatch sub_stray log_follow log_now log_not_regular log_syntax log_paths log_not_utf8 log_stream
	job_screens job_contract job_select job_branches job_own job_notes job_pss job_sources
	why_screens why_clock_step why_calls why_tail why_tail_file why_not_utf8 why_ctl_o job_passes why_tail_hung why_forged why_nodes_json why_nodes_figures why_pending why_dep
	why_resources wide_job wide_job_ahead why_ended why_array why_budget why_parallel why_signals
	opts_env_values opts_env_flags opts_flag_beats_env opts_env_refused opts_env_inert opts_sort opts_rd7_flags
	opts_clusters opts_short_words opts_equals opts_empty_blank opts_canonical opts_dash_values opts_kept_pins
	opts_jobid opts_repeat opts_check_order opts_sub_placement opts_o_attached opts_fallback_source opts_mem opts_docs
	nodes_o_calls nodes_o_figures nodes_o_forged nodes_o_pairs nodes_o_fail nodes_o_bounds stub_nodes stub_fast nodes_o_cost nodes_nopart nodes_caption
	whole_widths whole_narrow whole_monotone whole_full whole_c_mode whole_height whole_pins whole_captions whole_docs whole_accepted
	whole_forms whole_orders whole_guard whole_v31
	gawk_arg_limit plural_one invalid_colour suite_interrupt
)
# The cases that measure time or load: a bound on how long sq or a call
# takes, CPU seconds, a poll that must see sq do something within seconds,
# signals sent while calls are in flight, a snapshot's age by the clock, or
# SQ_TIMEOUT=1 on calls that must answer.  -j runs them one after the other
# once the others are done, so no other case loads the host meanwhile.
timed_cases=" squeue_hangs squeue_ignores_term scrub_bounded tables_pass_cost cancel_names
	membar_json membar_fallback jobmem_outcomes jobmem_throttle job_own
	log_follow log_now log_not_regular log_not_utf8 log_stream job_contract
	why_nodes_json why_tail_hung why_budget why_parallel why_signals job_screens
	nodes_o_fail nodes_o_bounds stub_fast nodes_o_cost compact_prompt_row jobmem_lists "
timed_cases=" $(printf '%s ' $timed_cases)"       # one space around each name
for c in $timed_cases; do
	[[ " ${cases[*]} " == *" $c "* ]] || { echo "run.sh: timed_cases names $c, which is no case" >&2; exit 2; }
done
selected=()
for c in "${cases[@]}"; do
	if [ ${#only[@]} -gt 0 ]; then
		hit=0; for o in "${only[@]}"; do [ "$c" = "$o" ] && hit=1; done
		[ $hit = 1 ] || continue
	fi
	selected+=("$c")
done
# run_case NAME: the case, its line printed, its status in T_STATUS
run_case() {
	local sid
	T_NAME=$1 T_TITLE= T_XFAIL= T_CALLS=0 T_FAIL=() T_WANT=() T_TODAY=() run_n=0 T_SIDS=
	T_DIR=$work/$1; mkdir -p "$T_DIR"
	"c_$1"
	# whatever a background sq of this case left running is a FAIL, and goes
	for sid in $T_SIDS; do
		[ -z "$(leftovers "$sid")" ] || { T_FAIL+=("left running: $(leftovers "$sid" | paste -sd';')"); session_kill "$sid"; }
	done
	verdict
}
# -j: each case's line, stderr and status go to $results/NAME.{out,err,status}
# (status last, so it says the case is done), and show_done prints the cases
# in their order as far as they are done
results=$work/.results shown=0
run_case_into() {   # run_case_into NAME: run_case, its output into $results
	run_case "$1" > "$results/$1.out" 2> "$results/$1.err"
	printf '%s\n' "$T_STATUS" > "$results/$1.status"
}
show_done() {
	local c
	while [ "$shown" -lt ${#selected[@]} ]; do
		c=${selected[$shown]}
		[ -e "$results/$c.status" ] || break
		cat "$results/$c.out"; cat "$results/$c.err" >&2
		T_NAME=$c T_DIR=$work/$c T_STATUS=$(cat "$results/$c.status"); tally
		shown=$((shown + 1))
	done
}
start=$(date +%s%N)
if [ "$jobs" = 1 ]; then
	for c in "${selected[@]}"; do run_case "$c"; tally; done
else
	mkdir -p "$results"; running=0
	for c in "${selected[@]}"; do
		[[ $timed_cases == *" $c "* ]] && continue
		while [ "$running" -ge "$jobs" ]; do wait -n; running=$((running - 1)); show_done; done
		# a process group of its own (set -m only while it forks, and off in
		# it again): suite_exit kills the case whole, and SIGINT is not
		# ignored in it as it would be in a background job without job control
		set -m; ( set +m; run_case_into "$c" ) & set +m
		case_pgids="$case_pgids $!" running=$((running + 1))
	done
	while [ "$running" -gt 0 ]; do wait -n; running=$((running - 1)); show_done; done
	case_pgids=
	for c in "${selected[@]}"; do   # a case whose shell died left no status: a FAIL
		[[ $timed_cases == *" $c "* ]] || [ -e "$results/$c.status" ] && continue
		printf '%-5s  %-24s %s\n' FAIL "$c" "its shell ended without a verdict" >> "$results/$c.out"
		echo FAIL > "$results/$c.status"
	done
	show_done
	for c in "${selected[@]}"; do
		[[ $timed_cases == *" $c "* ]] || continue
		run_case_into "$c"; show_done
	done
fi
ms=$(( ($(date +%s%N) - start) / 1000000 ))
printf '\n%d passed, %d failed, %d xfail, %d xpass  (%d.%03ds)\n' \
	$n_pass $n_fail $n_xfail $n_xpass $((ms / 1000)) $((ms % 1000))
[ -z "$failrun" ] || printf 'evidence of the failed cases in %s\n' "$failrun"
[ $n_fail -eq 0 ] && [ $n_xpass -eq 0 ]
