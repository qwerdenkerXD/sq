# Renders a fixture in the format a Slurm client was asked for; driven by
# tests/lib/stub.sh, which documents the fixture format.  Input comes from the
# environment: STUB_TOOL, STUB_MODE (pct | long | sacct | raw | json | jsonfile), STUB_FMT, STUB_DELIM,
# STUB_TRAIL, STUB_FILE, SQSTUB_LOG, STUB_MIRROR=1 when the queue's own file
# answers sq's mirror call (stub.sh says how), STUB_DERIVE=1 when the sinfo
# file answers scontrol (ditto), STUB_CALL (which call of this
# tool and format this is in the run) and STUB_RUN (the run's directory).

function refuse(msg) {
  printf "stub %s: %s\n", tool, msg > "/dev/stderr"
  printf "STUBERROR\t%s\t%s\n", tool, msg >> logf
  close(logf)
  exit 97
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function where() { return cur_file " line " cur_line }

# the format, as tokens: lit[0] val[1] lit[1] val[2] ... val[nf] lit[nf]
function parse_format(   i, c, d, m, items, p, name, spec) {
  nf = 0; lit[0] = ""
  if (mode == "raw" || mode ~ /^json/) return   # scontrol: each line as written, or one JSON document
  if (mode == "pct") {                        # squeue -o / SQUEUE_FORMAT, sinfo -o:
    for (i = 1; i <= length(fmt); i++) {      # %<letter>, then literal text up to
      c = substr(fmt, i, 1)                   # the next %
      if (c != "%") { lit[nf] = lit[nf] c; continue }
      d = substr(fmt, i+1, 1)
      if (d !~ /^[A-Za-z]$/)
        refuse("format '" fmt "': only bare %<letter> fields are emulated (no widths, no %%)")
      fld[++nf] = d; lit[nf] = ""; i++
    }
  } else if (mode == "long") {                # squeue -O / SQUEUE_FORMAT2, sinfo -O:
    m = split(fmt, items, ",")                # Field:suffix, suffix letter-led; sinfo
    for (i = 1; i <= m; i++) {                # also Field:0suffix, size 0 (measured:
      p = index(items[i], ":")                # the same bytes as Field:suffix)
      if (!p) refuse("-O field '" items[i] "' has no :suffix; " tool " pads it to a default width, which is not emulated")
      name = substr(items[i], 1, p-1); spec = substr(items[i], p+1)
      if (tool == "sinfo") sub(/^0/, "", spec)
      if (spec !~ /^[A-Za-z]/)
        refuse("-O field '" items[i] "': only a letter-led suffix is emulated (" \
               (tool == "sinfo" ? "no width but 0" : "no widths") ", no '.')")
      fld[++nf] = tolower(name); lit[nf] = spec
      gsub(/-/, "_", fld[nf])                 # tres-alloc: the fixture says tres_alloc
    }
  } else if (mode == "sacct") {               # sacct -p/-P -o a,b,c --delimiter=D
    m = split(fmt, items, ",")
    for (i = 1; i <= m; i++) {
      if (items[i] !~ /^[A-Za-z]+$/) refuse("sacct field '" items[i] "' is not emulated (no %width)")
      fld[++nf] = tolower(items[i]); lit[nf] = ENVIRON["STUB_DELIM"]
    }
    if (ENVIRON["STUB_TRAIL"] != "1") lit[nf] = ""    # -P: no trailing delimiter
  } else refuse("unknown mode '" mode "'")
  if (!nf) refuse("format '" fmt "' requests no field")
}

# \{now-1h30m}: the time that far from the moment the stub runs, printed the way
# SLURM_TIME_FORMAT=standard prints one; \{epoch-1h30m} the same moment as an
# integer epoch, the way SLURM_TIME_FORMAT=%s prints one.  A fixture says how
# long ago a job ended, never when, so the ages sq renders from it cannot
# change with the date the suite runs on.  OFF is "", or a sign and d/h/m/s
# terms: "-1h30m", "+2d"
function offset(off,   sign, sec, u) {      # OFF in seconds, signed
  sign = (substr(off, 1, 1) == "+") ? 1 : -1
  sec = 0; off = substr(off, 2)
  while (match(off, /^[0-9]+[dhms]/)) {
    u = substr(off, RLENGTH, 1)
    sec += substr(off, 1, RLENGTH - 1) * (u == "d" ? 86400 : u == "h" ? 3600 : u == "m" ? 60 : 1)
    off = substr(off, RLENGTH + 1)
  }
  return sign * sec
}
# The moment is the stub's clock less SQSTUB_SKEW seconds: SQSTUB_SKEW=-1 prints
# every time 1 s later, as if the clock stepped back 1 s once the stub answered
# (WSL steps it back about 1.5 s every 30 s)
function stubnow() { return systime() - ENVIRON["SQSTUB_SKEW"] }
function reltime(off) { return strftime("%Y-%m-%dT%H:%M:%S", stubnow() + offset(off)) }
function relepoch(off) { return sprintf("%d", stubnow() + offset(off)) }

function decode(s,   out, i, c, d, n) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c != "\\") { out = out c; continue }
    d = substr(s, ++i, 1)
    if      (d == "n")  out = out "\n"
    else if (d == "t")  out = out "\t"
    else if (d == "r")  out = out "\r"
    else if (d == "e")  out = out "\033"
    else if (d == "a")  out = out "\a"
    else if (d == "s")  out = out " "
    else if (d == ";")  out = out ";"
    else if (d == "\\") out = out "\\"
    else if (d == "x" && substr(s, i+1, 2) ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
      out = out sprintf("%c", strtonum("0x" substr(s, i+1, 2))); i += 2
    }
    else if (d == "{" && substr(s, i+1, 4) == "run}") { out = out ENVIRON["STUB_RUN"]; i += 4 }
    else if (d == "{" && match(substr(s, i+1), /^now([-+]([0-9]+[dhms])+)?}/)) {
      n = RLENGTH; out = out reltime(substr(s, i+4, n-4)); i += n
    }
    else if (d == "{" && match(substr(s, i+1), /^epoch([-+]([0-9]+[dhms])+)?}/)) {
      n = RLENGTH; out = out relepoch(substr(s, i+6, n-6)); i += n
    }
    else refuse(where() ": unknown escape \\" d)
  }
  return out
}

