#!/usr/bin/env python3
"""sq's width table: the columns each code point takes on a terminal (WIDE-v4, W1).

    tests/width_table.py check SQ LOCALE    exit 1 and list the code points where
                                            regenerating would change the table
    tests/width_table.py write SQ LOCALE    regenerate the table in SQ, in place
    tests/width_table.py lookup SQ < WIDTHS the "HEX WIDTH" lines on stdin, one per
                                            scalar value, against the table: exit 1
                                            and list the code points that differ

LOCALE is a UTF-8 locale for glibc's wcwidth (the suite passes its own).

The table in SQ is the source of truth: one list of hex ranges, each of width 0
or 2 (every other code point is 1), between the lines "# ---- the width
table" and "# ---- width table end", with the Unicode version it was made
from and the set of glibcs ("glibc 2.39+2.40").  Regenerating takes, per
code point, the largest of
  - the list as it stands;
  - glibc's wcwidth here, where -1 counts 1;
  - a Unicode rule over python's unicodedata: 0 for Mn, Me, Cf but U+00AD and
    Hangul jamo V/T (U+1160-11FF, U+D7B0-D7FF); else 2 for East Asian W and F
    (unassigned code points that default to W included) and for unassigned
    code points in U+1F000-1FAFF and U+1FC00-1FFFD; else 1.  Only when this
    unicodedata is not older than the version the list records: an older one
    sees code points assigned since as unassigned, so its part is left out and
    said to be;
  - the fixed set: U+FE0F counts 1, the regional indicators U+1F1E6-1F1FF 2
    each, and the nine Emoji_Modifier_Base characters tmux 3.4 draws wide
    (glibc 1, East Asian N) 2.
so a regeneration only widens, and records this glibc beside the ones the
list records.  Exact mode: where the list records this glibc alone and this
unicodedata's version, the list must equal the sources alone (all but the
list itself) exactly, and write makes it so, narrowing a stray entry too.
An empty list (or none) is a first generation from the sources alone.
check fails exactly where write would change something; both say which of
the two they did.
"""
import bisect
import ctypes
import ctypes.util
import re
import sys
import unicodedata

BEGIN = "# ---- the width table"
END = "# ---- width table end"
FIXED = {0xFE0F: 1}
FIXED.update({cp: 2 for cp in range(0x1F1E6, 0x1F200)})
FIXED.update({cp: 2 for cp in (0x261D, 0x26F9, 0x270C, 0x270D, 0x1F3CB, 0x1F3CC, 0x1F574, 0x1F575, 0x1F590)})
SCALARS = [cp for cp in range(0x110000) if not 0xD800 <= cp <= 0xDFFF]


def die(msg):
    print("width_table.py: " + msg, file=sys.stderr)
    sys.exit(2)


def version(text):
    return tuple(int(x) for x in text.split("."))


def read_table(path):
    """(lines of SQ, index of the BEGIN line, index of the END line, recorded Unicode version,
    the set of recorded glibc versions ({"2.39", ...}), {cp: width})"""
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    try:
        b = next(i for i, l in enumerate(lines) if l.startswith(BEGIN))
        e = next(i for i in range(b, len(lines)) if lines[i].startswith(END))
    except StopIteration:
        die("%s: no width table (%r ... %r)" % (path, BEGIN, END))
    m = re.search(r"Unicode ([0-9.]+)", lines[b])
    recorded = m.group(1) if m else None
    m = re.search(r"glibc ([0-9.]+(?:\+[0-9.]+)*)", lines[b])
    recorded_glibcs = set(m.group(1).split("+")) if m else set()
    table = {}
    body = " ".join(re.findall(r'"([^"]*)"', "\n".join(lines[b + 1:e])))
    for item in body.split():
        m = re.fullmatch(r"([0-9A-F]+)(?:-([0-9A-F]+))?:([02])", item)
        if not m:
            die("%s: not a range of the width table: %r" % (path, item))
        lo = int(m.group(1), 16)
        hi = int(m.group(2), 16) if m.group(2) else lo
        for cp in range(lo, hi + 1):
            table[cp] = int(m.group(3))
    return lines, b, e, recorded, recorded_glibcs, table


def glibc_widths(locale):
    libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
    libc.setlocale.restype = ctypes.c_char_p
    libc.setlocale.argtypes = [ctypes.c_int, ctypes.c_char_p]
    if not libc.setlocale(6, locale.encode()):          # LC_ALL
        die("glibc does not know the locale %s" % locale)
    libc.wcwidth.argtypes = [ctypes.c_uint32]
    libc.wcwidth.restype = ctypes.c_int
    try:
        libc.gnu_get_libc_version.restype = ctypes.c_char_p
        name = libc.gnu_get_libc_version().decode()
    except AttributeError:
        die("no glibc here (gnu_get_libc_version): its wcwidth is the table's reference")
    def width(cp):
        w = libc.wcwidth(cp)
        return 1 if w < 0 else w
    return name, width


