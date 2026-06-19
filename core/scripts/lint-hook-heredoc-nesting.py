#!/usr/bin/env python3
"""Lint shell scripts for heredocs nested inside command/process substitution.

macOS ships bash 3.2, whose parser mishandles a heredoc opened inside a
`$( ... )` command substitution, a `<( ... )` / `>( ... )` process
substitution, or a `` `...` `` backtick substitution. The body is read past
the substitution and the parser reports a phantom "unexpected EOF while
looking for matching quote" / unterminated-quote error. For a PreToolUse /
PostToolUse hook that means EVERY tool call fails with a hook error.

The fix is always the same: slurp the heredoc into a variable at the top
level (a standalone heredoc, no enclosing substitution) and feed it to the
inner command via an argument, e.g. `python3 -c "$var"`.

This lint flags the dangerous shape directly, so it is caught on any bash
version — including CI runners on bash 5, which do NOT reproduce the 3.2
parse error. `bash -n` alone is therefore not enough.

Usage:
    lint-hook-heredoc-nesting.py FILE [FILE ...]

Exit status 0 = clean, 1 = at least one violation (printed to stderr).
"""

import sys


def find_violations(path):
    """Return a list of (line_no, delimiter) heredocs opened while inside a
    command/process/backtick substitution."""
    with open(path, "r", encoding="utf-8") as handle:
        lines = handle.readlines()

    violations = []
    # Context stack of frame types. Command contexts (where a heredoc operator
    # is meaningful) are: 'top', 'cmdsub', 'procsub', 'backtick'. Non-command
    # frames: 'squote', 'dquote', 'arith'.
    stack = ["top"]
    # Heredoc delimiters whose bodies are still being consumed, in FIFO order
    # (bash fills the first-opened heredoc first). Each entry: (word, strip_tabs).
    active = []

    def in_substitution():
        # A heredoc is dangerous if any enclosing command frame is a
        # substitution (cmdsub/procsub/backtick). Plain quote/arith frames do
        # not by themselves make it dangerous, but a cmdsub *inside* a dquote
        # is still on the stack and counts.
        return any(frame in ("cmdsub", "procsub", "backtick") for frame in stack)

    for idx, raw in enumerate(lines):
        line = raw.rstrip("\n")
        line_no = idx + 1

        # If we are consuming heredoc bodies, this whole physical line is data
        # until it matches the delimiter of the oldest open heredoc.
        if active:
            word, strip_tabs = active[0]
            cmp = line.lstrip("\t") if strip_tabs else line
            if cmp == word:
                active.pop(0)
            continue

        j = 0
        length = len(line)
        while j < length:
            top = stack[-1]
            c = line[j]

            if top == "squote":
                if c == "'":
                    stack.pop()
                j += 1
                continue

            if top == "dquote":
                if c == "\\":
                    j += 2
                    continue
                if c == '"':
                    stack.pop()
                    j += 1
                    continue
                if c == "`":
                    stack.append("backtick")
                    j += 1
                    continue
                if c == "$" and j + 1 < length and line[j + 1] == "(":
                    if j + 2 < length and line[j + 2] == "(":
                        stack.append("arith")
                        j += 3
                        continue
                    stack.append("cmdsub")
                    j += 2
                    continue
                j += 1
                continue

            if top == "arith":
                # Arithmetic context ends at the matching '))'. Track nested
                # parens loosely; no heredoc/quote parsing needed inside.
                if c == ")" and j + 1 < length and line[j + 1] == ")":
                    stack.pop()
                    j += 2
                    continue
                j += 1
                continue

            # Command context: top, cmdsub, procsub, backtick.
            if c == "\\":
                j += 2
                continue
            if c == "#" and (j == 0 or line[j - 1] in " \t"):
                break  # comment to end of line
            if c == "'":
                stack.append("squote")
                j += 1
                continue
            if c == '"':
                stack.append("dquote")
                j += 1
                continue
            if c == "`":
                if top == "backtick":
                    stack.pop()
                else:
                    stack.append("backtick")
                j += 1
                continue
            if c == "$" and j + 1 < length and line[j + 1] == "(":
                if j + 2 < length and line[j + 2] == "(":
                    stack.append("arith")
                    j += 3
                    continue
                stack.append("cmdsub")
                j += 2
                continue
            if c in "<>" and j + 1 < length and line[j + 1] == "(":
                stack.append("procsub")
                j += 2
                continue
            if c == "<" and j + 1 < length and line[j + 1] == "<":
                if j + 2 < length and line[j + 2] == "<":
                    j += 3  # here-string <<<, not a heredoc
                    continue
                k = j + 2
                strip_tabs = False
                if k < length and line[k] == "-":
                    strip_tabs = True
                    k += 1
                while k < length and line[k] in " \t":
                    k += 1
                word = ""
                if k < length and line[k] in ("'", '"'):
                    quote = line[k]
                    k += 1
                    while k < length and line[k] != quote:
                        word += line[k]
                        k += 1
                    k += 1
                else:
                    while k < length and (line[k].isalnum() or line[k] in "_-.+"):
                        word += line[k]
                        k += 1
                if word:
                    if in_substitution():
                        violations.append((line_no, word))
                    active.append((word, strip_tabs))
                j = k
                continue
            if c == "(":
                # plain subshell / grouping; only matters for paren balance
                stack.append("subshell")
                j += 1
                continue
            if c == ")":
                if top in ("cmdsub", "procsub", "subshell"):
                    stack.pop()
                j += 1
                continue
            j += 1

    return violations


def main(argv):
    paths = argv[1:]
    if not paths:
        sys.stderr.write("usage: lint-hook-heredoc-nesting.py FILE [FILE ...]\n")
        return 2
    bad = 0
    for path in paths:
        for line_no, word in find_violations(path):
            bad += 1
            sys.stderr.write(
                "%s:%d: heredoc <<%s opened inside a command/process "
                "substitution; bash 3.2 mis-parses this as an unterminated "
                "quote. Slurp it into a top-level variable and run via "
                'an argument (e.g. python3 -c "$var").\n' % (path, line_no, word)
            )
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
