# sq

An auto-fitting Slurm dashboard for the terminal. One bash script, meant to run under `watch`:

```sh
watch -tc -n 1 'sq -C'
```

```
  ▌ SLURM node01  11:26:56 UTC

  node01 ████▒░░░░░░░░░░░░░░  25%  32/128 cpu   ████░░░░░░░░░░░░░░░░  19%  192/1007G mem  mixed
  node02 ···················   0%   0/24  cpu   ····················   0%    0/79G   mem  down*
         ↳ Not responding · since 2026-10-19

  JOBID         NAME          USER  STATE   TIME    LEFT       CPU MEM      NODE/REASON        
  4140          call_variants alice PENDING    0:00    4:00:00   8      16G (Resources) → 14:32
  4108_[0-3] ×4 align_reads   bob   RUNNING 2:26:58 1-21:33:02   4     128G node01
  4135          assemble      alice RUNNING    2:54       5:06  16   41/64G node01

  recently finished · last 2h
  JOBID            NAME         STATE        EXIT    ELAPSED    AGO                            
  4120_[0-3] ×4    qc_report    COMPLETED       0      1s-3s    10s-12s
  4120_[4-5] ×2    qc_report    FAILED          7         0s        13s

  6 jobs   5 running   1 pending   0 other
```

*(Sample output with made-up names, as alice sees it; the real thing is coloured.)*


## What it does

- **Fits the screen, or shows everything.** On a terminal and under `watch`, a COMPACT screen
  fitted to the terminal, where what does not fit collapses into lines like `… 42 jobs running`
  and the jobs that need you stay longest; piped or redirected, the FULL screen, every job.
  `sq help modes`
- **Fits the terminal's width:** columns are sized to their content, text shrinks first, and
  numbers are never cut while anything else can give; COMPACT fits every width, FULL wraps its
  long lines. `sq help columns`
- **CPU and memory bars per node,** with the memory each node keeps for its OS taken off, and
  the memory in use where Slurm does not schedule memory. `sq help nodes`
- **MEM is each job's total memory,** and your own running jobs show what they use, `41/64G`.
  `sq help memory`
- **Array jobs fold** into one row per group of alike tasks, `4108_[0-3] ×4`. `sq help arrays`
- **Recently finished jobs** from accounting, with an exit that names the signal, the
  out-of-memory or the Slurm error. `sq help finished`, `sq help exit`
- **A bell for your own failures.** `sq help bell`
- **Time-limit pressure, start estimates, down-node reasons,** and a clear banner when the
  controller does not answer. `sq help columns`, `sq help slurm`
- **One job in full, and its efficiency,** for `seff` users too. `sq job -h`

## Requirements

- Slurm client tools: `sinfo` and `squeue`; `sacct` when accounting (slurmdbd) is set up, for the
  finished jobs and `sq job`'s efficiency; `sstat` for your own jobs' memory; `scontrol` for the
  memory each node keeps for its OS (`sq help slurm` says which call needs what)
