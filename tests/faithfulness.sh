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
# with output formats, and their output comes back over the ssh pipe.

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
# every field is followed by N, and a record by a newline.
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
		line = line (j > 1 ? "; " : "") nm[j] "=" enc(v)
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
run_real() {  # run_real DIR words...: the real command's output in DIR/real.out
	local d=$1; shift; mkdir -p "$d/fx"
	real "$@" > "$d/real.out" 2> "$d/real.err" && return 0
	printf 'ERROR  %-16s real command failed: %s\n' "${d##*/}" "$(head -1 "$d/real.err")"
	fails=$((fails+1)); return 1
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

# ---- the four call shapes of sq (sq ~388, ~391, ~457, ~474) ------------------
# separators shaped as sq mints them, SLURM_TIME_FORMAT pinned as sq pins it
nfields="CPUsState NodeList FreeMem Memory StateLong Reason TimeStamp CPUsLoad AllocMem"
nfmt=; nfmt_nosize=                   # sq's form, size 0; and the same without the 0,
for f in $nfields; do                 # which the stub takes as the same form
	nfmt="$nfmt${nfmt:+,}$f:0$N3"; nfmt_nosize="$nfmt_nosize${nfmt_nosize:+,}$f:$N3"
done
compare sinfo long "${nfields// /,}" "$N3" sinfo \
	SLURM_TIME_FORMAT=standard sinfo -hN -O "$nfmt"
compare sinfo-nosize long "${nfields// /,}" "$N3" sinfo \
	SLURM_TIME_FORMAT=standard sinfo -hN -O "$nfmt_nosize"
compare squeue pct i,j,u,T,M,L,C,m,R,t,l,S "$N" squeue \
	SLURM_TIME_FORMAT=standard \
	SQUEUE_FORMAT="%i$N%j$N%u$N%T$N%M$N%L$N%C$N%m$N%R$N%t$N%l$N%S$N" squeue -h -S t,i
sfields=JobID,User,State,ExitCode,Elapsed,End,NodeList,JobName
compare sacct sacct "$sfields" "$N2" sacct \
	SLURM_TIME_FORMAT=standard sacct -p --delimiter="$N2" -n -S "$since" -E now -a -o "$sfields"
compare squeue-all long JobID,StateCompact,State,exit_code,TimeUsed,EndTime,ArrayJobID,ArrayTaskID,UserName,Name "$N" squeue-all \
	SLURM_TIME_FORMAT=standard \
	SQUEUE_FORMAT2="JobID:$N,StateCompact:$N,State:$N,exit_code:$N,TimeUsed:$N,EndTime:$N,ArrayJobID:$N,ArrayTaskID:$N,UserName:$N,Name:$N" \
	squeue -t all -h

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

# ---- squeue's -o/-O framing, seen through the header ---------------------------
# With an empty queue no record can be compared, but squeue prints its header
# through the same width logic as a row: an unsized field followed by literal
# text (-o) or a letter-led :suffix (-O) must come out unpadded, while an
# unsuffixed -O field is padded (the stub refuses that form).
hdr() {   # hdr LABEL EXPECT words...: the first line of real output vs EXPECT (a regex)
	local label=$1 want=$2; shift 2
	local got; got=$(real "$@" 2>&1 | head -1)
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
