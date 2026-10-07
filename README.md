# sq

An auto-fitting Slurm dashboard for the terminal. One bash script, meant to run under `watch`:

```sh
watch -tc -n 5 sq
```

```
▌ SLURM node01  11:26:56

node01   ████▒░░░░░░░░░░░  28%  36/128 cpu   ████████▓▓▓▓▓▓▓▓  98%  991/1007G mem  mixed
node02   ░░░░░░░░░░░░░░░░   0%   0/24  cpu   ················   -%    -/79G   mem  down*
         ↳ Not responding · since 2025-10-19

JOBID          NAME          USER   STATE    TIME     LEFT          CPU  MEM NODE/REASON
4108_[0-3] ×4  align_reads   alice  RUNNING  2:26:58  1-21:33:02      4  32G node01
4135           assemble      bob    RUNNING     2:54     0:05:06     16  64G node01
4140           call_variants alice  PENDING     0:00     4:00:00      8  16G (Resources) → 14:32

recently finished · last 2h
JOBID            NAME         STATE        EXIT    ELAPSED      AGO
4120_[0-3] ×4    qc_report    COMPLETED       0    0:01-0:03    10s
4120_[4-5] ×2    qc_report    FAILED          7         0:00    13s

6 jobs   5 running   1 pending   0 other
```

*(Sample output with made-up names; the real thing is coloured.)*

## What it does

- **Fits the screen, or shows everything.** On a terminal and under `watch`, sq draws a
  COMPACT screen fitted to the terminal's height: what does not fit collapses into lines like
  `… 42 jobs running`. Stuck jobs (pending for a reason other than plain waiting), jobs blocked
  by a node or partition fault and jobs held by an admin keep their rows longest, within half the
  table while running jobs are hidden; running jobs come next, the longest-running first; ordinary
  pending jobs last. The finished block shrinks to one line naming the newest failure, else the
  newest job, and on the smallest screens the nodes become one summary line. Piped or redirected,
  sq draws the FULL screen, every job. `--compact`, `--full` or `SQ_COMPACT` choose instead.
  The width has a floor: the node lines and the job table cannot shrink below about 60 columns
  (it depends on the node names and the columns shown), and on a narrower terminal those lines
  wrap, so COMPACT can then run over the screen's height.
- **Fits the terminal's width.** Every column is sized to its content. When the table is too wide, the text
  columns (name, reason, command, node list, work dir) shrink first, longest first, cut with `…`.
  Numbers are never cut while anything else can give.
- **One right edge.** Node stats, the job table and the finished-jobs block are measured together
  and drawn to a common width, so the dashboard reads as one block rather than three.
- **CPU and memory bars per node, allocated and in use.** A cell is `█` in use, `▒` allocated but
  idle, `▓` in use beyond the allocation (magenta), `░` free, and `·` where the use is not known
  (sinfo says `N/A`). The figures beside the bars count allocated cores and memory in use. Memory
  in use comes from the node's own free-memory reading, so it is shown even when Slurm is not
  configured to schedule memory (`CR_CORE`), which is exactly when you most need to watch it;
  nodes then report no memory allocated, so all of it draws as `▓`, in use beyond the allocation.
  Bars turn yellow past 85%, memory red past 95%, and a down node's filled cells are red.
  Two caveats. CPU in use is the node's 5-minute load average (`CPULoad`), refreshed only with
  slurmctld's node pings, so it trails the node by minutes, and it counts processes outside Slurm
  too. Memory in use is RealMemory − FreeMem, and FreeMem follows the kernel's `MemFree`, so page
  cache and the OS count as used: use beyond the allocation is not necessarily jobs.
- **Array jobs fold.** Tasks that agree on every displayed column collapse to one row,
  `4108_[0-3] ×4`. A pending array Slurm prints as one bracket reads `4109_[1,4,7-20%2] ×16`,
  and the counts include every task in it, not the row. When the id column is too narrow it
  shrinks inside the brackets, `4109_[1,4,…] ×16`, so the count is never the part that gets cut.
  Finished tasks fold by array and by outcome, so failures never hide inside a
  count of successes; values that differ are shown as ranges.
- **Recently finished jobs**, with state, exit code (and signal), elapsed time and age.
- **A bell for your own failures.** A newly failed, timed-out or out-of-memory job of yours rings
  the terminal bell once. Other people's jobs don't.
- **Time-limit pressure.** `LEFT` turns yellow under 10% of the job's limit and red under 2%.
- **Start estimates** for pending jobs, from the backfill scheduler.
- **Down-node reasons**, and a clear banner when the controller doesn't answer, instead of an
  empty screen that looks like an empty queue.
