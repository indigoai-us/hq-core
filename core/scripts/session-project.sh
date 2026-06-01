#!/usr/bin/env bash
# session-project.sh - create or reuse a lightweight project folder for native sessions.
#
# This is intentionally thinner than /prd. It gives native Claude/Codex work a
# durable project/prd.json target without forcing a full interview flow.

set -uo pipefail

HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
SESSION_PROJECT_STDIN_INPUT=""
if [ "${1:-}" = "ingest-plan" ]; then
  SESSION_PROJECT_STDIN_INPUT="$(cat 2>/dev/null || true)"
fi
export SESSION_PROJECT_STDIN_INPUT

python3 - "$HQ_ROOT" "$@" <<'PY'
import argparse
import datetime as dt
import json
import os
import pathlib
import re
import sys

HQ_ROOT = pathlib.Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]

STOPWORDS = {
    "about", "after", "again", "almost", "always", "and", "any", "are",
    "basically", "before", "being", "can", "claude", "codex", "create",
    "created", "creating", "default", "does", "doing", "done", "for",
    "from", "have", "how", "into", "mode", "native", "ones", "plan",
    "project", "projects", "session", "sessions", "should", "that",
    "the", "this", "update", "updated", "when", "with", "work", "would",
}


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def today():
    return dt.datetime.now(dt.timezone.utc).date().isoformat()


def slugify(value):
    value = (value or "native-session").lower()
    value = re.sub(r"[^a-z0-9]+", "-", value).strip("-")
    value = re.sub(r"-+", "-", value)
    return (value or "native-session")[:60].strip("-") or "native-session"


# Filler words that should never anchor a project name — approvals,
# pleasantries, pronouns, and instruction scaffolding. Distinct from STOPWORDS
# (which tunes reuse-matching); this set tunes the human-facing slug.
SLUG_FILLER = {
    "ok", "okay", "yes", "yep", "yeah", "ya", "sure", "cool", "nice", "great",
    "good", "perfect", "thanks", "thank", "you", "your", "please", "pls", "go",
    "ahead", "for", "it", "do", "did", "that", "this", "now", "lets", "let",
    "us", "proceed", "continue", "just", "still", "also", "and", "then", "the",
    "a", "an", "to", "with", "up", "on", "in", "of", "both", "all", "sounds",
    "lgtm", "fine", "right", "exactly", "agreed", "next", "keep", "again",
    "more", "im", "i", "we", "should", "can", "could", "would", "want", "need",
    "me", "my", "our", "help", "make", "get", "got", "have", "is", "are", "be",
    "out", "here", "there", "some", "any", "as", "at", "by", "or", "but", "so",
    "from", "into", "about", "please", "kindly", "gonna", "wanna", "like",
}


def topic_slug(text, max_words=5):
    """Build a clean, meaningful project slug: drop filler, keep the first few
    content words. Date-stamp as a last resort so a name is always produced."""
    toks = re.findall(r"[a-z0-9][a-z0-9-]*", (text or "").lower())
    content = [
        t for t in toks
        if t not in SLUG_FILLER and not t.isdigit() and len(t) > 1
    ]
    if not content:
        return f"session-{today()}"
    return slugify("-".join(content[:max_words]))


def words(value):
    return {
        w for w in re.findall(r"[a-z0-9][a-z0-9-]{2,}", (value or "").lower())
        if w not in STOPWORDS
    }


def read_json(path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=True) + "\n")


def project_base(scope, company):
    if scope == "company" and company:
        return HQ_ROOT / "companies" / company / "projects"
    return HQ_ROOT / "personal" / "projects"


def candidate_bases(scope, company):
    # Company isolation: when a company is explicit, only reuse that company's
    # projects. Otherwise use personal/HQ projects as the neutral home.
    return [project_base(scope, company)]


def project_text(prd, path):
    metadata = prd.get("metadata") if isinstance(prd, dict) else {}
    stories = prd.get("userStories") if isinstance(prd, dict) else []
    story_text = " ".join(
        f"{s.get('id', '')} {s.get('title', '')} {s.get('description', '')}"
        for s in stories[:5]
        if isinstance(s, dict)
    )
    return " ".join([
        str(prd.get("name", "")),
        str(prd.get("description", "")),
        str(metadata.get("goal", "")) if isinstance(metadata, dict) else "",
        path.parent.name,
        story_text,
    ])