def unicode_width(cp):
    c = chr(cp)
    g = unicodedata.category(c)
    if g in ("Mn", "Me") or (g == "Cf" and cp != 0xAD) or 0x1160 <= cp <= 0x11FF or 0xD7B0 <= cp <= 0xD7FF:
        return 0
    if unicodedata.east_asian_width(c) in ("W", "F"):
        return 2
    if g == "Cn" and (0x1F000 <= cp <= 0x1FAFF or 0x1FC00 <= cp <= 0x1FFFD):
        return 2
    return 1


def generate(locale, recorded):
    """the table the sources alone make, the glibc's version, and whether the Unicode part took part"""
    glibc, gw = glibc_widths(locale)
    local = unicodedata.unidata_version
    with_unicode = recorded is None or version(local) >= version(recorded)
    new = {}
    for cp in SCALARS:
        w = max(gw(cp), FIXED.get(cp, 0))
        if with_unicode:
            w = max(w, unicode_width(cp))
        if w != 1:
            new[cp] = w
    return new, glibc, with_unicode


def hexlist(widths):
    out, start, prev, pw = [], None, None, None
    for cp in SCALARS + [None]:
        w = widths.get(cp, 1) if cp is not None else None
        if start is not None and (cp is None or w != pw or cp != prev + 1):
            out.append(("%X" % start if start == prev else "%X-%X" % (start, prev)) + ":%d" % pw)
            start = None
        if cp is not None and w != 1 and start is None:
            start, pw = cp, w
        prev = cp
    return out


def table_lines(items, header):
    rows, row = [], ""
    for it in items:
        if row and len(row) + len(it) + 1 > 96:
            rows.append(row)
            row = ""
        row = (row + " " + it) if row else it
    if row:
        rows.append(row)
    body = ["BEGIN {", "  WIDTHS = \\"]
    for i, r in enumerate(rows):
        body.append('    "%s%s"%s' % (r, " " if i < len(rows) - 1 else "", " \\" if i < len(rows) - 1 else ""))
    if not rows:
        body.append('    ""')
    body.append("}")
    return [header] + body


def changes(old, new):
    return [(cp, old.get(cp, 1), new.get(cp, 1)) for cp in SCALARS if old.get(cp, 1) != new.get(cp, 1)]


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("check", "write", "lookup"):
        die("usage: width_table.py check|write SQ LOCALE, or lookup SQ < WIDTHS")
    mode, path = sys.argv[1], sys.argv[2]
    lines, b, e, recorded, recorded_glibcs, table = read_table(path)
    if mode == "lookup":
        seen, bad = set(), []
        for ln in sys.stdin:
            h, w = ln.split()
            cp = int(h, 16)
            seen.add(cp)
            if int(w) != table.get(cp, 1):
                bad.append((cp, int(w), table.get(cp, 1)))
        missing = [cp for cp in SCALARS if cp not in seen]
        for cp, got, want in bad[:40]:
            print("U+%04X: sq %d, the list %d" % (cp, got, want))
        if missing:
            print("%d scalar values not measured, e.g. %s" % (len(missing), " ".join("U+%04X" % c for c in missing[:10])))
        print("%d scalar values measured, %d differ from the list" % (len(seen), len(bad)))
        sys.exit(1 if bad or missing else 0)
    if len(sys.argv) < 4:
        die("%s needs the LOCALE for glibc's wcwidth" % mode)
    locale = sys.argv[3]
    first = not table
    sources, glibc, with_unicode = generate(locale, recorded)
    local = unicodedata.unidata_version
    if not with_unicode:
        print("the Unicode part was not checked: python's unicodedata %s is older than the list's Unicode %s; "
              "checked glibc %s and the fixed set only" % (local, recorded, glibc))
    # exact: the list records these very sources, this unicodedata and this
    # glibc alone, so it must be theirs exactly; else it only widens
    exact = not first and recorded == local and recorded_glibcs == {glibc}
    if first or exact:
        new, glibcs = sources, {glibc}
    else:
        new = {cp: w for cp in set(table) | set(sources) if (w := max(table.get(cp, 1), sources.get(cp, 1))) != 1}
        glibcs = recorded_glibcs | {glibc}
    how = ("a first generation" if first else
           "exact: the list's own versions, so it equals its sources" if exact else
           "widening only: the list records glibc %s and Unicode %s" % ("+".join(sorted(recorded_glibcs, key=version)) or "none", recorded))
    diff = changes(table, new)
    narrowed = sum(1 for _, a, z in diff if z < a)
    if mode == "check":
        for cp, a, z in diff[:200]:
            print("U+%04X: the list %d, regenerated %d" % (cp, a, z))
        if len(diff) > 200:
            print("... %d more" % (len(diff) - 200))
        print("%d code points would change, %d narrowed (glibc %s, unicodedata %s%s; %s)" % (len(diff), narrowed, glibc, local,
              "" if with_unicode else ", not used", how))
        sys.exit(1 if diff else 0)
    made = recorded if (recorded and not with_unicode) else local
    if recorded and version(recorded) > version(made):
        made = recorded
    header = "%s: Unicode %s, glibc %s; tests/width_table.py writes it" % (BEGIN, made, "+".join(sorted(glibcs, key=version)))
    lines[b:e] = table_lines(hexlist(new), header)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("%d code points changed (%d narrowed); %d ranges (%s)" % (len(diff), narrowed, len(hexlist(new)), how))


main()
