# Are the stubs faithful?

A stub that renders a format differently from Slurm makes every test a lie, so
the stubs in `tests/bin` were compared with the real clients on bioserver
(Slurm 23.11.4), read-only. Re-run it with:

    tests/faithfulness.sh fsill@bioserver      # or with no argument on a host with Slurm
    tests/faithfulness.sh fsill@bioserver --keep   # keeps real and stub output

## Byte comparisons (automated)

For each call shape, `faithfulness.sh` runs the real command with a separator
shaped like sq's nonce (`N` + 24 hex), turns the real output into a fixture
(one record per real record, values escaped), renders that fixture with the stub
given the same argv and environment, and compares the bytes with `cmp`.

| shape | command (separators as sq mints them) | result 2026-10-06 |
|---|---|---|
| nodes | `SLURM_TIME_FORMAT=standard sinfo -hN -o '%C<N3>%N<N3>%e<N3>%m<N3>%T<N3>%E<N3>%H<N3>'` | MATCH: 2 records, 448 bytes |
| queue | `SLURM_TIME_FORMAT=standard SQUEUE_FORMAT='%i<N>%j<N>…%t<N>%l<N>%S<N>' squeue -h -S t,i` | MATCH, but EMPTY: 0 bytes vs 0 bytes |
| finished | `SLURM_TIME_FORMAT=standard sacct -p --delimiter=<N2> -n -S now-7days -E now -a -o JobID,User,State,ExitCode,Elapsed,End,NodeList,JobName` | MATCH: 1198 records, 325915 bytes |
| fallback | `SLURM_TIME_FORMAT=standard SQUEUE_FORMAT2='JobID:<N>,StateCompact:<N>,…,Name:<N>' squeue -t all -h` | MATCH, but EMPTY: 0 bytes vs 0 bytes |
| array ids | the finished command restricted to the 10 bracketed array ids in the window, with `SLURM_BITSTR_LEN` unset, 0, 1, 2, 3, 4, 5, 6, 8, 64; the fixture is taken once with `SLURM_BITSTR_LEN=0` (the whole truth) | MATCH at every length |

What a match shows: field order, the separator after every field including the
last (`sacct -p`, `%x<N>`), no header with `-h`/`-n`, empty fields (a step row's
`User`), the raw bytes inside values (the sacct history holds job names with
newlines, tabs, `|`, ESC sequences, `\x01` and nonce-shaped text, all reproduced),
the newline after each record, and sacct's array-id truncation
(`10609_[...%3]` at 4, `10609_[0...%3]` at 5, `10609_[%3]` at 1).

A negative control: rendering the sacct fixture with `-P` instead of `-p` differs
from the real output at byte 249 (the missing trailing delimiter), so the
comparison can fail.

## squeue, through its header (automated)

The queue was empty, so no squeue RECORD could be compared. A header is padded
to its column's width (the unsuffixed `-O` check shows that padding), so the
header is indirect evidence of the framing, not proof:

| check | command | real first line |
|---|---|---|
| `-o` grammar: letter, then the literal, no padding | `SQUEUE_FORMAT='%i<N>%j<N>%t<N>' squeue -t all` | `JOBID<N>NAME<N>ST<N>` |
| `-O` `Field:suffix`: no padding | `SQUEUE_FORMAT2='JobID:<N>,ArrayTaskID:<N>,Name:<N>' squeue -t all` | `JOBID<N>ARRAY_TASK_ID<N>NAME<N>` |
| `-O` without suffix IS padded (so the stub refuses it) | `squeue -t all -O JobID,Name` | `JOBID` + 15 spaces, `NAME` + 16 spaces |
| `SQUEUE_FORMAT` beats `SQUEUE_FORMAT2` (the stub does the same) | both set | `JOBID<N>` |
| sinfo `-N -o` | `sinfo -N -o '%C<N3>%N<N3>%E<N3>'` | `CPUS(A/I/O/T)<N3>NODELIST<N3>REASON<N3>` |

## By hand (2026-10-06)

- `sacct -P` ends a line without the delimiter, `-p` with it; both emulated.
- sacct field names match in any case (`-o jobid,USER,state`); so do the stub's.
- `sacct -o JobID,ArrayTaskID` fails with `sacct: error: Invalid field requested`
  and rc 1: accounting has no array field, so the fallback fixtures carry
  `ArrayJobID`/`ArrayTaskID` and the sacct fixtures carry the id only.
- `sinfo -hN` with no reason prints `none` for `%E` and `Unknown` for `%H`; the
  shared fixture `fixtures/_common/sinfo-two-idle` uses exactly that.

## Not compared, and how the stub handles it

- **A squeue record.** The queue was empty; only the empty output and the header
  framing above were compared. When a job is queued, re-run `faithfulness.sh`:
  the `queue` and `fallback` rows then compare real records.
- **squeue's 31-character `%i` cut** for a bracketed id with `SLURM_BITSTR_LEN`
  unset (`snprintf(id, 32, "%u_[%s]")` in 23.11, per the array-count spec): not seen
  live (no pending array). With `SLURM_BITSTR_LEN=0` the stub prints the whole id;
  any other value for squeue `%i` is refused rather than guessed.
- **`-O JobID` of an array** prints the plain base id and the expression arrives
  bare in `ArrayTaskID` (stated in the array-count spec; not seen live). The
  stub refuses a `[` in a fallback `JobID`, so a fixture cannot get this wrong.
- **The 64-byte default truncation on a long expression**: the algorithm was
  matched at lengths 1-8 and 64 on short expressions; no expression longer than
  64 bytes was in the window. A strided (`a-b:s`) or `ArrayTaskID` expression
  long enough to be cut is refused by the stub, as its truncation was not seen.
- **Selection.** The stubs apply no filter and no sort: a fixture lists what the
  real tool would return, in its order. The filters are logged. The one exception
  is `-t all`, which picks the `squeue-all` fixture, because it asks a different
  question (finished jobs too); as in squeue, the last `-t` wins.
- **Unemulated forms** (field widths, `%%`, headers, unsuffixed `-O` fields, the
  default formats, any option sq does not send) make the stub exit 97 with a
  `STUBERROR` line in the log, which fails the case.