- **Colour where it belongs:** on in a terminal and under `watch`, off when piped or redirected,
  off with [`NO_COLOR`](https://no-color.org).

## Requirements

- Slurm client tools: `sinfo`, `squeue`, and `sacct` when accounting (slurmdbd) is set up;
  without it the finished block falls back to `squeue -t all` and says so
- **gawk** (GNU awk; plain awk and mawk won't do)
- coreutils (`timeout`, `stty`) and `tput`
- A UTF-8 terminal

## Install

```sh
sudo install -m 755 sq /usr/local/bin/sq     # for everyone
install -m 755 sq ~/.local/bin/sq            # just for you
```

## Usage

```sh
sq                        # one-shot
watch -tc -n 5 sq         # live; keep -t, or watch's own header pushes the
                          #  footer off screen (or leave it room with
                          #  --reserve 2); -c for colour
sq -o i,j,T,M,P,N         # choose columns by squeue field letter
sq -u "$USER" -p gpu      # squeue's filters are passed on, by full long name from
                          #  a fixed list (sq -h names it) - never an abbreviation,
                          #  because squeue's own getopt would read "--iter=5" as
                          #  -i and "--forma=%i" as -o.  Some full names are refused
                          #  too, where they would replace the output sq parses
sq -C                     # centred in both axes
```

| Flag | Effect |
|---|---|
| `-o LIST` | Columns as squeue field letters, e.g. `i,j,u,T,M,L,C,m,R` (the default). `%` and widths are ignored, since widths are automatic. |
| `-c` / `-C` | Centre horizontally / in both axes. With `-C`, keep `watch -t`, or watch's header pushes the bottom off screen. |
| `-x` | Show array tasks one per row instead of folding them. |
| `--no-recent` | Hide the recently-finished block. |
| `--no-bell` | Never ring the bell. |
| `--color` / `--no-color` | Force colour on or off. |
| `--compact` / `--full` | Fit the screen / show every job, whatever the output goes to. Giving both is an error. |
| `--reserve N` | COMPACT leaves N lines of the screen unused, e.g. for `watch`'s own header. If only the footer fits, only the footer is drawn. |
| `-h` | Help. |

| Variable | Effect |
|---|---|
| `SQ_FMT` | Default column list, same syntax as `-o`. |
| `SQ_CENTER` | `1` horizontal, `2` both axes. |
| `SQ_FOLD` | `0` never folds arrays. |
| `SQ_RECENT` | `0` hides finished jobs. |
| `SQ_BELL` | `0` never rings. `SQ_BELL_ALL=1` rings for everyone's failures, not only yours. |
| `SQ_ETA` | `0` hides pending start estimates. |
| `SQ_COLOR` | `0` never, `1` always. |
| `SQ_TIMEOUT` | Seconds to wait for Slurm before declaring it unreachable (default 5). |
| `SQ_SINCE` | How far back the finished block looks (`sacct -S` syntax, default `now-2hours`). |
| `SQ_RECENT_MAX` | Finished rows shown (default: the space left on screen, 3–25; a value you set is used as given in FULL, and is an upper limit in COMPACT, which never pushes the footer off screen). |
| `SQ_COMPACT` | `1` always COMPACT, `0` always FULL; anything else, or unset, decides by where the output goes. The flags beat it. |
| `SQ_BELL_HORIZON` | A failure only rings while it is this fresh (default 600 s; `0` mutes). |
| `SQ_WIDTH`, `SQ_HEIGHT` | Pretend the terminal has this size. They never choose the mode. |

## Good to know

- **How the mode is chosen:** `--compact` or `--full`, else `SQ_COMPACT`, else COMPACT when
  stdout is a terminal, or when `COLUMNS` and `LINES` are both in the environment, which is how
  `watch` runs sq (an interactive shell does not export them). Anything else, a pipe, a file,
  `ssh host sq` without `-t`, a cron job, gets FULL. `sq --compact` with no size to measure
  uses the usual fallback size, 24 lines.
- **Finished jobs come from the accounting database** (`sacct`), so a job that ended while
  nobody was watching is still shown, for as long as `SQ_SINCE` reaches back. Step rows are read
  too, because a signalled job's own row reports success and only its step carries the signal.
  Without accounting, or with a filter `sacct` has no equivalent for, the block falls back to
  `squeue -t all`, which only remembers jobs for `MinJobAge` (often 300 s), and the caption says so.
- **The bell keeps a little state:** `<jobid><tab><end time>` lines in `~/.cache/sq/alerted`,
  added to and aged out after 24 h, never pruned just because one run looked at fewer jobs, and
  replaced atomically so two running copies cannot tear it.
- An unreachable controller makes `sinfo` and `squeue` hang rather than fail, so every call is
  bounded by `SQ_TIMEOUT`. A full outage therefore delays a refresh by about twice that.
- **Refused:** `-O`/`--Format`, `-s`/`--steps`, `-i`/`--iterate`, `-l`, `-v`, `-V`, `--json` and
  `--yaml`. Each would replace or defeat the output sq parses; sq exits with code 2 and says
  why. (`-o`/`--format` are sq's own column list.)

## Tests

```sh
tests/run.sh              # ~2 min, no cluster needed
```

The suite puts stand-ins for `squeue`, `sinfo` and `sacct` first on `PATH` and feeds sq the
shapes that are hard to get from a live cluster: large arrays, hostile job names, array ids
Slurm truncates, a controller that hangs. Most cases assert properties of the screen
(counts, which rows appear, that nothing is forged), not a snapshot; the node bars are compared
byte for byte with the screens they were designed from. Known defects are listed
as expected failures, so a fix shows up as one. `tests/faithfulness.sh <host>` compares the
stand-ins' output with the real tools, read-only, and fails wherever a real tool complains on
stderr.

## License

MIT, see [LICENSE](LICENSE).
