# json-c's escaping of a string, for the stub's made documents and the
# suite's hostile ones; under LC_ALL=C, so each byte is a character.
# json-c 0.11-0.19 (json_escape_str) put a backslash before a quote, a
# backslash and a slash, write \b \f \n \r \t by letter and any other byte
# below 0x20 as \u00xx, and keep every other byte (0x7f, invalid UTF-8) raw
function jstr(s,   out, i, c) {
  if (!JSTR_INIT++) for (i = 1; i < 32; i++) if (i != 8 && i != 9 && i != 10 && i != 12 && i != 13) CTRL[sprintf("%c", i)] = i
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
