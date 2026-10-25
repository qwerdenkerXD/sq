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

- **Fits the screen, or shows everything.** On a terminal and under `watch`, sq draws a
  COMPACT screen fitted to the terminal's height: what does not fit collapses into lines like
  `… 42 jobs running`. Stuck jobs (pending for a reason other than plain waiting), jobs blocked
  by a node or partition fault and jobs held by an admin keep their rows longest, within half the
  table while running jobs are hidden; running jobs come next, your own near their memory limit
  first (from 90 %, then from 70 %), then the longest-running; ordinary pending jobs last. The
  finished block shrinks to one line naming the newest failure, else the newest job, and on the
  smallest screens the nodes become one summary line. Piped or redirected, sq draws the FULL
  screen, every job. `--compact`, `--full` or `SQ_COMPACT` choose instead.
  The width has a floor: the node lines and the job table cannot shrink below about 60 columns
  (it depends on the node names and the columns shown), and on a narrower terminal those lines
  wrap, so COMPACT can then run over the screen's height.
- **Fits the terminal's width.** Every column is sized to its content. When the table is too wide, the text
  columns (name, reason, command, node list, work dir) shrink first, longest first, cut with `…`.
  Numbers are never cut while anything else can give.
- **One right edge.** Node stats, the job table and the finished-jobs block are measured together
  and drawn to a common width, so the dashboard reads as one block rather than three.
- **CPU and memory bars per node.** A CPU cell is `█` in use, `▒` allocated but idle, `▓` in use
  beyond the allocation (magenta), `░` free, and `·` where the use is not known (sinfo says
  `N/A`); the figure beside it counts allocated cores. Where Slurm schedules memory, the memory
  bar and figure count allocated memory the same way, `█` allocated and `░` free, against what
  jobs can be given: RealMemory less the node's MemSpecLimit, `265/977G`, which one more call,
  `scontrol --json show node` (`scontrol -o show node` on a Slurm without JSON, asked about the
  nodes sinfo lists), reads. Should that call fail, RealMemory counts and a dim line under the
  nodes says why; where scontrol gives no usable MemSpecLimit for a node (it does not list it,
  lists it twice, or its figures are unreadable), RealMemory counts for that node and the same
  line names it (`↳ memory counts RealMemory on fb2-bioinf: scontrol listed it twice`, or the
  first of several). Where Slurm does not
  schedule memory (`CR_CORE`: no node has any memory allocated, but some node has CPUs), the
  memory bar shows memory in use instead, from the node's own free-memory reading, which is
  exactly when you most need to watch it: all of it draws as `▓`, in use beyond the (absent)
  allocation. With nothing allocated anywhere, the bar is the allocated one, `0/977G`. The
  one-line node summary of a small screen adds up the allocated memory too, `335/1052G mem`. Bars
  turn yellow past 85%, memory in use red past 95%, and a down node's filled cells are red.
  Two caveats. CPU in use is the node's 5-minute load average (`CPULoad`), refreshed only with
  slurmctld's node pings, so it trails the node by minutes, and it counts processes outside Slurm
  too. Memory in use (`CR_CORE` only) is RealMemory − FreeMem, and FreeMem follows the kernel's
  `MemFree`, so page cache and the OS count as used: use beyond the allocation is not
  necessarily jobs.
