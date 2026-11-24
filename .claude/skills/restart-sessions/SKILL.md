---
name: restart-sessions
description: "Bring Claude desktop sessions over from another Claude account on the same Mac, with groups, presets and connectors. Triggers: \"my sessions are gone after switching accounts\", \"bring my sessions over\", \"get my sessions from the other account\", \"restart my sessions on this account\"."
allowed-tools: Bash, Read, AskUserQuestion, mcp__ccd_session_mgmt__list_sessions, mcp__ccd_sidebar__list_groups, mcp__ccd_sidebar__create_group, mcp__ccd_sidebar__move_sessions, mcp__ccd_connectors__session_connectors_status, mcp__mcp-registry__search_mcp_registry, mcp__mcp-registry__suggest_connectors
---

# Restart Sessions

The Claude desktop app keeps a separate session list for each Claude account
that has signed in on a Mac. After an account switch, the sidebar of the new
account is empty, even though every conversation is still on disk. This skill
copies the session list from the old account into the current one, so the
original conversations open and continue under the new account. It then
rebuilds the sidebar groups, copies saved session presets, and lists the
connectors that need a new sign-in.

Use `/handoff-all` and `/resume-all` instead when the user wants fresh sessions
that restart from a summary, or when the sessions are on another computer. Use
this skill when the user wants the original sessions with their full history.

## Limits

- macOS and the Claude desktop app only. Not tested on Windows or Linux.
- Both accounts must have been signed in on this Mac. Sessions from another
  computer are not on this disk and cannot be brought over this way.
- The storage layout below is not documented by Anthropic and can change in an
  app update. Last verified working on 2026-11-20. If the folders or files do
  not match what is described here, stop and tell the user. Do not guess.
- Copy only. Never move, edit, or delete anything in the old account's folder.
- Session records can contain prompt text. Read and print titles, ids, dates,
  and folder paths only. Never print a whole record.

## How sessions are stored

```
~/Library/Application Support/Claude/claude-code-sessions/
  <account-id>/
    <organization-id>/
      local_<session-id>.json     one record per session
      archived-sessions.idx       {"v":1,"archived":["local_...", ...]}
      scheduled-tasks.json        leave alone
      waiting-input               leave alone
```

Each record has `sessionId`, `title`, `cwd`, `isArchived`, `lastActivityAt`,
and `cliSessionId`. The conversation itself is not in the record. It lives at
`~/.claude/projects/<folder-name>/<cliSessionId>.jsonl`, which is shared by
every account on the Mac. That is why a copied record opens the full
conversation.

## Steps

### 1. Record the sidebar groups first, if you still can

Sidebar groups do not travel with the records. If the user has not switched
accounts yet, call `mcp__ccd_session_mgmt__list_sessions` with a high `limit`
and save each session's `group.name`. If they already switched, the old groups
cannot be read; ask the user for a screenshot of the old sidebar or for the
group names, and file only the sessions you can place with confidence.

### 2. Find the destination and the source

The destination is the `<account-id>/<organization-id>` folder that holds the
record for the session you are running in. Find it by matching `cliSessionId`
to the current session id. If no record matches, stop and ask the user which
account they are signed into now; never guess from `lastActivityAt`.

The source is any other `<account-id>/<organization-id>` folder that contains
`local_*.json` records. If there is more than one, list each with its session
count and newest session title, and ask the user which one to bring over.

List the source sessions (date, open or archived, title) and confirm the count
with the user before copying.

### 3. Copy and verify

Run this with the two folder paths filled in. It never overwrites a file that
already exists in the destination, and it merges the archived list instead of
replacing it.

```bash
python3 -I -c "
import json,glob,os,shutil,hashlib
src='SOURCE_FOLDER'
dst='DESTINATION_FOLDER'
copied=skipped=bad=missing=0
names=[os.path.basename(f) for f in sorted(glob.glob(src+'/local_*.json'))]
for n in names:
    if os.path.exists(dst+'/'+n): skipped+=1; continue
    shutil.copy2(src+'/'+n,dst+'/'+n); copied+=1
si,di=src+'/archived-sessions.idx',dst+'/archived-sessions.idx'
if os.path.exists(si):
    a=json.load(open(si)).get('archived',[])
    if os.path.exists(di):
        cur=json.load(open(di)); cur['archived']=sorted(set(cur.get('archived',[]))|set(a))
        json.dump(cur,open(di,'w'),separators=(',',':'))
    else: shutil.copy2(si,di)
for n in names:
    d=json.load(open(dst+'/'+n))
    if hashlib.sha256(open(src+'/'+n,'rb').read()).digest()!=hashlib.sha256(open(dst+'/'+n,'rb').read()).digest(): bad+=1
    c=d.get('cliSessionId')
    if c and not glob.glob(os.path.expanduser('~/.claude/projects/*/'+c+'.jsonl')): missing+=1; print('no conversation file:',d.get('title'))
print('copied',copied,'already there',skipped,'differ from source',bad,'missing conversation',missing)
"
```