# "k=v; k=v" into dst[], keys normalised: one letter stays as is (%i is not %I),
# a field name is matched in any case, as Slurm does
function parse_fields(line, dst,   i, c, piece, n, pieces, p, key) {
  n = 0; piece = ""
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    if (c == "\\") { piece = piece c substr(line, ++i, 1); continue }
    if (c == ";")  { pieces[++n] = piece; piece = ""; continue }
    piece = piece c
  }
  pieces[++n] = piece
  for (i = 1; i <= n; i++) {
    piece = trim(pieces[i])
    if (piece == "") continue
    if (!(p = index(piece, "="))) refuse(where() ": '" piece "' is not name=value")
    key = trim(substr(piece, 1, p-1))
    if (key !~ /^[A-Za-z_]+$/) refuse(where() ": '" key "' is not a field name")
    if (length(key) > 1) key = tolower(key)
    if (key in dst) refuse(where() ": field " key " set twice")
    dst[key] = decode(trim(substr(piece, p+1)))
  }
}

# ---- array ids: a fixture holds the WHOLE expression, Slurm may not print it --
# Slurm formats an array's task list through xlate_array_task_str(): with
# SLURM_BITSTR_LEN unset (or negative) into a 64-byte buffer, 0 = no limit,
# capped at 4096.  bit_fmt() writes "term," per term into the buffer (snprintf
# cuts the last one), zaps the last character, and if the result is longer
# than len-3 overwrites bytes len-4..len-2 with dots.  A %n throttle is appended
# after that.  Measured on 23.11 for every len 0..8 (tests/FAITHFULNESS.md).
function bitstr_len(   v) {
  if (!("SLURM_BITSTR_LEN" in ENVIRON)) return 64
  v = ENVIRON["SLURM_BITSTR_LEN"]
  v = match(v, /^[ \t]*[-+]?[0-9]+/) ? substr(v, RSTART, RLENGTH) + 0 : 0   # atoi()
  if (v < 0) return 64
  return v > 4096 ? 4096 : v
}
function xlate(expr, len,   thr, s, keep) {
  thr = ""
  if (match(expr, /%[0-9]+$/)) { thr = substr(expr, RSTART); expr = substr(expr, 1, RSTART-1) }
  if (len == 0) return expr thr
  if (expr ~ /:/) {                     # a step function is formatted on its own
    if (length(expr) > len - 3)         # path, which was never measured long
      refuse(where() ": truncation of the strided expression '" expr "' is not emulated")
    return expr thr
  }
  s = substr(expr ",", 1, len - 1)      # what snprintf fits into the buffer
  s = substr(s, 1, length(s) - 1)       # "zap trailing comma"
  if (length(s) > len - 3) {
    keep = (len > 4) ? len - 4 : 0
    s = substr(s, 1, keep) substr("...", 1, len - 1 - keep)
  }
  return s thr
}
# the value a field prints, after Slurm's own array-id formatting
function slurm_value(k, v,   len) {
  if (tool == "sacct" && k == "jobid" && match(v, /^[0-9]+_\[.*\]$/))
    return substr(v, 1, index(v, "[")) xlate(substr(v, index(v, "[") + 1, length(v) - index(v, "[") - 1), bitstr_len()) "]"
  if (tool == "squeue" && mode == "pct" && k == "i" && match(v, /^[0-9]+_\[.*\]$/)) {
    # squeue 23.11 prints %i of a pending array with snprintf(id, 32,
    # "%u_[%s]"): cut at 31 characters, mid-number, no closing "]".  Only
    # unset and 0 are known; 0 prints the whole expression
    if (!("SLURM_BITSTR_LEN" in ENVIRON)) {
      v = substr(v, 1, index(v, "[")) xlate(substr(v, index(v, "[") + 1, length(v) - index(v, "[") - 1), 64) "]"
      return substr(v, 1, 31)
    }
    if (bitstr_len() != 0)
      refuse("squeue %i with SLURM_BITSTR_LEN=" ENVIRON["SLURM_BITSTR_LEN"] " is not emulated (only unset and 0 are known)")
    return v
  }
  if (tool == "squeue" && mode == "long" && k == "jobid" && index(v, "["))
    refuse(where() ": -O JobID prints the plain base id, never a bracket; put the expression in ArrayTaskID")
  if (tool == "squeue" && mode == "long" && k == "arraytaskid" && v ~ /[-,:%]/) {
    len = bitstr_len()                  # the bare expression; its truncation
    if (len && length(v) > len - 3)     # was never measured, so it is refused
      refuse(where() ": truncation of ArrayTaskID '" v "' is not emulated")
  }
  return v
}

