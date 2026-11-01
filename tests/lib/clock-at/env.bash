# run.sh --at WHEN: the whole suite, sq byte for byte, as if the wall clock read
# WHEN when it starts, so a case can be tried across a midnight, a month's end or
# a year's end.  No hook in sq: what moves is what sq reads the clock through,
# all CLOCK_AT_SHIFT seconds on: date and gawk's systime() (lib/clock-at/date,
# gawk, first on PATH), the stubs' \{now} (render.awk), and printf's %(...)T of
# bash, here, which bash reads as BASH_ENV before any script.  What does not move:
# file dates sq does not set itself, so a case relying on a fresh file's mtime
# against a shifted date would read it as old; EPOCHREALTIME, read for a budget
# only where /proc/uptime is missing; the file's dates of bash's and coreutils' own
printf() {
	case $* in
		*%\(*\)T*) ;;
		*) builtin printf "$@"; return ;;
	esac
	local clock_at_args=() clock_at_a
	for clock_at_a; do
		[ "$clock_at_a" != -1 ] || clock_at_a=$((EPOCHSECONDS + ${CLOCK_AT_SHIFT:-0}))
		clock_at_args+=("$clock_at_a")
	done
	builtin printf "${clock_at_args[@]}"
}