- **gawk** (GNU awk; plain awk and mawk won't do)
- coreutils (`timeout`, `stty`) and `tput`
- GNU `tail` 8.28 or newer, only for [`sq log`](#sq-log) to follow a file (`--no-follow` does
  without)
- A UTF-8 terminal

## Install

```sh
sudo install -m 755 sq /usr/local/bin/sq     # for everyone
install -m 755 sq ~/.local/bin/sq            # just for you
```

## Usage

```sh
sq                        # one-shot
watch -tc -n 5 sq         # live; keep -t, or watch's own header pushes the footer off screen
sq -u "$USER" -p gpu      # squeue's filters and flags; long names in full, never abbreviated
sq job 12345              # one job, and its efficiency once it ended
sq log 12345              # a job's output file, followed while it runs
```

The help is the manual: `sq -h` lists every option of the dashboard (`sq job -h` and
`sq log -h` their own), `sq help` the topics, and `sq help TOPIC` prints one:

| Topic | |
|---|---|
| `modes` | FULL and COMPACT: how sq chooses, what fits a small screen |
| `columns` | -o's letters and their headers, what gives first when narrow |
| `memory` | MEM: each job's total memory, your own jobs' use, ? and ! |
| `arrays` | How array tasks fold, and what -x and -r change |
| `nodes` | The CPU and memory bars: █ ▒ ▓ ░ ·, their colours and lines |
| `finished` | The recently-finished block: sacct, SQ_SINCE, the fallback |
| `exit` | Reading EXIT (rc/sigN, rc/oom, rc/errN, ?), and sq's own exit status |
| `bell` | Which failures ring, and the state the bell keeps |
| `filters` | squeue's options sq passes on, those it refuses, and why |
| `display` | Colour, centring, clock times, and the text sq rewrites |
| `slurm` | What sq asks Slurm, how long it waits, an outage |
| `env` | Every variable sq reads, a line each |
| `why` | sq job's why section: what holds a job, or why it ended |
| `efficiency` | sq job's CPU and memory against the allocation, an array's summary |
| `job` | sq job's help, as sq job -h prints it |
| `log` | sq log's help, as sq log -h prints it |

## sq job

`sq job JOBID` shows one job: its state and times, the CPUs and memory it asked for and was
given, its work directory and output files, why it waits or did not complete, and once it ended
how well it used them:

```
▌ 4120  align-reads · alice
state and times
  state     COMPLETED · exit 0
  ran       8m20s on node01 (batch)
  ended     2026-10-20 17:52 (3m ago)
resources
  CPUs      2 allocated (1 requested)
  memory    15.2G allocated (7.6G requested)
files
  work dir  /home/alice/rnaseq
  stdout    /home/alice/rnaseq/logs/align-reads-4120.out
  stderr    into stdout
efficiency
  CPU ████████▒▒▒▒▒▒▒▒  49.4%  8m14s of 16m40s
  MEM █▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒   7.9%  1.2/15.2G peak (step 0)
  ↳ 1 requested CPU became 2: a program running 1 thread reaches at most 50%
```

Unlike `seff`, its CPU time counts what Slurm's sampling saw of processes it killed or never
waited for, and its peak memory adds up each task's own peak. `sq help why`,
`sq help efficiency`

## sq log

`sq log JOBID` prints a batch job's output file from its start, follows it while the job runs,
and ends shortly after the job ends, so it pipes like any stream (`sq log -h`):

```sh
sq log 12345                     # the stdout file, whole, then live, until the job ends
sq log --err 12345               # its stderr file instead
sq log -n 50 12345 | grep -i err # the last 50 lines, then live
sq log 12345_4                   # an array task (a bare array id is refused with its
                                 #  task ids, unless only its last task is left)
sq log --no-follow 12345         # what is there now, then stop
watch -n 5 'sq log --no-follow -n 20 12345'
```

## Tests

```sh
tests/run.sh              # no cluster needed
tests/run.sh -j 3         # 3 cases at once, the timed ones one by one after: 36-52 min on a 12-thread WSL host shared with other load
```

The suite puts stand-ins for `squeue`, `sinfo`, `sacct`, `sstat`, `scontrol` and `getent` first
on `PATH` and feeds sq the shapes that are hard to get from a live cluster: large arrays, hostile
job names, array ids Slurm truncates, a controller that hangs. Most cases assert properties of
the screen (counts, which rows appear, that nothing is forged), not a snapshot; the node bars,
the `sq job` reports and the help's `sq -h`, `sq help`, `sq job -h` and `sq log -h` are compared
byte for byte with the screens they were designed from (`tests/run.sh --pin` writes the reports
and the help's screens anew, for a change meant to change them). Known defects are listed
as expected failures, so a fix shows up as one. `tests/faithfulness.sh <host>` compares the
stand-ins' output with the real tools, read-only, and fails wherever a real tool complains on
stderr.

A timed case whose timing precondition never held is a SKIP: named in the summary, no failure,
evidence under `sq-skipped/`. `tests/run.sh --at WHEN` runs as if the clock read WHEN. Needs
Linux's `/proc/uptime`.

## License

MIT, see [LICENSE](LICENSE).
