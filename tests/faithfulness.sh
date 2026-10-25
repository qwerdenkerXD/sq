#!/usr/bin/env bash
# Compares the stubs in tests/bin against the real Slurm clients, read-only.
#
#   tests/faithfulness.sh [ssh-target] [--keep]
#
# For each call shape sq uses, run the REAL command (over ssh, or locally when
# no target is given), turn its output into a fixture, render that fixture with
# the stub given the SAME argv and environment, and compare the bytes.  A match
# means the stub reproduces field order, separators, the trailing separator,
# empty fields, line ends and raw bytes inside values exactly.  It cannot say
# anything about a shape the cluster has no record of right now (an empty queue
# compares as zero bytes against zero bytes, and is reported as such).
#
# Nothing is written on the target: the commands are squeue, sinfo and sacct
# with output formats, scontrol show node, getent passwd and id -u, and their
# output comes back over the ssh pipe.

set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
target=; keep=0
for a in "$@"; do
	case $a in
		--keep) keep=1 ;;
		-*) printf 'usage: %s [ssh-target] [--keep]\n' "$0" >&2; exit 2 ;;
		*) target=$a ;;
	esac
done
since=${SINCE:-now-7days}             # a window with history in it

work=$(mktemp -d) || exit 1
[ $keep = 1 ] && printf 'evidence kept in %s\n' "$work" || trap 'rm -rf "$work"' EXIT

nonce() { printf 'N%s' "$(LC_ALL=C od -An -tx1 -N12 /dev/urandom | LC_ALL=C tr -d ' \n')"; }
N=$(nonce); N2=$(nonce); N3=$(nonce)

real() {    # real <words...>: VAR=value ... tool args, on the target
	if [ -n "$target" ]; then
		timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "env $(printf '%q ' "$@")"
	else
		env "$@"
	fi
}