def find_candidates(scope, company, query, limit=5):
    query_words = words(query)
    if not query_words:
        return []

    candidates = []
    for base in candidate_bases(scope, company):
        if not base.exists():
            continue
        for child in sorted(base.iterdir()):
            prd_path = child / "prd.json"
            if not prd_path.is_file():
                continue
            prd = read_json(prd_path)
            if not isinstance(prd, dict):
                continue
            haystack = project_text(prd, prd_path)
            hay_words = words(haystack)
            overlap = sorted(query_words & hay_words)
            slug_hits = [w for w in query_words if w in child.name.lower()]
            score = len(overlap) + len(slug_hits)
            if score == 0:
                continue
            candidates.append({
                "path": str(prd_path.relative_to(HQ_ROOT)),
                "projectDir": str(child.relative_to(HQ_ROOT)),
                "name": prd.get("name") or child.name,
                "score": score,
                "overlap": overlap[:12],
            })

    candidates.sort(key=lambda c: (-c["score"], c["path"]))
    return candidates[:limit]


def load_or_create_prd(project_dir, title, scope, company, prompt, origin, repo_path):
    prd_path = project_dir / "prd.json"
    if prd_path.exists():
        prd = read_json(prd_path)
        return prd if isinstance(prd, dict) else {}

    slug = project_dir.name
    description = prompt or title
    prd = {
        "name": slug,
        "description": description,
        "branchName": "main",
        "metadata": {
            "origin": "native-session",
            "scope": scope,
            "company": company or "personal",
            "createdAt": now_iso(),
            "goal": title,
            "repoPath": repo_path,
            "status": "active",
            "executionMode": "native",
            "source": origin,
            "nativeSessions": [],
            "nativePlans": [],
        },
        "userStories": [
            {
                "id": "US-001",
                "title": title,
                "description": description,
                "acceptanceCriteria": [],
                "e2eTests": [],
                "priority": 1,
                "passes": False,
                "files": [],
                "labels": ["native-session"],
                "dependsOn": [],
                "notes": "Created automatically from a native Claude/Codex session. Enrich with /prd or /plan if this becomes a structured project.",
                "model_hint": "",
            }
        ],
    }
    return prd


def append_session(prd, session_id, prompt, reused):
    metadata = prd.setdefault("metadata", {})
    sessions = metadata.setdefault("nativeSessions", [])
    entry = {
        "ts": now_iso(),
        "sessionId": session_id or "unknown",
        "prompt": (prompt or "")[:1000],
        "reused": bool(reused),
    }
    if not sessions or sessions[-1] != entry:
        sessions.append(entry)
    metadata["updatedAt"] = entry["ts"]


def write_readme(project_dir, prd):
    readme = project_dir / "README.md"
    if readme.exists():
        return
    name = prd.get("name", project_dir.name)
    description = prd.get("description", "")
    readme.write_text(
        f"# {name}\n\n"
        f"{description}\n\n"
        "## Status\n\n"
        "Native session project. This folder was created automatically so work "
        "done outside `/prd` and `/run-project` still has a durable home.\n\n"
        "## Next\n\n"
        "- Enrich `prd.json` if this becomes structured execution work.\n"
        "- Keep session notes in `journal/` or `sessions/`.\n"
    )


def set_active_pointer(project_dir):
    state = HQ_ROOT / ".claude" / "state"
    state.mkdir(parents=True, exist_ok=True)
    (state / "active-session-project").write_text(str(project_dir) + "\n")


def ensure_project(args):
    query = " ".join([args.title or "", args.prompt or ""]).strip()
    reuse = None
    if not args.force_new:
        candidates = find_candidates(args.scope, args.company, query, limit=3)
        if candidates and candidates[0]["score"] >= args.reuse_threshold:
            reuse = candidates[0]

    if reuse:
        project_dir = HQ_ROOT / reuse["projectDir"]
        reused = True
    else:
        base = project_base(args.scope, args.company)
        slug = slugify(args.slug) if args.slug else topic_slug(args.title or args.prompt)
        project_dir = base / slug
        suffix = 2
        while project_dir.exists() and not (project_dir / "prd.json").exists():
            project_dir = base / f"{slug}-{suffix}"
            suffix += 1
        reused = False

    project_dir.mkdir(parents=True, exist_ok=True)
    (project_dir / "journal").mkdir(exist_ok=True)
    (project_dir / "sessions").mkdir(exist_ok=True)

    prd = load_or_create_prd(
        project_dir, args.title, args.scope, args.company, args.prompt,
        args.origin, args.repo_path,
    )
    append_session(prd, args.session_id, args.prompt, reused)
    write_json(project_dir / "prd.json", prd)
    write_readme(project_dir, prd)
    set_active_pointer(project_dir)

    session_file = project_dir / "sessions" / f"{now_iso().replace(':', '').replace('-', '')}-{args.session_id or 'session'}.json"
    write_json(session_file, {
        "ts": now_iso(),
        "kind": "native-session-start",
        "prompt": args.prompt,
        "reused": reused,
        "projectDir": str(project_dir.relative_to(HQ_ROOT)),
    })

    print(json.dumps({
        "projectDir": str(project_dir.relative_to(HQ_ROOT)),
        "prdPath": str((project_dir / "prd.json").relative_to(HQ_ROOT)),
        "reused": reused,
        "match": reuse,
    }, indent=2))


