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
| nodes | `SLURM_TIME_FORMAT=standard sinfo -hN -O 'CPUsState:0<N3>,NodeList:0<N3>,FreeMem:0<N3>,Memory:0<N3>,StateLong:0<N3>,Reason:0<N3>,TimeStamp:0<N3>,CPUsLoad:0<N3>,AllocMem:0<N3>'` | MATCH (2026-10-07): 2 records, 558 bytes |
| nodes, no size | the same with `Field:<N3>` instead of `Field:0<N3>` | MATCH (2026-10-07): 2 records, 558 bytes |
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
| sinfo `-N -O` `Field:0suffix` (2026-10-07) | `sinfo -N -O 'CPUsState:0<N3>,NodeList:0<N3>,Reason:0<N3>,CPUsLoad:0<N3>,AllocMem:0<N3>'` | `CPUS(A/I/O/T)<N3>NODELIST<N3>REASON<N3>CPU_LOAD<N3>ALLOCMEM<N3>` |
| sinfo `-O` without size IS padded (so the stub refuses it) | `sinfo -N -O NodeList,Reason` | `NODELIST` + 12 spaces, `REASON` + 14 spaces |

## By hand (2026-10-06)

- `sacct -P` ends a line without the delimiter, `-p` with it; both emulated.
- sacct field names match in any case (`-o jobid,USER,state`); so do the stub's.
- `sacct -o JobID,ArrayTaskID` fails with `sacct: error: Invalid field requested`
  and rc 1: accounting has no array field, so the fallback fixtures carry
  `ArrayJobID`/`ArrayTaskID` and the sacct fixtures carry the id only.
- `sinfo -hN` with no reason prints `none` for `%E` and `Unknown` for `%H`; the
  shared fixture `fixtures/_common/sinfo-two-idle` uses exactly that.

## sinfo -O, by hand (2026-10-07)

sq asks sinfo with `-O`, because AllocMem has no `-o` letter. Its grammar is
`type[:[.][size][suffix]]`, the size read with `strtol` (`_parse_long_token`,
`src/sinfo/opts.c`), so the size and the separator have to be told apart. With
the nonce `N5c33003374c1ff99ec32cff8` on both nodes of bioserver:

- **The eight fields `-o` also has are the same bytes.** `-hN -o
  '%C<N>%N<N>%e<N>%m<N>%T<N>%E<N>%H<N>%O<N>'` and `-hN -O 'CPUsState:0<N>,…,CPUsLoad:0<N>,AllocMem:0<N>'`,
  run back to back, print identical bytes up to `%O`; `-O` then adds AllocMem.
  Both letters and names call the same `_print_*` function (`src/sinfo/print.c`).
- **Size 0 is printed whole: no padding, no cut.** `Field:0<N>` and `Field:<N>`
  print identical bytes. Without the node split, `NodeList:0<N>` printed
  `fb2-bioinf,fb2-bioinf-0` (23 characters) whole, past the default 20.
- **Any other size pads and cuts.** No colon pads to 20 (`fb2-bioinf` + 10
  spaces); `:3` cuts (`fb2`, `non`, `0.4`) and pads (`0` + 2 spaces), `:8` pads
  `idle` to 8, `:.8` right-justifies. `:0` without a suffix prints the fields
  run together, with no separator at all.
- **A digit-led suffix is a size**: `NodeList:12345x` pads the name to 12345
  columns. A `:` inside the suffix is kept (`NodeList:0a:b<N>` prints `a:b<N>`).
  A nonce is letter-led and alphanumeric, so it is never a size and never holds
  the `,` that splits the field list.
- **Precedence**: `SINFO_FORMAT='%N|%T'` with `-O` on the command line prints the
  `-O` fields. `-O` then `-o`: the `-o` string is parsed in `-O`'s grammar
  (`Invalid job format specification: %NN…`, empty lines, rc 0); the stub refuses
  both together.
- **An unknown field name** is an error on stderr (`Invalid job format
  specification: AllocMemX`) with rc 0, and in sq's `Field:0<N>` form it keeps
  its place: `…,CPUsLoad:0<N>,AllocMemX:0<N>` printed `0/128/0/128<N>fb2-bioinf<N>0.00<N><N>`,
  an EMPTY field followed by its separator (`format_add_invalid` in
  `src/sinfo/opts.c` keeps the suffix), so the field count stays right. Only a
  token without a colon (`Reason<N>`) drops both the field and its separator.
  So the record gate does not catch a misspelt field: sq would read an empty
  AllocMem as 0 and an empty CPUsLoad as unknown, without a caption, since it
  ignores stderr when sinfo exits 0. Nor does `faithfulness.sh`: run with
  `AllocMemX` it still says MATCH, because the empty field goes into the
  fixture (`AllocMemX=`) and the stub renders it back; only the error in the
  real command's stderr, which it does not check, tells. What guards the
  names is `tests/run.sh` pinning the exact `-O` string sq sends (`c_mixed`),
  together with the measurements above, made with those names.
- **Forms**: no reason is `none` and its TimeStamp `Unknown` (with
  `SLURM_TIME_FORMAT` standard, unset and relative); CPUsLoad has two decimals
  (`0.46`, `0.01`); AllocMem and FreeMem are whole MB (`0`, `1018271`).