# scontrol -o show node from a sinfo record: each node once, the figures sinfo
# has, in scontrol's order (stub.sh says why); "" for a record that adds none
function derive_node(   rec, k, cpus, out) {
  parse_fields(cur_text, rec)
  for (k in DEF) if (!(k in rec)) rec[k] = DEF[k]
  if (!("nodelist" in rec) || rec["nodelist"] in DERIVED) return ""
  DERIVED[rec["nodelist"]] = 1
  out = "NodeName=" rec["nodelist"]
  if (split(rec["cpusstate"], cpus, "/") == 4) out = out " CPUAlloc=" cpus[1] " CPUTot=" cpus[4]
  if ("cpusload" in rec) out = out " CPULoad=" rec["cpusload"]
  if ("memory" in rec)   out = out " RealMemory=" rec["memory"]
  if ("allocmem" in rec) out = out " AllocMem=" rec["allocmem"]
  if ("freemem" in rec)  out = out " FreeMem=" rec["freemem"]
  return out
}

# ---- scontrol --json show node, made from -o lines: json-c's pretty layout ----
# (SPACED|PRETTY, as Slurm prints it) in the dialect of SQSTUB_JSONC: 0.17
# indents depth d by 2d spaces and prints an empty container as [] on one
# line, 0.16 (0.14-0.16) prints it as "[" and "]" lines, 0.13 (and older)
# indents by 2d+1 and ends with " }".  A string is escaped as json-c does it
function jind(d) { return sprintf("%*s", 2 * d + (JSONC == "0.13"), "") }
function jstr(s,   out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\"" || c == "\\" || c == "/") out = out "\\" c
    else if (c == "\b") out = out "\\b"
    else if (c == "\f") out = out "\\f"
    else if (c == "\n") out = out "\\n"
    else if (c == "\r") out = out "\\r"
    else if (c == "\t") out = out "\\t"
    else if (c in CTRL) out = out sprintf("\\u%04x", CTRL[c])
    else out = out c
  }
  return "\"" out "\""
}
# a member at depth d: KEY's value, a number if it is one, else a string
function jnum(d, key, v) { return jind(d) "\"" key "\": " (v ~ /^[0-9]+$/ ? v : jstr(v)) }
# a member at depth d whose value is the array of LIST's strings, split on SEP
function jarr(d, key, list, sep,   n, a, i, out) {
  n = (list == "") ? 0 : split(list, a, sep)
  out = jind(d) "\"" key "\": ["
  if (!n) return out (JSONC == "0.17" ? "]" : "\n" jind(d) "]")
  for (i = 1; i <= n; i++) out = out "\n" jind(d + 1) jstr(a[i]) (i < n ? "," : "")
  return out "\n" jind(d) "]"
}
# one node of the document from an -o line, as node_read reads that line: up
# to its first newline and its first " Reason=", " Comment=" or " Extra=",
# the first key of a name counting
function json_node(ln,   KV, s, m, M, mn, out, i) {
  sub(/\n.*/, "", ln)
  if (ln !~ /^NodeName=/) return
  if (match(ln, / (Reason|Comment|Extra)=/)) ln = substr(ln, 1, RSTART - 1)
  s = ln
  while (match(s, /(^| )([A-Za-z_]+)=([^ ]*)/, m)) { if (!(m[2] in KV)) KV[m[2]] = m[3]; s = substr(s, RSTART + RLENGTH) }
  if ("Arch" in KV) M[++mn] = jind(3) "\"architecture\": " jstr(KV["Arch"])
  M[++mn] = jind(3) "\"boot_time\": {\n" jind(4) "\"set\": true,\n" jind(4) "\"infinite\": false,\n" jind(4) "\"number\": 0\n" jind(3) "}"
  if ("CPUTot" in KV) M[++mn] = jnum(3, "cpus", KV["CPUTot"])
  if ("CPUEfctv" in KV) M[++mn] = jnum(3, "effective_cpus", KV["CPUEfctv"])
  M[++mn] = jarr(3, "features", "", ",")
  M[++mn] = jnum(3, "specialized_memory", ("MemSpecLimit" in KV) ? KV["MemSpecLimit"] : 0)
  M[++mn] = jind(3) "\"name\": " jstr(KV["NodeName"])
  M[++mn] = jarr(3, "next_state_after_reboot", "INVALID", ",")
  M[++mn] = jarr(3, "state", KV["State"], "+")
  M[++mn] = jarr(3, "partitions", KV["Partitions"], ",")
  if ("RealMemory" in KV) M[++mn] = jnum(3, "real_memory", KV["RealMemory"])
  M[++mn] = jind(3) "\"reason\": \"\""
  if ("AllocMem" in KV) M[++mn] = jnum(3, "alloc_memory", KV["AllocMem"])
  if ("CPUAlloc" in KV) M[++mn] = jnum(3, "alloc_cpus", KV["CPUAlloc"])
  M[++mn] = jnum(3, "weight", 1)
  out = jind(2) "{"
  for (i = 1; i <= mn; i++) out = out "\n" M[i] (i < mn ? "," : "")
  JNODE[++JNODES] = out "\n" jind(2) "}"
}
# the document of every node so far, once
function json_doc(   i) {
  if (mode != "json" || JDONE++) return
  printf "{\n"
  if (!JNODES) printf "%s\n", (JSONC == "0.17" ? jind(1) "\"nodes\": []," : jind(1) "\"nodes\": [\n" jind(1) "],")
  else {
    printf "%s\"nodes\": [\n", jind(1)
    for (i = 1; i <= JNODES; i++) printf "%s%s\n", JNODE[i], (i < JNODES ? "," : "")
    printf "%s],\n", jind(1)
  }
  printf "%s\"last_update\": {\n%s\"set\": true,\n%s\"infinite\": false,\n%s\"number\": 0\n%s},\n", jind(1), jind(2), jind(2), jind(2), jind(1)
  printf "%s\"meta\": {\n%s\"slurm\": {\n%s\"release\": \"23.11.4\"\n%s}\n%s},\n", jind(1), jind(2), jind(3), jind(2), jind(1)
  printf "%s,\n%s\n%s}\n", jarr(1, "errors", "", ","), jarr(1, "warnings", "", ","), jind(0)
}
function render(   rec, i, out, k, src) {
  if (mode == "jsonfile") { printf "%s\n", cur_text; return }
  if (mode == "json") { json_node(derive ? derive_node() : decode(cur_text)); return }
  if (derive) { out = derive_node(); if (out != "") printf "%s\n", out; return }
  if (mode == "raw") { printf "%s\n", decode(cur_text); return }
  parse_fields(cur_text, rec)
  out = lit[0]
  for (i = 1; i <= nf; i++) {
    k = fld[i]
    src = (mirror && k == "jobid") ? "A" : k   # the mirror call: -O JobID is %A
    if      (src in rec) out = out slurm_value(k, rec[src])
    else if (src in DEF) out = out slurm_value(k, DEF[src])
    else if (mirror && k == "tres_alloc") out = out "N/A"
    else refuse(where() ": no value for " (mode == "pct" ? "%" src : src) \
                " (the format asks for it; set it in the record or in @defaults)")
    if (i < nf || !cut_next) out = out lit[i]
  }
  printf "%s%s%s", out, trail_next, cut_next ? "" : "\n"; trail_next = ""; cut_next = 0
}