# fixture_of MODE NAMES N < real output: one fixture record per real record.
# MODE pct|long|sacct says how a field is named; NAMES are the fields in order;
# every field is followed by N, and a record by a newline.  A name the format
# asks for twice (sq's hidden leading %i) is set once, from its first field,
# as the stub prints one value wherever the format names it: a second field
# that differs then differs in the comparison.
fixture_of() {
	LC_ALL=C gawk -v names="$2" -v N="$3" '
	function enc(s,   o, i, c, n) {
		o = ""; n = length(s)
		for (i = 1; i <= n; i++) {
			c = substr(s, i, 1)
			if      (c == "\\") o = o "\\\\"
			else if (c == ";")  o = o "\\;"
			else if (c == "\n") o = o "\\n"
			else if (c == "\t") o = o "\\t"
			else if (c == "\r") o = o "\\r"
			else if (c == "\033") o = o "\\e"
			else if (c == " " && (i == 1 || i == n)) o = o "\\s"
			else if (c ~ /[[:cntrl:]]/) o = o sprintf("\\x%02x", ord[c])
			else o = o c
		}
		return o
	}
	BEGIN { RS = N; nf = split(names, nm, ","); for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
	{
		j = (NR - 1) % nf + 1
		v = $0
		if (j == 1 && NR > 1) {
			if (substr(v, 1, 1) != "\n") { bad = "record " int(NR/nf)+1 " does not start on a new line"; exit }
			v = substr(v, 2)
		}
		if (j == 1) delete seen
		if (!(nm[j] in seen)) { seen[nm[j]]; line = line (line != "" ? "; " : "") nm[j] "=" enc(v) }
		if (j == nf) { print line; line = "" }
	}
	END {
		if (bad != "") { print "fixture_of: " bad > "/dev/stderr"; exit 1 }
		# after the last separator only the final newline may remain, and it
		# arrives as one more record of RS-split input
		if (NR && (NR - 1) % nf != 0) { print "fixture_of: " NR " fields is not records of " nf " plus a final newline" > "/dev/stderr"; exit 1 }
		if (NR && $0 != "\n") { print "fixture_of: output does not end in separator + newline" > "/dev/stderr"; exit 1 }
	}'
}

fails=0
verdict() {   # verdict LABEL DIR RECORDS: real.out vs stub.out in DIR
	local label=$1 d=$2 recs=$3
	if [ "$(cat "$d/stub.rc")" -ne 0 ]; then
		printf 'ERROR  %-16s stub failed (rc %s): %s\n' "$label" "$(cat "$d/stub.rc")" "$(head -1 "$d/stub.err")"
		fails=$((fails+1))
	elif cmp -s "$d/real.out" "$d/stub.out"; then
		printf 'MATCH  %-16s %d records, %d bytes identical%s\n' "$label" "$recs" \
			"$(wc -c < "$d/real.out")" "$([ "$recs" = 0 ] && echo ' (EMPTY: shape of a record not compared)')"
	else
		printf 'DIFFER %-16s %d records; first difference: %s\n' "$label" "$recs" \
			"$(cmp "$d/real.out" "$d/stub.out" 2>&1 | head -1)"
		fails=$((fails+1))
	fi
}
# Anything the real command writes on stderr fails the comparison, even at rc 0:
# sinfo -O and squeue -O report an unknown field name there and go on with rc 0,
# printing an empty field in its place, which a fixture would faithfully copy
real_err() {  # real_err LABEL FILE: 0 if FILE is empty, else print it as an ERROR
	[ -s "$2" ] || return 0
	printf 'ERROR  %-16s real command wrote to stderr:\n' "$1"
	sed 's/^/         | /' "$2"
	fails=$((fails+1)); return 1
}
run_real() {  # run_real DIR words...: the real command's output in DIR/real.out
	local d=$1; shift; mkdir -p "$d/fx"
	if ! real "$@" > "$d/real.out" 2> "$d/real.err"; then
		printf 'ERROR  %-16s real command failed: %s\n' "${d##*/}" "$(head -1 "$d/real.err")"
		fails=$((fails+1)); return 1
	fi
	real_err "${d##*/}" "$d/real.err"
}
run_stub() {  # run_stub DIR FIXTURE-DIR words...: the stub, same argv and env
	local d=$1 fx=$2; shift 2; : > "$d/log"
	env PATH="$here/bin:$PATH" SQSTUB_FIXTURE="$fx" SQSTUB_LOG="$d/log" "$@" \
		> "$d/stub.out" 2> "$d/stub.err"
	echo $? > "$d/stub.rc"
}
compare() {   # compare LABEL MODE NAMES SEP FILE words...
	local label=$1 mode=$2 names=$3 sep=$4 file=$5; shift 5
	local d=$work/$label
	run_real "$d" "$@" || return
	if ! fixture_of "$mode" "$names" "$sep" < "$d/real.out" > "$d/fx/$file" 2> "$d/conv.err"; then
		printf 'DIFFER %-16s real output is not the expected shape: %s\n' "$label" "$(head -1 "$d/conv.err")"
		fails=$((fails+1)); return
	fi
	run_stub "$d" "$d/fx" "$@"
	verdict "$label" "$d" "$(wc -l < "$d/fx/$file")"
}

# ---- the dashboard's call shapes (sq's "collect nodes", "collect jobs",
# "collect recent" sacct and squeue) ---------------------------------------------
# separators shaped as sq mints them, SLURM_TIME_FORMAT and SLURM_BITSTR_LEN
# pinned as sq pins them where this compares them
nfields="CPUsState NodeList FreeMem Memory StateLong Reason TimeStamp CPUsLoad AllocMem"
nfmt=; nfmt_nosize=                   # sq's form, size 0; and the same without the 0,
for f in $nfields; do                 # which the stub takes as the same form
	nfmt="$nfmt${nfmt:+,}$f:0$N3"; nfmt_nosize="$nfmt_nosize${nfmt_nosize:+,}$f:$N3"
done
compare sinfo long "${nfields// /,}" "$N3" sinfo \
	SLURM_TIME_FORMAT=standard sinfo -hN -O "$nfmt"
compare sinfo-nosize long "${nfields// /,}" "$N3" sinfo \
	SLURM_TIME_FORMAT=standard sinfo -hN -O "$nfmt_nosize"
# the queue as sq asks for its default columns i,j,u,T,M,L,C,m,R: the job id
# first and hidden, the columns, then hidden %t %l %S and, with MEM shown and
# no cluster selection (JOBMEM), %A %U last
compare squeue pct i,i,j,u,T,M,L,C,m,R,t,l,S,A,U "$N" squeue \
	SLURM_TIME_FORMAT=standard SLURM_BITSTR_LEN=0 \
	SQUEUE_FORMAT="%i$N%i$N%j$N%u$N%T$N%M$N%L$N%C$N%m$N%R$N%t$N%l$N%S$N%A$N%U$N" squeue -h -S t,i
sfields=JobID,User,State,ExitCode,Elapsed,End,NodeList,JobName
compare sacct sacct "$sfields" "$N2" sacct \
	SLURM_TIME_FORMAT=standard sacct -p --delimiter="$N2" -n -S "$since" -E now -a -o "$sfields"
compare squeue-all long JobID,StateCompact,State,exit_code,TimeUsed,EndTime,ArrayJobID,ArrayTaskID,UserName,Name "$N" squeue-all \
	SLURM_TIME_FORMAT=standard \
	SQUEUE_FORMAT2="JobID:$N,StateCompact:$N,State:$N,exit_code:$N,TimeUsed:$N,EndTime:$N,ArrayJobID:$N,ArrayTaskID:$N,UserName:$N,Name:$N" \
	squeue -t all -h

# ---- sq log's one squeue call: 17 fields of one job (sq's log_ask) -------------
# The fields as sq lists them (log_fields, read out of sq), each framed by the
# nonce, the times as epochs; the job is the first that squeue -t all printed
# above, so it is one squeue still knows
eval "$(sed -n '/^log_fields="/,/"$/p' "$here/../sq")"
lfmt= lnames=
for f in $log_fields; do lfmt="$lfmt${lfmt:+,}$f:$N" lnames="$lnames${lnames:+,}$f"; done
lid=$(LC_ALL=C sed -n 's/^JobID=\([0-9][0-9]*\(_[0-9][0-9]*\)\{0,1\}\);.*/\1/p' "$work/squeue-all/fx/squeue-all" 2>/dev/null | head -n 1)
if [ -z "$lid" ]; then
	echo "SKIP   squeue-log       squeue -t all printed no job: sq log's call not compared"
else
	compare squeue-log long "$lnames" "$N" squeue-all \
		SLURM_TIME_FORMAT=%s SLURM_BITSTR_LEN=0 SQUEUE_FORMAT2="$lfmt" squeue -h --jobs="$lid" -t all
	printf '       (job compared: %s)\n' "$lid"
fi

# ---- the login names of uids: one getent passwd call (sq's uid_names) ---------
# The caller's uid, every canceller's of the finished window (sacct's
# "CANCELLED by UID"), and one no system has: getent prints the known ones in
# the order asked and exits 2 for the missing one, and the stub must do the
# same from the known ones' lines as its passwd file, rc included
uids=$(echo $(real id -u 2>/dev/null) $(LC_ALL=C grep -ao 'CANCELLED by [0-9]*' "$work/sacct/real.out" 2>/dev/null | LC_ALL=C sed 's/.* //' | sort -un | head -10 | paste -sd' ') 2147483646)
d=$work/getent; mkdir -p "$d/fx"
real getent passwd $uids > "$d/real.out" 2> "$d/real.err"; echo $? > "$d/real.rc"
if real_err getent "$d/real.err"; then
	cp "$d/real.out" "$d/fx/passwd"
	run_stub "$d" "$d/fx" getent passwd $uids
	if [ "$(cat "$d/real.rc")" != "$(cat "$d/stub.rc")" ]; then
		printf 'DIFFER %-16s rc %s, the stub %s: %s\n' getent "$(cat "$d/real.rc")" "$(cat "$d/stub.rc")" "$(head -1 "$d/stub.err")"
		fails=$((fails+1))
	elif cmp -s "$d/real.out" "$d/stub.out"; then
		printf 'MATCH  %-16s uids %s: %d lines, rc %s, bytes identical\n' getent "$uids" "$(wc -l < "$d/real.out")" "$(cat "$d/real.rc")"
	else
		printf 'DIFFER %-16s uids %s; first difference: %s\n' getent "$uids" "$(cmp "$d/real.out" "$d/stub.out" 2>&1 | head -1)"
		fails=$((fails+1))
	fi
fi

# ---- sacct's array-id truncation (SLURM_BITSTR_LEN) ---------------------------
# The fixture is the WHOLE truth, taken with SLURM_BITSTR_LEN=0; the stub must
# degrade it exactly as sacct does at every other length, and when it is unset.
ids=$(LC_ALL=C grep -ao '^[0-9][0-9]*_\[' "$work/sacct/real.out" 2>/dev/null \
	| LC_ALL=C tr -d '_[' | sort -u | head -20 | paste -sd, -)
if [ -z "$ids" ]; then
	echo "SKIP   sacct-bitstr     no bracketed array id in the window ($since): truncation not compared"
else
	t=$work/bitstr-truth
	if run_real "$t" SLURM_BITSTR_LEN=0 sacct -p --delimiter="$N2" -n -S "$since" -E now -a -j "$ids" -o "$sfields" &&
	   fixture_of sacct "$sfields" "$N2" < "$t/real.out" > "$t/fx/sacct"; then
		for len in unset 0 1 2 3 4 5 6 8 64; do
			d=$work/bitstr-$len; env=(); [ $len = unset ] || env=(SLURM_BITSTR_LEN=$len)
			run_real "$d" "${env[@]+"${env[@]}"}" sacct -p --delimiter="$N2" -n -S "$since" -E now -a -j "$ids" -o "$sfields" || continue
			run_stub "$d" "$t/fx" "${env[@]+"${env[@]}"}" sacct -p --delimiter="$N2" -n -S "$since" -E now -a -j "$ids" -o "$sfields"
			verdict "sacct-bitstr=$len" "$d" "$(wc -l < "$t/fx/sacct")"
		done
		printf '       (array ids compared: %s)\n' "$ids"
	fi
fi

# ---- scontrol show node: --json through the stub, and both readers of sq -------
# The --json answer, as the fixture scontrol-node.json, must come back from the
# stub byte for byte.  And sq's own readers, cut out of sq (between its "the
# node readers" and "node readers end" lines, after its character classes,
# which they use), must agree as sq uses them where Slurm has no JSON (NODES):
# - G, the names of sq job's figure call (sinfo --local -h -N -O with its six
#   fields, framed as sq frames them), as node_names lists them;
# - node_read on `scontrol -o show node G`, asked before and after --json (the
#   figures move between two calls, so either may match), with node_json_read
#   on --json: name, CPUs, real_memory, specialized_memory, and whether the
#   node is unknown;
# - G's -o answer has no "Node N not found" line (sinfo and scontrol see the
#   same nodes);
# - sinfo's figures with --json per node (CPUsState's first figure alloc_cpus
#   and its fourth -o's CPUTot, as node_json_read keeps the effective CPUs,
#   Memory real_memory, AllocMem alloc_memory,
#   StateComplete in upper case the state, compared as its base word and the
#   set of its flags, as JSON lists the flags in another order), and the rows
#   of one node byte for byte alike outside PartitionName.
# Each answer reaches them as it reaches sq's: through sq's scrub -s, cut out
# of sq too (between "the scrub" and "scrub end").  Run it once as an operator
# and once as a user who is none (V3: the premise that sinfo and scontrol show
# one user the same nodes); the line names the user it ran as.
eval "$(sed -n '/^# ---- the scrub/,/^# ---- scrub end/p' "$here/../sq")"
sed -n -e '/^# ---- the character classes/,/^# ---- character classes end/p' \
	-e '/^# ---- the node readers/,/^# ---- node readers end/p' "$here/../sq" > "$work/readers.awk"
flags_awk='function flags(st,   n, a, i, j, t) {     # the base word, then the flags sorted
	n = split(st, a, "+")
	for (i = 2; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
	t = a[1]; for (i = 2; i <= n; i++) t = t "+" a[i]
	return t
}'
nodes_dump() {   # nodes_dump json|text FILE [GATE]: what sq's reader keeps, a node a line
	scrub -s < "$2" > "$2.scrubbed"
	LC_ALL=C.UTF-8 gawk -v how="$1" -v f="$2.scrubbed" -v g="${3:-}" -f "$work/readers.awk" -e '
	END {
		if (how == "json" && !node_json_read(f)) { print "not accepted"; exit }
		if (how == "text") node_read(f, g)
		for (n = 1; n <= NN; n++) printf "%s|%s|%s|%s|%s\n", NODE_NAME[n], NODE_CPUS[n], NODE_REALMEM[n], NODE_SPECMEM[n], (n in NODE_BAD) ? NODE_BAD[n] : "ok"
	}' /dev/null
}
d=$work/scontrol; mkdir -p "$d/fx"
sfmt=; for f in CPUsState NodeList PartitionName Memory AllocMem StateComplete; do sfmt="$sfmt${sfmt:+,}$f:0$N3"; done
who=$(real id -un 2>/dev/null)
if run_real "$d/fig" sinfo --local -h -N -O "$sfmt" &&
   G=$(LC_ALL=C SQ_F="$d/fig/real.out" SQ_N="$N3" gawk -f "$work/readers.awk" -e 'END { n = node_names(ENVIRON["SQ_F"], ENVIRON["SQ_N"], 6, 1); if (n < 1) exit 1; print NODE_LIST }' /dev/null) &&
   run_real "$d/o1" scontrol -o show node "$G" && run_real "$d" scontrol --json show node && run_real "$d/o2" scontrol -o show node "$G"; then
	cp "$d/real.out" "$d/fx/scontrol-node.json"
	run_stub "$d" "$d/fx" scontrol --json show node
	verdict scontrol-json "$d" "$(LC_ALL=C grep -c '^NodeName=' "$d/o1/real.out")"
	printf '%s\n' "${G//,/$'\n'}" > "$d/gate"; scrub -s < "$d/gate" > "$d/gate.scrubbed"
	nodes_dump json "$d/real.out" > "$d/json.dump"
	nodes_dump text "$d/o1/real.out" "$d/gate.scrubbed" > "$d/o1.dump"; nodes_dump text "$d/o2/real.out" "$d/gate.scrubbed" > "$d/o2.dump"
	# --json lists every node, -o G only sinfo's: compare the nodes of G
	LC_ALL=C gawk -F'|' 'NR == FNR { g[$0]; next } $1 in g' "$d/gate.scrubbed" "$d/json.dump" > "$d/json.g.dump"
	if [ ! -s "$d/json.dump" ] || [ "$(cat "$d/json.dump")" = "not accepted" ]; then
		printf 'DIFFER %-16s node_json_read: %s\n' scontrol-readers "$(head -1 "$d/json.dump")"; fails=$((fails+1))
	elif cmp -s "$d/json.g.dump" "$d/o1.dump" || cmp -s "$d/json.g.dump" "$d/o2.dump"; then
		printf 'MATCH  %-16s node_json_read == node_read on -o G: %d nodes (as %s)\n' scontrol-readers "$(wc -l < "$d/o1.dump")" "$who"
	else
		printf 'DIFFER %-16s node_json_read != node_read on either -o G (as %s):\n' scontrol-readers "$who"
		diff "$d/o1.dump" "$d/json.g.dump" | sed 's/^/         | /'; fails=$((fails+1))
	fi
	if LC_ALL=C grep -q '^Node .* not found$' "$d/o1/real.out" "$d/o2/real.out"; then
		printf 'DIFFER %-16s scontrol -o does not know a node sinfo lists (as %s):\n' scontrol-names "$who"
		LC_ALL=C grep -h '^Node .* not found$' "$d/o1/real.out" | sed 's/^/         | /'; fails=$((fails+1))
	else
		printf 'MATCH  %-16s scontrol -o knows every node sinfo lists: %s (as %s)\n' scontrol-names "$G" "$who"
	fi
	# sinfo's figures with --json's, per node, and one node's rows alike
	scrub -s < "$d/fig/real.out" > "$d/fig/real.scrubbed"
	scrub -s < "$d/o1/real.out" > "$d/o1/real.scrubbed"
	if J="$d/real.out.scrubbed" S="$d/fig/real.scrubbed" O="$d/o1/real.scrubbed" LC_ALL=C.UTF-8 SQ_N="$N3" gawk -f "$work/readers.awk" -e "$flags_awk" -e '
		END {
			if (!node_json_read(ENVIRON["J"])) { print "         | --json not accepted"; exit 1 }
			# CPUsState counts CPUTot, which -o prints (--json keeps effective_cpus beside cpus,
			# and node_json_read the effective ones, below CPUTot on a node with CPUSpecList)
			while ((getline ln < ENVIRON["O"]) > 0)
				if (ln ~ /^NodeName=/ && match(ln, / CPUTot=[^ ]*/)) { nm = ln; sub(/^NodeName=/, "", nm); sub(/ .*/, "", nm); gsub(CNTRL, "?", nm); TOT[nm] = substr(ln, RSTART + 8, RLENGTH - 8) }
			ns = read_rows(ENVIRON["S"], ENVIRON["SQ_N"])
			for (r = 1; r <= ns; r++) {
				nm = ROW[r, 2]; gsub(CNTRL, "?", nm)
				sig = ROW[r, 1] "|" ROW[r, 4] "|" ROW[r, 5] "|" ROW[r, 6]
				if (nm in seen) { if (seen[nm] != sig) { print "         | " nm ": rows differ outside PartitionName"; bad = 1 }; continue }
				seen[nm] = sig
				if (!(nm in NODE_AT)) { print "         | " nm ": not in --json"; bad = 1; continue }
				i = NODE_AT[nm]; split(ROW[r, 1], c, "/")
				got = c[1] "/" c[4] "/" ROW[r, 4] "/" ROW[r, 5] "/" flags(toupper(ROW[r, 6]))
				want = NODE_CPUALLOC[i] "/" ((nm in TOT) ? TOT[nm] : "no CPUTot in -o") "/" NODE_REALMEM[i] "/" NODE_ALLOCMEM[i] "/" flags(NODE_STATE[i])
				if (got != want) { print "         | " nm ": sinfo " got ", --json " want; bad = 1 }
			}
			exit bad
		}
		function read_rows(file, nonce,   saved, ln, f, n, i) {
			saved = RS; RS = nonce "\n"
			while ((getline ln < file) > 0) { split(ln, f, nonce); n++; for (i = 1; i <= 6; i++) ROW[n, i] = f[i] }
			RS = saved; return n
		}' /dev/null > "$d/fig.cmp" 2>&1; then
		printf 'MATCH  %-16s sinfo figures == --json per node, rows of a node alike (as %s)\n' sinfo-figures "$who"
	else
		printf 'DIFFER %-16s sinfo figures != --json (as %s):\n' sinfo-figures "$who"; cat "$d/fig.cmp"; fails=$((fails+1))
	fi
fi

# ---- squeue's -o/-O framing, seen through the header ---------------------------
# With an empty queue no record can be compared, but squeue prints its header
# through the same width logic as a row: an unsized field followed by literal
# text (-o) or a letter-led :suffix (-O) must come out unpadded, while an
# unsuffixed -O field is padded (the stub refuses that form).
hdr() {   # hdr LABEL EXPECT words...: the first line of real output vs EXPECT (a regex)
	local label=$1 want=$2; shift 2
	local d=$work/$label got; mkdir -p "$d"
	real "$@" > "$d/real.out" 2> "$d/real.err"
	real_err "$label" "$d/real.err" || return
	got=$(head -1 "$d/real.out")
	if [[ $got =~ $want ]]; then printf 'MATCH  %-16s header %s\n' "$label" "$got"
	else printf 'DIFFER %-16s header %s (wanted /%s/)\n' "$label" "$got" "$want"; fails=$((fails+1)); fi
}
hdr hdr-o "^JOBID${N}NAME${N}ST${N}\$" SQUEUE_FORMAT="%i$N%j$N%t$N" squeue -t all
hdr hdr-O "^JOBID${N}ARRAY_TASK_ID${N}NAME${N}\$" SQUEUE_FORMAT2="JobID:$N,ArrayTaskID:$N,Name:$N" squeue -t all
hdr hdr-O-unsized '^JOBID {15}NAME {16}$' squeue -t all -O JobID,Name
hdr hdr-precedence "^JOBID${N}\$" SQUEUE_FORMAT="%i$N" SQUEUE_FORMAT2="JobID:Qq,Name:Qq" squeue -t all
hdr hdr-sinfo "^CPUS\(A/I/O/T\)${N3}NODELIST${N3}REASON${N3}\$" sinfo -N -o "%C$N3%N$N3%E$N3"
hdr hdr-sinfo-O "^CPUS\(A/I/O/T\)${N3}NODELIST${N3}REASON${N3}CPU_LOAD${N3}ALLOCMEM${N3}\$" \
	sinfo -N -O "CPUsState:0$N3,NodeList:0$N3,Reason:0$N3,CPUsLoad:0$N3,AllocMem:0$N3"
hdr hdr-sinfo-O-unsized '^NODELIST {12}REASON {14}$' sinfo -N -O NodeList,Reason

[ $fails -eq 0 ] && echo "all comparisons match" || echo "$fails comparison(s) differ or failed"
[ $fails -eq 0 ]
