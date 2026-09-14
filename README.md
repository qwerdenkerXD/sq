# sq

An auto-fitting Slurm dashboard for the terminal. One bash script, meant to run under `watch`:

```sh
watch -tc -n 5 sq
```

```
▌ SLURM node01  11:26:56

node01   ████░░░░░░░░░░░░  28%  36/128 cpu   ███████████████░  98%  991/1007G mem  mixed
node02   ░░░░░░░░░░░░░░░░   0%   0/24  cpu   ················   -%    -/79G   mem  down*
         ↳ Not responding · since 2025-10-19

JOBID          NAME          USER   STATE    TIME     LEFT          CPU  MEM NODE/REASON
4108_[0-3] ×4  align_reads   alice  RUNNING  2:26:58  1-21:33:02      4  32G node01
4135           assemble      bob    RUNNING     2:54     0:05:06     16  64G node01
4140           call_variants alice  PENDING     0:00     4:00:00      8  16G (Resources) → 14:32

recently finished
JOBID            NAME         STATE        EXIT    ELAPSED      AGO
4120_[0-3] ×4    qc_report    COMPLETED       0    0:01-0:03    10s
4120_[4-5] ×2    qc_report    FAILED          7         0:00    13s

5 jobs   4 running   1 pending   0 other
```

*(Sample output with made-up names; the real thing is coloured.)*

## What it does

- **Fits the terminal.** Every column is sized to its content. When the table is too wide, the text
  columns (name, reason, command, node list, work dir) shrink first, longest first, cut with `…`.
  Numbers are never cut while anything else can give.
- **One right edge.** Node stats, the job table and the finished-jobs block are measured together
  and drawn to a common width, so the dashboard reads as one block rather than three.
- **CPU and memory bars per node.** Memory comes from the node's own free-memory reading, so it is
  meaningful even when Slurm is not configured to schedule memory (`CR_CORE`), which is exactly
  when you most need to watch it. Yellow past 85%, red past 95%.
- **Array jobs fold.** Tasks that agree on every displayed column collapse to one row,
  `4108_[0-3] ×4`. Finished tasks fold by array and by outcome, so failures never hide inside a
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

- Slurm client tools: `sinfo`, `squeue`
- **gawk** (GNU awk; plain awk and mawk won't do)
- coreutils `timeout`, and `tput`
- A UTF-8 terminal

## Install

```sh
sudo install -m 755 sq /usr/local/bin/sq     # for everyone
install -m 755 sq ~/.local/bin/sq            # just for you
```

## Usage

```sh
sq                        # one-shot
watch -tc -n 5 sq         # live; -c keeps the colours, -t drops watch's header
sq -o i,j,T,M,P,N         # choose columns by squeue field letter
sq -u "$USER" -p gpu      # anything sq doesn't know is passed on to squeue
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
| `SQ_WIDTH`, `SQ_HEIGHT` | Pretend the terminal has this size. |

## Good to know

- **Finished jobs only stay visible for `MinJobAge`** (`scontrol show config | grep MinJobAge`,
  often 300 s), because they are read from the controller's memory with `squeue -t all`, not from
  an accounting database. That's enough to catch a failure while you're watching, not to review
  yesterday.
- **The bell keeps a little state:** the ids of failures it has already rung for, in
  `~/.cache/sq/alerted`, rewritten on every run to hold only what is still in the window.
- An unreachable controller makes `sinfo` and `squeue` hang rather than fail, so every call is
  bounded by `SQ_TIMEOUT`. A full outage therefore delays a refresh by about twice that.

## License

MIT, see [LICENSE](LICENSE).
