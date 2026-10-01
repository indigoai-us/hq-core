# Emit executable source lines while dropping shell comments and here-doc bodies.
# The checker uses this for hybrid validation and for discovering CLI call sites.

function shell_code(line,    result, quote, escaped, i, c, previous) {
  result = ""
  quote = ""
  escaped = 0
  previous = ""
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    if (quote == "single") {
      result = result c
      if (c == "'") quote = ""
      previous = c
      continue
    }
    if (quote == "double") {
      result = result c
      if (escaped) escaped = 0
      else if (c == "\\") escaped = 1
      else if (c == "\"") quote = ""
      previous = c
      continue
    }
    if (escaped) {
      result = result c
      escaped = 0
      previous = c
      continue
    }
    if (c == "\\") {
      result = result c
      escaped = 1
      previous = c
      continue
    }
    if (c == "'") {
      quote = "single"
      result = result c
      previous = c
      continue
    }
    if (c == "\"") {
      quote = "double"
      result = result c
      previous = c
      continue
    }
    if (c == "#" && (i == 1 || previous ~ /[[:space:];|&()]/)) break
    result = result c
    previous = c
  }
  return result
}

function javascript_code(line,    result, i, c, nextc, quote, escaped, keep_string) {
  result = ""
  quote = ""
  escaped = 0
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    nextc = substr(line, i + 1, 1)
    if (js_block_comment) {
      if (c == "*" && nextc == "/") {
        js_block_comment = 0
        i++
      }
      continue
    }
    if (quote != "") {
      if (escaped) {
        if (keep_string) result = result c
        escaped = 0
      } else if (c == "\\") {
        if (keep_string) result = result c
        escaped = 1
      } else if (c == quote) {
        if (keep_string) result = result c
        quote = ""
        keep_string = 0
      } else if (keep_string) result = result c
      continue
    }
    if (c == "'" || c == "\"" || c == "`") {
      quote = c
      # JavaScript diagnostics and documentation are not command invocations.
      # Preserve text only when it is the first argument to a child-process API,
      # where the generic shell-call scan can validate the command string.
      keep_string = result ~ /(^|[^[:alnum:]_$])(exec|execSync|execFile|execFileSync|spawn|spawnSync|fork)[[:space:]]*\([[:space:]]*$/
      if (keep_string) result = result c
      continue
    }
    if (c == "/" && nextc == "/") break
    if (c == "/" && nextc == "*") {
      js_block_comment = 1
      i++
      continue
    }
    result = result c
  }
  return result
}

function queue_here_documents(code,    i, c, nextc, quote, escaped, j, strip_tabs, delimiter, q) {
  quote = ""
  escaped = 0
  for (i = 1; i <= length(code); i++) {
    c = substr(code, i, 1)
    nextc = substr(code, i + 1, 1)
    if (quote != "") {
      if (escaped) escaped = 0
      else if (c == "\\" && quote != "single") escaped = 1
      else if (c == quote) quote = ""
      continue
    }
    if (c == "'" || c == "\"") {
      quote = c
      continue
    }
    if (c == "\\") {
      i++
      continue
    }
    if (c != "<" || nextc != "<" || substr(code, i + 2, 1) == "<" || substr(code, i - 1, 1) == "<") continue

    j = i + 2
    strip_tabs = 0
    if (substr(code, j, 1) == "-") {
      strip_tabs = 1
      j++
    }
    while (substr(code, j, 1) == " " || substr(code, j, 1) == "\t") j++
    delimiter = ""
    q = substr(code, j, 1)
    if (q == "'" || q == "\"") {
      j++
      while (j <= length(code) && substr(code, j, 1) != q) {
        c = substr(code, j, 1)
        if (c == "\\" && q == "\"" && j < length(code)) j++
        delimiter = delimiter substr(code, j, 1)
        j++
      }
      if (substr(code, j, 1) == q) j++
    } else {
      while (j <= length(code)) {
        c = substr(code, j, 1)
        if (c ~ /[[:space:];|&()<>]/) break
        if (c == "\\" && j < length(code)) j++
        delimiter = delimiter substr(code, j, 1)
        j++
      }
    }
    if (delimiter != "") {
      heredoc_count++
      heredoc_delimiter[heredoc_count] = delimiter
      heredoc_strip_tabs[heredoc_count] = strip_tabs
    }
    i = j - 1
  }
}

function has_line_continuation(line,    i, count) {
  count = 0
  for (i = length(line); i > 0 && substr(line, i, 1) == "\\"; i--) count++
  return count % 2 == 1
}

BEGIN {
  if (language == "") language = "shell"
  heredoc_next = 1
}

{
  if (language == "javascript") {
    code = javascript_code($0)
  } else {
    if (heredoc_next <= heredoc_count) {
      body = $0
      if (heredoc_strip_tabs[heredoc_next]) sub(/^\t+/, "", body)
      if (body == heredoc_delimiter[heredoc_next]) heredoc_next++
      next
    }
    code = shell_code($0)
    if (has_line_continuation(code)) {
      logical = logical substr(code, 1, length(code) - 1) " "
      next
    }
    code = logical code
    logical = ""
    queue_here_documents(code)
  }
  if (code ~ /[^[:space:]]/) print code
}

END {
  if (language != "javascript" && logical ~ /[^[:space:]]/) print logical
}