Expected result: `copied` equals the source count on a first run, and
`missing conversation` is 0. `differ from source` counts sessions that were
already in the destination and have since changed there; that is normal on a
second run and those records are left alone. A session reported with no
conversation file will appear in the sidebar but open empty; tell the user
which ones.

### 4. Copy saved session presets

Presets (the saved "new session" setups) are stored per account in
`~/Library/Application Support/Claude/ccd-session-presets.json`, under
`byAccount.<account-id>`. The account ids are the first-level folder names of
the source and destination from step 2. This adds the old account's presets to
the current one and skips any with the same id or name.

```bash
python3 -I -c "
import json,os
f=os.path.join(os.path.expanduser('~'),'Library','Application Support','Claude','ccd-session-presets.json')
p=json.load(open(f)); b=p.setdefault('byAccount',{})
o=b.get('SOURCE_ACCOUNT_ID',{}); n=b.setdefault('DESTINATION_ACCOUNT_ID',{})
n.setdefault('presets',[]); n.setdefault('builtIns',{})
have={x['id'] for x in n['presets']}|{x['name'] for x in n['presets']}
added=[x for x in o.get('presets',[]) if x['id'] not in have and x['name'] not in have]
n['presets'].extend(json.loads(json.dumps(added)))
for k,v in o.get('builtIns',{}).items(): n['builtIns'].setdefault(k,json.loads(json.dumps(v)))
t=f+'.tmp'; json.dump(p,open(t,'w')); os.replace(t,f)
print('presets added:',[x['name'] for x in added])
"
```

Skip this step when the file does not exist. The app may write its own copy of
this file when it quits; if presets are missing after the restart in step 5,
run this again and restart once more.

### 5. Restart the app

The app reads its session list when it starts. Ask the user to quit Claude
completely and reopen it. After they confirm, call
`mcp__ccd_session_mgmt__list_sessions` with `include_archived: true` and check
the count matches.

### 6. Rebuild the sidebar groups

With the group names from step 1, call `mcp__ccd_sidebar__list_groups`, create
any missing group with `mcp__ccd_sidebar__create_group`, then file sessions
with `mcp__ccd_sidebar__move_sessions`. Reuse an existing group with the same
name instead of creating a duplicate. Leave sessions ungrouped when you do not
know where they belong, and tell the user how many.

### 7. Re-add Claude connectors

Claude connectors (Gmail, Slack, Linear and similar) cannot be copied. Their
sign-ins are held by Claude for each account, not on the Mac. Never try to
copy sign-in tokens between accounts.

1. List what the old account had. Each source record has a
   `remoteMcpServersConfig` list; collect the distinct `name` values across all
   source records. Ignore built-ins such as `Claude Docs` and `visualize`.
2. List what the current account has with
   `mcp__ccd_connectors__session_connectors_status`.
3. For each missing one, check `hq integrations list --usable` first. An app
   that is usable through HQ already works on the new account, because HQ
   integrations follow the HQ login. Tell the user it needs no action unless
   they want the Claude version too.
4. For the rest, look each up with `mcp__mcp-registry__search_mcp_registry` and
   show one card with `mcp__mcp-registry__suggest_connectors`. The user clicks
   Connect and signs in. Do not sign in for them.

This is a one-time job per account. Each account keeps its own sign-ins, so
switching back later needs nothing.

## What carries over and what does not

| Item | Result |
|---|---|
| Sessions and conversation history | Copied (step 3) |
| Saved session presets | Copied (step 4) |
| Sidebar groups | Rebuilt by name (step 6) |
| Claude connectors | Re-added by the user, one time per account (step 7) |
| HQ integrations, skills, policies, hooks | Same on every account; they follow the HQ login and the HQ folder |
| Local MCP servers | Same on every account; they are set per Mac |
| Scheduled tasks | Not copied |

## What to tell the user afterward

- The old account still has its own copy. If they continue a session here and
  later switch back, each account shows its own version of that session's
  status. The conversation history is shared.
- Which connectors they still need to sign in to, by name.
- Scheduled tasks are not copied.

## Undo

Delete from the destination folder only the `local_*.json` files whose names
also exist in the source folder, and remove their ids from the destination's
`archived-sessions.idx`. Then restart the app. Confirm with the user before
deleting, and never delete the record of the session you are running in.