- **MEM is each job's total memory,** what a running job holds and what a pending one asks for,
  not squeue's `%m`, which is per node or per CPU: a `--mem-per-cpu=8G -c 4` job reads `32G`,
  not `8G`, and a folded row the sum over its jobs. Details under [Good to know](#good-to-know).
- **Your own running jobs show the memory they use,** as in use/allocated, `41/64G`: green below
  70 %, yellow from 70 %, red from 90 %, bold red from 100 %; `?` means no reading, `!` that the
  reading failed. Read with `sstat`, at most every 30 s; what the figure leaves out is under
  [Good to know](#good-to-know).
- **Array jobs fold.** Tasks that agree on every displayed column, as squeue prints it, collapse
  to one row, `4108_[0-3] ×4`, and its MEM adds up theirs. A pending array Slurm prints as one
  bracket reads `4109_[1,4,7-20%2] ×16`, and the counts include every task in it, not the row.
  When the id column is too narrow it shrinks inside the brackets, `4109_[1,4,…] ×16`, so the
  count is never the part that gets cut.
  Finished tasks fold by array and by outcome, so failures never hide inside a
  count of successes; values that differ are shown as ranges.
- **Recently finished jobs**, with state, exit code (and signal, out of memory or Slurm error,
  see below), elapsed time and age.
- **A bell for your own failures.** A newly failed, timed-out or out-of-memory job of yours rings
  the terminal bell once. Other people's jobs don't. The bell and the colours follow STATE, not
  EXIT: a COMPLETED job whose step ran out of memory shows `0/oom` but stays green and quiet.
- **Time-limit pressure.** `LEFT` turns yellow under 10% of the job's limit and red under 2%.
- **Start estimates** for pending jobs, from the backfill scheduler.
- **Down-node reasons**, and a clear banner when the controller doesn't answer, instead of an
  empty screen that looks like an empty queue.
- **Colour where it belongs:** on in a terminal and under `watch`, off when piped or redirected,
  off with [`NO_COLOR`](https://no-color.org).
- **One job in full, and its efficiency** (CPU time and peak memory against what the job was
  given), for `seff` users too: see [`sq job`](#sq-job).

## Requirements

- Slurm client tools: `sinfo`, `squeue`, and `sacct` when accounting (slurmdbd) is set up (for
  `sq job`'s efficiency too);
  without it the finished block falls back to `squeue -t all` and says so; `sstat` for the
  memory your own running jobs use; `scontrol --json show node` for the memory each node
  reserves for its OS (`MemSpecLimit`) and for `sq job`'s per-node view. On a Slurm without
  JSON, `sq job` asks `sinfo` for the node figures and `scontrol -o show node`, for those nodes
  alone, for MemSpecLimit and the effective CPU count (CPUEfctv); the memory bars ask scontrol
  about the nodes their own `sinfo` lists
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
watch -tc -n 5 sq         # live; keep -t, or watch's own header pushes the
                          #  footer off screen (or leave it room with
                          #  --reserve 2); -c for colour
sq -o i,j,T,M,P,N         # choose columns by squeue field letter
sq -u "$USER" -p gpu      # squeue's filters and flags, read by their full long
                          #  name from a fixed list (sq -h names it) and passed on
                          #  in squeue's short spelling - never an abbreviation,
                          #  because squeue's own getopt would read "--iter=5" as
                          #  -i and "--forma=%i" as -o.  Short options are written
                          #  apart (-a -r, not -ar).  Some names are refused too,
                          #  where they would replace the output sq parses
sq -C                     # centred in both axes
sq log 12345              # a job's output file, followed while it runs (below)
sq job 12345              # one job, and its efficiency once it ended (below)
```

| Flag | Effect |
|---|---|
| `-u`, `-p`, `-A` (`-U`), `-q`, `-j`, `-M`, `-n`, `-t`, `-w`, `-L`, `-R`, `-S`, `--me` | squeue's filters, also by their long names (`--user`, `--partition`, `--account`, …, `sq -h` lists them). The value follows the letter (`-pgpu`, `--partition=gpu`) or is the next word, whatever it looks like (`-n -x` is the job name `-x`). An empty value, one of only blanks and commas, and `-p=gpu` are refused; `-j` takes job ids, `12345` or `12345_4`; a filter given twice is refused, as squeue would keep only the last: write one list. |
| `-a`, `-r`, `-P`, `--hide`, `--noconvert`, `--federation`, `--local`, `--sibling` | squeue's flags, also as `--all`, `--array`, `--priority`, `--sib`. `--noheader` is accepted and changes nothing: squeue's `-h` is `--noheader`, which sq always passes, and so `-h` is sq's help. |
| `-o LIST` | Columns as squeue field letters, e.g. `i,j,u,T,M,L,C,m,R` (the default), also `-oLIST`, `--format LIST`, `--format=LIST`. `%` and widths are ignored, since widths are automatic. |
| `-c` / `-C` | Centre horizontally / in both axes. Vertical centring happens only on a screen (a terminal, or `watch`; into a file or a pipe `-C` centres horizontally only) and shows only while the dashboard is at least two lines shorter than the screen. With `-C`, keep `watch -t`, or watch's header pushes the bottom off screen. |
| `-x` | Show array tasks one per row instead of folding them. |
| `--no-recent` | Hide the recently-finished block. |
| `--no-bell` | Never ring the bell. |
| `--color` / `--no-color` | Force colour on or off. |
| `--compact` / `--full` | Fit the screen / show every job, whatever the output goes to. Giving both is an error. |
| `--reserve N` | COMPACT leaves N lines of the screen unused, e.g. for `watch`'s own header. If only the footer fits, only the footer is drawn. |
| `-h`, `--help` | Help. |

| Variable | Effect |
|---|---|
| `SQ_FMT` | Default column list, same syntax as `-o`. |
| `SQ_CENTER` | `1` horizontal, `2` both axes. |
| `SQ_FOLD` | `0` never folds arrays. |
| `SQ_RECENT` | `0` hides finished jobs. |
| `SQ_BELL` | `0` never rings. `SQ_BELL_ALL=1` rings for everyone's failures, not only yours. |
| `SQ_ETA` | `0` hides pending start estimates. |
| `SQ_COLOR` | `0` never, `1` always. |
| `SQ_TIMEOUT` | Seconds to wait for Slurm before declaring it unreachable (default 5). `sq job` waits 30 s for accounting unless this is set to a valid number. |
| `SQ_SINCE` | How far back the finished block looks (`sacct -S` syntax, default `now-2hours`). |
| `SQ_RECENT_MAX` | Finished rows shown (default: every finished job in FULL, the space left on screen up to 25 in COMPACT; a value you set is used as given in FULL, and is an upper limit in COMPACT, which never pushes the footer off screen). |
| `SQ_COMPACT` | `1` always COMPACT, `0` always FULL; anything else, or unset, decides by where the output goes. The flags beat it. |
| `SQ_BELL_HORIZON` | A failure only rings while it is this fresh (default 600 s; `0` mutes). |
| `SQ_WIDTH`, `SQ_HEIGHT` | Pretend the terminal has this size. They never choose the mode. |
| `SQ_PSS_SINCE` | `sq job` only: when this cluster's accounting moved from RSS to PSS (`JobAcctGatherParams=UsePss`). It only dates that switch, it turns nothing on; Slurm keeps no record of which jobs were measured which way. Written as `2026-10-19 15:59 CEST`, `2026-10-19T13:59Z` or `@EPOCH`. A peak memory measured in a step that started before it gets a note. Unset by default: no such note. |

## sq log

`sq log JOBID` prints a batch job's output file from its start, follows it while the job runs,
and ends shortly (within about 10 s) after the job ends, so it pipes like any stream:

```sh
sq log 12345                     # the stdout file, whole, then live, until the job ends
sq log --err 12345               # its stderr file instead
sq log -n 50 12345 | grep -i err # the last 50 lines, then live
sq log 12345_4                   # an array task (a bare array id asks for one)
sq log --no-follow 12345         # what is there now, then stop
watch -n 5 'sq log --no-follow -n 20 12345'
```

- A pending job is waited for until it runs and its file is there. sq computes the path from
  the job's `-o`/`-e` the way Slurm's job does (`%j`, `%A_%a`, `%N`, `%x`, widths, `%%`, and a
  backslash, which turns expansion off), so a file name that is reused (no `%j` in it) may first
  show an earlier run's text. A het job's output is its leader's.
- The file's bytes are passed on as they are; notes (`sq log: …`) go to stderr, also into a
  pipe: the job is pending, the file has not appeared yet, Slurm does not answer, and how the
  job ended (`sq log: job 12345 ended: FAILED (exit code 1:0)`). The exit code is 0 whatever
  the job's own outcome, 1 when the file cannot be shown (Slurm forgets a job about 5 minutes
  after it ends, and its path with it; an interactive job; output to `/dev/null`; a file not
  readable; a path that is no regular file, such as a FIFO or a device, which `sq job` does not
  read either), 2 for a usage error, 128+N when stopped by signal N.
- A requeued job ends the stream with a note; run `sq log` again for its new run.
- It follows for as long as Slurm cannot tell it the job ended, and asks Slurm every 5 s.
  "Live" can lag: a job on another node writes through NFS, and many programs buffer their
  output into a file (`python -u` or `stdbuf -oL` help).
- It reads the file on this machine, so `-M`, `--federation`, `--sibling` and `SLURM_CLUSTERS`
  are refused. A subcommand comes first: only options that take no value (`--me`, `-c`, …) may
  stand before it, so `alias sq='sq --me'` still works with it.

## sq job

`sq job JOBID` shows one job: its state and times, the CPUs and memory it asked for and was
given, its work directory and output files, and once it ended how well it used them:

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

- **Where it differs from `seff`:** its CPU time includes what Slurm's sampling saw of processes
  it killed or never waited for, which `seff` leaves out (a job killed at its time limit can read
  near 0 % there), and its peak memory is the largest step's total, each task's own peak added
  up, where `seff` multiplies the largest single task's peak by that step's task count.
- **CPU** is the steps' CPU time against CPUs × elapsed. Per step it is the larger of what the
  step's processes reported and what Slurm's sampling saw, so processes Slurm killed or never
  waited for still count (a note says when the sampling decided it); sampled, it stays a lower
  bound. When Slurm gave more CPUs than were asked for, a note says how far a program running
  one thread per requested CPU can get at most. Green from 70 % of that, yellow from 30 %, red
  below.
- **MEM** is the largest step's peak against the allocation, coloured as the dashboard's MEM.
  A step of several tasks adds up each task's own peak, an upper bound, and a note says so.
  The peak is sampled, so a job killed for its memory can read far below its limit; an
  `OUT_OF_MEMORY` job gets a note saying that. On a cluster whose accounting moved from RSS to
  PSS, set [`SQ_PSS_SINCE`](#usage) to when: a peak measured before it gets a note, as RSS
  counts memory shared between processes once per process.
- **While your own job runs**, the memory it uses now, as the dashboard's MEM reads it, from
  the same reading (`?` none yet, `!` it failed); the CPU efficiency comes when it ends.
  Another user's running job and a pending job have no efficiency section: `sstat` answers
  only a job's owner.
- **Why**, a section right after the state: for a pending job, what holds it and who can act,
  as one coloured verdict (green *waits its turn*, yellow *needs action*, *waits for an admin*
  and *stuck*, red *can never start* and *will never start*), the same kinds the dashboard sorts
  pending jobs by, with the detail: the parents of a dependency and their state now, a job
  waiting for resources against what each node it may use has free and the running jobs that
  must end first, the jobs ahead of it in the queue, the command that releases a hold. For an
  ended job that did not complete: its exit in plain words (and what sacct cannot tell apart,
  such as exit 4 and a SIGILL), who cancelled it, the time or memory limit it hit, the node it
  lost. A failed job's output ends the section with its last 5 lines, read from the file's last
  4096 bytes while Slurm still knows its path, for every job whose file you can read, other
  users' too; the file is read by one process that gets 2 s, so a hung network mount does not
  hang `sq job` (that process, stuck in the kernel, is the one sq may leave behind). A running
  or completed job has no why section.
- **An array**, `sq job 12345`, gets one summary: its tasks counted by state, and over the
  completed ones the median, the weakest task and the best, so `sq job 12345_7` can look at the
  weakest, and why its other tasks did not complete. A task is `12345_7`, or its own job id.
  While accounting does not answer, the count is a floor: `array of ≥5 (accounting did not
  answer)`.
- The efficiency comes from accounting (`sacct`), so it shows once accounting has recorded the
  job's end, a moment after squeue says it ended. `sq job` waits up to 30 s for it (a big
  array's rows take a while), `SQ_TIMEOUT` instead when set, and asks the rest meanwhile. A job squeue has forgotten (about 5 minutes
  after it ends) is still shown from accounting, without its output paths.
- When one of squeue and sacct does not answer, the report shows what the other knows and a dim
  line says which. Exit 0 when shown, 1 when Slurm does not know the job or cannot be asked, 2
  for a usage error. Het jobs are not supported yet. `-M`, `--federation`, `--sibling` and
  `SLURM_CLUSTERS` are refused, as `sq log` refuses them.

## Good to know

- **How the mode is chosen:** `--compact` or `--full`, else `SQ_COMPACT`, else COMPACT when
  stdout is a terminal, or when `COLUMNS` and `LINES` are both in the environment, which is how
  `watch` runs sq (an interactive shell does not export them). Anything else, a pipe, a file,
  `ssh host sq` without `-t`, a cron job, gets FULL. `sq --compact` with no size to measure
  uses the usual fallback size, 24 lines.
- **Finished jobs come from the accounting database** (`sacct`), so a job that ended while
  nobody was watching is still shown, for as long as `SQ_SINCE` reaches back. Step rows are read
  too, because a signalled job's own row reports success and only its step carries the signal.
  Without accounting, or with a filter sq does not translate for sacct (`-n`, `-w`, `-L`, `-R`,
  `--sibling`), the block falls back to `squeue -t all`, which only remembers jobs for
  `MinJobAge` (often 300 s), and the caption says so (`sq does not translate -n for sacct`).
  A state filter (`-t`) filters the queue only: the block shows every finished job either way.
  `--array` (`-r`) becomes sacct's `--array`, one row per task of a pending array's remainder,
  and `--local` and `--federation` are sacct's own; `--noconvert`, `--priority` (`-P`) and `-S`
  only change how squeue shows its jobs, and `--all` (`-a`) and `--hide` only whether it shows
  the jobs of hidden partitions and of partitions closed to your groups, which sacct always
  shows, so none of them is passed to sacct. So in squeue's default view (no `--all`, no `-p`)
  the queue leaves out those partitions' jobs while the finished block lists them. sacct also
  refuses an unknown user or QoS that squeue only warns about: `-u alice,typo` shows alice's
  queue beside a fallback block that names sacct's error.
- **squeue's environment counts as its flags.** `SQUEUE_USERS`, `SQUEUE_PARTITION`,
  `SQUEUE_ACCOUNT`, `SQUEUE_QOS`, `SQUEUE_STATES`, `SQUEUE_NAMES`, `SQUEUE_LICENSES` and
  `SLURM_CLUSTERS` are read as `-u`, `-p`, `-A`, `-q`, `-t`, `-n`, `-L` and `-M`, the flag on the
  command line winning, and `SQUEUE_ALL`, `SQUEUE_ARRAY`, `SQUEUE_PRIORITY`, `SQUEUE_LOCAL`,
  `SQUEUE_FEDERATION`, `SQUEUE_SIB` and `SQUEUE_SIBLING` (set at all, even empty) as `-a`, `-r`,
  `-P`, `--local`, `--federation` and `--sibling`, all in squeue's own order, so the queue, the
  finished block and its caption see the same filters. squeue's environment may stop sq with a
  usage error naming the variable, because squeue would silently show no job (or fail): one set
  but empty or of only blanks and commas, a user, partition, account, QoS or cluster beginning
  with `-` (`SLURM_CLUSTERS` even under `-M`, as squeue reads it first), and `SQUEUE_LICENSES`
  together with `-L` or `-p`, which Slurm versions read differently. sq's own `SQ_*` variables
  never stop it, except `SQ_FMT`, whose letters are checked like `-o`'s; any other invalid one
  keeps its default. `SQUEUE_SORT` is ignored, as sq sorts the queue itself, other `SQUEUE_*`
  names are left to squeue, which ignores them too, and the finished block's `sacct` runs
  without your `SACCT_*` settings. A `SQUEUE_SIB` or `SQUEUE_SIBLING` set in a profile costs the
  accounting block, as `--sibling` does: sacct has no sibling view.
- **Reading EXIT:** the exit code, then what ExitCode's second field says, taken from the job
  and its steps (the first non-zero one, except that an out-of-memory always wins): `rc/sigN`
  is signal N as Slurm records it, `rc/oom` out of memory, and `rc/errN` the low 7 bits of a
  Slurm error code, not errno, from slurmd starting the job or step: 53 task I/O setup failed
  (the stdin, stdout or stderr file, or the link back to srun), 52 slurmstepd could not start
  the tasks: a fork, chdir, pam_setup or privilege drop failed, or a task or proctrack plugin
  call did (a missing or non-executable program is not 52: it exits with its errno, e.g. exit 2
  for a missing file; a spank plugin failing after start-up reads as an exit code, not an
  errN), 46 the process-tracking container for the step could not be created, 48 switching to
  the user's ids failed (setuid/setgid), 54 the prolog failed or never started, 115 the spank
  plugin stack failed to initialize. So EXIT can show a step's OOM on a job that finished
  COMPLETED. A folded row lists its distinct exits, highest exit code first, then highest N.
  Known limits: a launch or communication failure can read as `sig11`, `sig12` or `sig13`
  (Slurm's own log calls it RaisedSignal); steps Slurm closes for a dead node read `sig9`; an
  OOM caught by OverMemoryKill or missed by the cgroup detection reads `sig9`; a real-time
  signal (34–64) reads `errN`; a signal passed through a shell as exit 128+N reads as exit N
  (that is sacct's text; the `squeue -t all` fallback shows 128+N).
- **The bell keeps a little state:** `<jobid><tab><end time>` lines in `~/.cache/sq/alerted`,
  added to and aged out after 24 h, never pruned just because one run looked at fewer jobs, and
  replaced atomically so two running copies cannot tear it. The directory is
  `$XDG_CACHE_HOME/sq` when that is an absolute path, else `~/.cache/sq` (the `memuse` below
  lives there too); with no absolute `HOME` either, or a directory sq cannot write in, sq keeps
  no state and the bell stays off.
- **MEM is each job's total memory:** what a running job holds and what a pending one asks for,
  as Slurm's `tres-alloc` reports it, not per node or per CPU as squeue's own `%m` prints it: a
  `--mem-per-cpu=7800M -c 2` job reads `15.2G`, not `7800M`. Binary units, `M` below 1000 MiB,
  `T` from 1 TiB, else `G`, with one decimal, cut, where it is not whole; on a screen too narrow
  for the decimals, whole numbers from 10 up (`15G`; `7.6G` and `0.9G` keep their decimal). A
  folded row's MEM is the sum over the jobs it stands for: a folded array row adds up its tasks,
  and a pending bracket `×16` is sixteen times the request of one task, also with no JOBID column
  to show the `×16` (without one, tasks do not fold). A pending job's request is what it
  asked for, not always what it will get: an `--exclusive` job is given the whole node, and a
  `--mem=0` job the memory of the node it lands on. A red `!` before the value means sq could
  not get the totals, and the value is squeue's `%m`; a job Slurm reports no total for shows
  `%m` too. The totals cost one more `squeue` call per refresh, made only while MEM is shown and
  no cluster is selected: under `-M`, `--federation`, `--sibling`, `SLURM_CLUSTERS` or
  `SQUEUE_FEDERATION`, `SQUEUE_SIB`, `SQUEUE_SIBLING` (set at all, even empty), MEM is `%m`, and
  your own jobs' use is not read either. `FederationParameters=fed_display` in `slurm.conf`
  selects the federation too, but sq does not detect it. `%m` means what squeue means by it, per
  node, or per CPU for a `--mem-per-cpu` job, but is printed in the same units (`7800M` reads
  `7.6G`); a `0` (`--mem=0`) stays `0`.
- **Your own running jobs show the memory they use** in MEM, as in use/allocated (`83/100G`,
  `7.7/15.2G`), green below 70 %, yellow from 70 %, red from 90 %, bold red from 100 % (on a
  screen too narrow for that, whole numbers, `7/15G`, but an allocation below 10 keeps its
  decimal, `1/1.2G`; still too narrow, with colour, the allocation alone, `15G`, in the same
  colours). The reading comes from `sstat` and refreshes at most
  every 30 s: it is kept in `~/.cache/sq/memuse`, which every sq of yours shares. `?` means no
  reading: none yet, or a job sq does not measure (one on several nodes, or without a memory
  allocation); `!` that the reading failed. The figure leaves out page cache, tmpfs and
  `/dev/shm`, which the job's out-of-memory limit counts, so a job can be killed while it reads
  well below its allocation.
- An unreachable controller makes `sinfo` and `squeue` hang rather than fail, so every call is
  bounded by `SQ_TIMEOUT` (`sstat` by at most 2 s). The calls that need the job list (the memory
  ones, the `squeue -t all` fallback) are skipped when it does not come, so an outage of the
  controller delays a refresh by about twice that, three times when accounting (`sacct`) does
  not answer either.
- **Clock times are the server's,** in its time zone, which the title names (`UTC` on many
  clusters). Set `TZ`, e.g. `TZ=Europe/Berlin sq`, to read the title and the start estimates
  in your own. A start estimate names its month in English whatever your locale (`Oct23 14:05`).
- **A `␚` stands for bytes that are not valid UTF-8,** one per broken piece, wherever sq draws
  text: in what Slurm's tables print (job, user and node names, reasons, `sq job`'s fields), in
  error messages, in filters and `SQ_SINCE` on captions, in usage errors and in the host name in
  the title. Bidi controls (U+202A-202E, U+2066-2069, U+200E/F, U+061C), which would turn around
  what follows them on a line, are dropped; every other character stays, emoji joiners too. Two
  names that differ only in such bytes or controls read the same and are one: the node block
  shows the first of two such nodes, scontrol then lists that name twice, so its memory bar
  counts all of RealMemory and `sq job` calls it unknown, and array tasks named so fold
  together. `sq log` passes a job's output file on as it is.
- **Refused:** `-O`/`--Format`, `-s`/`--steps`, `-i`/`--iterate`, `-l`, `-v`, `-V`, `--json` and
  `--yaml`, in any spelling (`-Oi`, `--steps=5`, `-aO`). Each would replace or defeat the output
  sq parses; sq exits with code 2 and says why. (`-o`/`--format` are sq's own column list.)
  Options run together are refused (`-ar`, `-atR`: write `-a -r`, `-a -t R`), and so is any
  short option sq does not forward (`-z`). A long name written with one dash is refused with a
  hint, `-partition` is no `-p artition`; the cost: a job named "ame" is written `-n ame`, not
  `-name`, a user "sers" `-u sers`, a partition "artition" `-p artition`. Slurm's development
  branch adds `-J`/`--job-name` (= `-n`), which sq refuses until it is listed.

## Tests

```sh
tests/run.sh              # ~25 min, no cluster needed
tests/run.sh -j 6         # ~8 min: 6 cases at once, the timed ones one by one after
```

The suite puts stand-ins for `squeue`, `sinfo`, `sacct`, `sstat`, `scontrol` and `getent` first
on `PATH` and feeds sq the shapes that are hard to get from a live cluster: large arrays, hostile
job names, array ids Slurm truncates, a controller that hangs. Most cases assert properties of
the screen (counts, which rows appear, that nothing is forged), not a snapshot; the node bars
and the `sq job` reports are compared byte for byte with the screens they were designed from
(`tests/run.sh --pin` writes the latter anew, for a change meant to change them). Known defects are listed
as expected failures, so a fix shows up as one. `tests/faithfulness.sh <host>` compares the
stand-ins' output with the real tools, read-only, and fails wherever a real tool complains on
stderr.

## License

MIT, see [LICENSE](LICENSE).