# ---- @step: which part of the file answers this call -------------------------
# served: the highest step number not above the call; 0 while the call comes
# before every step (or the file has none)
function steps_of(path,   line, rc, n) {
  while ((rc = (getline line < path)) > 0)
    if (line ~ /^@step[ \t]/) {
      n = line; sub(/^@step[ \t]+/, "", n); n = trim(n)
      if (n !~ /^[0-9]+$/ || n + 0 < 1) refuse(path ": @step needs a call number from 1")
      if (n + 0 <= call && n + 0 > served) served = n + 0
    }
  close(path)
}
# ---- @file: a side effect in the run's directory, as a step is served -----
function shq(x) { gsub(/'/, "'\\''", x); return "'" x "'" }
function file_op(arg,   m, op, rel, rest, full, dir) {
  if (!match(arg, /^([a-z]+)[ \t]+([^ \t]+)([ \t](.*))?$/, m)) refuse(where() ": @file needs OP PATH [ARG]")
  op = m[1]; rel = decode(m[2]); rest = m[4]
  if (rel == "" || rel ~ /^\// || ("/" rel "/") ~ /\/[.][.]\//) refuse(where() ": @file needs a path inside the run's directory, not '" rel "'")
  full = ENVIRON["STUB_RUN"] "/" rel
  dir = full; sub(/\/[^\/]*$/, "", dir)
  if (system("mkdir -p -- " shq(dir)) != 0) refuse(where() ": @file cannot make " dir)
  if      (op == "create")   { printf "%s", decode(rest) > full; close(full) }
  else if (op == "append")   { printf "%s", decode(rest) >> full; close(full) }
  else if (op == "truncate") { printf "" > full; close(full) }
  else if (op == "chmod")    { if (rest !~ /^[0-7]+$/ || system("chmod " rest " -- " shq(full)) != 0) refuse(where() ": @file chmod " rest " failed") }
  else if (op == "touch")    { if (system("touch -d " shq(decode(rest)) " -- " shq(full)) != 0) refuse(where() ": @file touch failed") }
  else if (op == "fifo")     { if (system("mkfifo -- " shq(full)) != 0) refuse(where() ": @file fifo failed") }
  else refuse(where() ": @file knows create, append, truncate, chmod, touch and fifo, not '" op "'")
}

function run_file(path, depth,   line, rc, saved_file, saved_line, dir, d, arg, tmp, k, step, on) {
  saved_file = cur_file; saved_line = cur_line
  cur_file = path; cur_line = 0; on = 1
  while ((rc = (getline line < path)) > 0) {
    cur_line++
    if (line ~ /^[ \t]*(#|$)/ && mode != "jsonfile") continue
    if (line ~ /^@step[ \t]/) {
      if (depth) refuse(where() ": @step only in the tool's own file, never in an @include")
      step = trim(substr(line, 6)) + 0; on = (step == served); continue
    }
    if (!on) continue                                    # another step's part
    if (line !~ /^@/) { cur_text = line; render(); continue }
    d = line; sub(/[ \t].*$/, "", d)
    arg = substr(line, length(d) + 1); sub(/^[ \t]/, "", arg)
    if ((mirror || derive) && d != "@defaults" && d != "@include") continue   # the records alone
    if (d == "@file") { if (!step || step == call) file_op(arg); continue }
    if (d == "@defaults")     { delete tmp; parse_fields(arg, tmp); for (k in tmp) DEF[k] = tmp[k] }
    else if (d == "@include") {
      dir = path; if (!sub(/\/[^\/]*$/, "", dir)) dir = "."
      arg = trim(arg)
      run_file(arg ~ /^\// ? arg : dir "/" arg, depth + 1)
    }
    else if (d == "@trail")   trail_next = decode(arg)
    else if (d == "@cut")     cut_next = 1
    else if (d == "@raw")     printf "%s\n", decode(arg)
    else if (d == "@stderr")  printf "%s\n", decode(arg) > "/dev/stderr"
    else if (d == "@exit")    {
      if (trim(arg) !~ /^[0-9]+$/) refuse(where() ": @exit needs a number")
      json_doc(); fflush(); exit trim(arg) + 0
    }
    else if (d == "@hang")    {
      arg = trim(arg); if (arg == "") arg = 30
      if (arg !~ /^[0-9]+$/) refuse(where() ": @hang takes whole seconds")
      fflush(); system("sleep " arg)
    }
    else refuse(where() ": unknown directive " d)
  }
  if (rc < 0) refuse("cannot read " path)
  close(path)
  cur_file = saved_file; cur_line = saved_line
}

BEGIN {
  tool = ENVIRON["STUB_TOOL"]; mode = ENVIRON["STUB_MODE"]; fmt = ENVIRON["STUB_FMT"]
  mirror = (ENVIRON["STUB_MIRROR"] == "1"); derive = (ENVIRON["STUB_DERIVE"] == "1")
  logf = ENVIRON["SQSTUB_LOG"]
  call = ENVIRON["STUB_CALL"] + 0
  parse_format()
  steps_of(ENVIRON["STUB_FILE"])
  JSONC = ("SQSTUB_JSONC" in ENVIRON) ? ENVIRON["SQSTUB_JSONC"] : "0.17"
  for (i = 1; i < 32; i++) if (i != 8 && i != 9 && i != 10 && i != 12 && i != 13) CTRL[sprintf("%c", i)] = i
  run_file(ENVIRON["STUB_FILE"], 0)
  json_doc()
  exit 0
}