- **One line per node** with `-N`, so no min-max range (`0.10-0.46`) appears; a
  range is printed only for a record covering several nodes.

## Not compared live, and what the stub rests on instead

Premises never seen on the cluster are taken from the Slurm 23.11.4 source (tag
`slurm-23-11-4-1`), read for this:

- **squeue's 31-character `%i` cut.** `_print_job_job_id` formats a pending
  array's id with `snprintf(id, FORMAT_STRING_SIZE, "%u_[%s]", …)`
  (`src/squeue/print.c:643`), `FORMAT_STRING_SIZE` being 32
  (`src/squeue/print.h:47`): the id is cut at 31 characters, mid-expression,
  without its `]`. The cut is skipped when `SLURM_BITSTR_LEN` is set to ANY value
  (`print.c:635` only checks `getenv(...)` for non-NULL); the expression itself is
  still shortened to that length first (below). The stub cuts at 31 when the
  variable is unset and prints the whole id at 0; any other value for squeue
  `%i` it refuses rather than emulate.
- **`-O JobID` of an array** prints the plain `job_id` (`_print_job_job_id2`,
  `print.c:664-672`), never a bracket; the expression arrives in `ArrayTaskID`.
  The stub refuses a `[` in a fallback `JobID`, so a fixture cannot get this wrong.
- **`-O ArrayTaskID` of a job that is no array** is the literal `N/A`:
  `_print_job_array_task_id` (`src/squeue/print.c`) prints `job->array_task_str`
  if set, else the numeric `array_task_id` if it is not `NO_VAL`, else `"N/A"`.
  The fallback fixtures' default `ArrayTaskID=N/A`
  (`fixtures/_common/squeue-all-defaults`) rests on this, and it is load-bearing:
  sq skips a fallback row whose `ArrayTaskID` is not `N/A`, plain digits or a
  valid array expression.
- **The `%n` throttle** is appended after any shortening
  (`src/common/slurm_protocol_defs.c:6888`, in `xlate_array_task_str`), which the
  live sacct comparison confirmed (`10609_[...%3]` at length 4).
- **A strided range is never shortened**: `xlate_array_task_str` prints a step
  function as `first-last:step` and jumps past the truncation
  (`slurm_protocol_defs.c:6834-6856`). It only does so when the range spans more
  than 10, has more than 5 tasks and skips the second index, so `0-12:2` is one.
  The stub refuses a strided expression long enough to be cut by its length rule
  rather than apply that rule to it.
- **`squeue -S t` sorts compact state codes as strings** (`xstrcmp` of
  `job_state_string_compact`, `src/squeue/sort.c:658-672`): `CG` < `PD` < `R`.
  Fixtures list their queue records in that order, since the stub does not sort.

- **N/A in FreeMem and CPUsLoad.** Both nodes were up, so neither was seen.
  `_build_free_mem_min_max_64` and `_build_cpu_load_min_max_32`
  (`src/sinfo/print.c`) print `N/A` for `NO_VAL64` / `NO_VAL`. slurmctld starts a
  node with `free_mem = NO_VAL64` until it registers (`_init_node_record`,
  `src/common/node_conf.c:784`), so FreeMem `N/A` is real; but it starts
  `cpu_load` at 0 (`node_conf.c:781`) and resets it to 0 when a node is downed
  or powered down (`node_mgr_reset_node_stats`, `src/slurmctld/node_mgr.c:4597`),
  so a down node most likely shows CPUsLoad `0.00`, not `N/A`. The fixtures
  with `CPUsLoad=N/A` (`bars-down`) exercise sq's handling of a value Slurm can
  print, not one bioserver was seen to print. AllocMem is always a number
  (`_print_alloc_mem`, `"%"PRIu64`).
- **A long REASON.** No reason can be set read-only. `_print_str` prints a size-0
  field with a bare `printf("%s")` (`src/sinfo/print.c`), and the 23-character
  NodeList above shows size 0 does not cut.

Other limits:

- **A squeue record.** The queue was empty; only the empty output and the header
  framing above were compared. When a job is queued, re-run `faithfulness.sh`:
  the `queue` and `fallback` rows then compare real records.
- **The 64-byte default truncation on a long expression**: the algorithm was
  matched at lengths 1-8 and 64 on short expressions; no expression longer than
  64 bytes was in the window.
- **Selection.** The stubs apply no filter and no sort: a fixture lists what the
  real tool would return, in its order. The filters are logged. The one exception
  is `-t all`, which picks the `squeue-all` fixture, because it asks a different
  question (finished jobs too); as in squeue, the last `-t` wins.
- **Unemulated forms** (field widths, `%%`, headers, unsuffixed `-O` fields, the
  default formats, squeue `--array` and `--noconvert`, sacct `-X`, any option sq
  does not send) make the stub exit 97 with a `STUBERROR` line in the log, which
  fails the case. `sacct -X` in particular drops the step rows, the only ones that
  carry a signal (seen live), so it could not be rendered from a fixture that has
  them.

## Known gaps of the suite

Left out on purpose, as cosmetic: right alignment of the numeric columns and
the truncation of a long drain reason. Neither carries a count or a row. The bar
glyphs are checked only on the node screens of the `bars_*` cases.
