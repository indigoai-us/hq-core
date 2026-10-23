#!/usr/bin/env bash
# Pins the super-conductor owner-decision contract: everything that needs the
# owner reaches them as a /decision-queue picker (one picker per item,
# recommended option first), never as a prose question, a "tell me your picks"
# table, a "still to come" list, a bare ad hoc AskUserQuestion, or a decision
# card. Status-only updates stay short prose. /decision-queue must support what
# the conductor needs: a queue of one or more items, draft previews, and
# relaying each answer back before the next picker.
set -euo pipefail

ROOT="${HQ_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
SC="$ROOT/.claude/skills/super-conductor/SKILL.md"
DQ="$ROOT/.claude/skills/decision-queue/SKILL.md"

python3 - "$SC" "$DQ" <<'PY'
import re
import sys
from pathlib import Path

sc_path, dq_path = (Path(p) for p in sys.argv[1:3])
fails = []


def body(path):
    text = path.read_text(encoding="utf-8")
    # Drop YAML frontmatter: allowed-tools legitimately lists AskUserQuestion.
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return text[end + 5 :]
    return text


def need(text, pattern, msg, path):
    if not re.search(pattern, text, re.M | re.S):
        fails.append(f"FAIL: {msg} ({path})")


def forbid(text, pattern, msg, path):
    m = re.search(pattern, text, re.M | re.I)
    if m:
        line = text[: m.start()].count("\n") + 1
        fails.append(f"FAIL: {msg} ({path}, body line {line}: {m.group(0)!r})")


sc = body(sc_path)
dq = body(dq_path)

# --- super-conductor: /decision-queue is the only owner-facing ask path ---
need(sc, r"The decision queue \(`workspace/reports/conduct/<link>-decisions.jsonl`", "names the decision queue as the only ask path", sc_path)
need(sc, r"the `/decision-desk` session \(Step 2b\) is the only\s+place a picker opens", "names the decision desk as the only picker surface", sc_path)
need(sc, r"This session never calls `AskUserQuestion` for an owner decision", "the conductor opens no owner picker itself", sc_path)
need(sc, r"open-asks.mjs check", "checks the source window before queueing or relaying an ask", sc_path)
need(sc, r"Never end a turn with a question to the owner in prose",
     "forbids ending a turn with a prose owner question", sc_path)
for kind in ("merges", "sends", "replies", "product choices", r"picks between\s+options",
             "approvals", "unblocks"):
    need(sc, kind, f"lists '{kind}' as a decision-queue item", sc_path)
need(sc, r"one picker per row", "one picker per row", sc_path)
need(sc, r"recommended option first", "recommended option first", sc_path)
need(sc, r"Status-only updates", "status-only updates stay prose", sc_path)
need(sc, r"tell me your picks", "names the 'tell me your picks' failure", sc_path)
need(sc, r"still to come", "names the 'still to come' list failure", sc_path)
need(sc, r"preview", "drafts and options are shown as picker previews", sc_path)
need(sc, r"Relay(ing)? (every|each) answer", "answers are relayed back to the owning child", sc_path)

# Loopholes that let the model drift away from the picker.
forbid(sc, r"ask one per turn", "allows asking one decision per turn then ending with the rest unasked", sc_path)
forbid(sc, r"decision cards?\b", "allows decision cards as an alternative to /decision-queue", sc_path)
forbid(sc, r"^### Decision card", "keeps a Decision card section", sc_path)
forbid(sc, r"instead of a bare `AskUserQuestion`", "allows a bare AskUserQuestion path", sc_path)
forbid(sc, r"Fall back to `AskUserQuestion`", "allows an ad hoc AskUserQuestion fallback", sc_path)

# Every body mention of AskUserQuestion must route through /decision-queue or forbid ad hoc use.
# Exempt: the Sources list, which reads a child window's open AskUserQuestion from its transcript.
for n, line in enumerate(sc.splitlines(), 1):
    if "child window" in line or "tool_use" in line:
        continue
    if "AskUserQuestion" in line and "/decision-queue" not in line and not re.search(r"\b[Nn]ever\b", line):
        fails.append(f"FAIL: AskUserQuestion mentioned outside /decision-queue ({sc_path}, body line {n}: {line.strip()!r})")

# --- decision-queue: supports what the conductor needs ---
forbid(dq, r"If only \*\*one\*\* decision is in scope, don't invoke",
       "refuses a one-item queue unconditionally (the conductor sends single items)", dq_path)
need(dq, r"/super-conductor", "documents the conductor caller", dq_path)
need(dq, r"preview", "supports draft previews on options", dq_path)
need(dq, r"[Rr]elay", "relays each answer back before the next picker", dq_path)
need(dq, r"[Nn]ever end the turn on the header", "header is never shown without its first picker", dq_path)

if fails:
    print("\n".join(fails), file=sys.stderr)
    raise SystemExit(1)
print("super-conductor decision-queue contract: ok")
PY