def ingest_plan(args):
    pointer = HQ_ROOT / ".claude" / "state" / "active-session-project"
    if args.project:
        project_dir = HQ_ROOT / args.project
    elif pointer.exists():
        project_dir = pathlib.Path(pointer.read_text().strip())
    else:
        raise SystemExit("session-project: no active project; run ensure first")

    if not project_dir.is_absolute():
        project_dir = HQ_ROOT / project_dir
    prd_path = project_dir / "prd.json"
    prd = read_json(prd_path) or {}

    if args.plan_file:
        body = pathlib.Path(args.plan_file).read_text()
    else:
        body = os.environ.get("SESSION_PROJECT_STDIN_INPUT", "")
    body = body.strip()
    if not body:
        raise SystemExit(0)

    plans_dir = project_dir / "sessions"
    plans_dir.mkdir(parents=True, exist_ok=True)
    plan_path = plans_dir / f"{now_iso().replace(':', '').replace('-', '')}-native-plan.md"
    plan_path.write_text(body + "\n")

    metadata = prd.setdefault("metadata", {})
    native_plans = metadata.setdefault("nativePlans", [])
    native_plans.append({
        "ts": now_iso(),
        "path": str(plan_path.relative_to(HQ_ROOT)),
        "summary": body[:500],
        "source": args.source,
    })
    metadata["updatedAt"] = now_iso()
    write_json(prd_path, prd)
    print(str(plan_path.relative_to(HQ_ROOT)))


def append_event(args):
    pointer = HQ_ROOT / ".claude" / "state" / "active-session-project"
    if args.project:
        project_dir = HQ_ROOT / args.project
    elif pointer.exists():
        project_dir = pathlib.Path(pointer.read_text().strip())
    else:
        raise SystemExit(0)
    if not project_dir.is_absolute():
        project_dir = HQ_ROOT / project_dir
    prd_path = project_dir / "prd.json"
    prd = read_json(prd_path) or {}
    metadata = prd.setdefault("metadata", {})
    events = metadata.setdefault("nativeEvents", [])
    events.append({"ts": now_iso(), "kind": args.kind, "summary": args.summary})
    metadata["updatedAt"] = now_iso()
    write_json(prd_path, prd)
    print(str(prd_path.relative_to(HQ_ROOT)))


parser = argparse.ArgumentParser(prog="session-project.sh")
sub = parser.add_subparsers(dest="cmd", required=True)

p_find = sub.add_parser("find")
p_find.add_argument("--scope", default="personal", choices=["personal", "hq-core", "company", "repo"])
p_find.add_argument("--company", default="")
p_find.add_argument("--query", required=True)
p_find.add_argument("--limit", type=int, default=5)

p_ensure = sub.add_parser("ensure")
p_ensure.add_argument("--scope", default="personal", choices=["personal", "hq-core", "company", "repo"])
p_ensure.add_argument("--company", default="")
p_ensure.add_argument("--title", required=True)
p_ensure.add_argument("--prompt", default="")
p_ensure.add_argument("--slug", default="")
p_ensure.add_argument("--repo-path", default="")
p_ensure.add_argument("--session-id", default="")
p_ensure.add_argument("--origin", default="native-session")
p_ensure.add_argument("--reuse-threshold", type=int, default=2)
p_ensure.add_argument("--force-new", action="store_true")

p_ingest = sub.add_parser("ingest-plan")
p_ingest.add_argument("--project", default="")
p_ingest.add_argument("--plan-file", default="")
p_ingest.add_argument("--source", default="native-plan")

p_event = sub.add_parser("append-event")
p_event.add_argument("--project", default="")
p_event.add_argument("--kind", required=True)
p_event.add_argument("--summary", required=True)

args = parser.parse_args(ARGS)

if args.cmd == "find":
    print(json.dumps(find_candidates(args.scope, args.company, args.query, args.limit), indent=2))
elif args.cmd == "ensure":
    ensure_project(args)
elif args.cmd == "ingest-plan":
    ingest_plan(args)
elif args.cmd == "append-event":
    append_event(args)
PY
