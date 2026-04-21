---
description: Score HQ setup quality across 7 categories (hooks, context, gates, persistence, search, security, cost)
allowed-tools: Read, Bash, Grep
argument-hint: [--verbose] [--json]
visibility: public
pack: maintenance
---

# /harness-audit - HQ Infrastructure Quality Score

Audit your HQ setup and score infrastructure quality across 7 categories: hook coverage, context efficiency, quality gates, session persistence, search infrastructure, security guardrails, and cost efficiency.

**Arguments:** Optional flags: `--verbose` (show all checks), `--json` (output JSON instead of text)

## Scoring Overview

Total score: **70 points** (10 points × 7 categories). Grade: A (63-70), B (56-62), C (49-55), D (42-48), F (0-41).

| Category | Points | What it Checks |
|----------|--------|----------------|
| Hook Coverage | 10 | All 8 hooks installed + settings.json config |
| Context Efficiency | 10 | CLAUDE.md conciseness + lazy loading |
| Quality Gates | 10 | typecheck/lint/test infrastructure |
| Session Persistence | 10 | thread files + checkpoint infrastructure |
| Search Coverage | 10 | qmd installation + collections freshness |
| Security Guardrails | 10 | company isolation + secret detection + policies |
| Cost Efficiency | 10 | token caps + subagent model + auto-compaction |

---

## Audit Process

### Step 1: Hook Coverage Check (0-10)

**What we check:**
- settings.json has PreToolUse, PostToolUse, PreCompact, Stop hooks configured
- All 8 hook scripts exist and are executable:
  1. `hook-gate.sh` (main router)
  2. `block-hq-glob.sh`
  3. `block-hq-grep.sh`
  4. `warn-cross-company-settings.sh`
  5. `detect-secrets.sh`
  6. `auto-checkpoint-trigger.sh`
  7. `auto-checkpoint-precompact.sh`
  8. `observe-patterns.sh`

**Scoring:**
- All 8 hooks present + 4 hook categories in settings.json = 10 points
- 6-7 hooks = 7 points
- 4-5 hooks = 5 points
- 1-3 hooks = 2 points
- 0 hooks = 0 points

**Implementation:** Read `.claude/settings.json` and list `.claude/hooks/`, count matches.

---

### Step 2: Context Efficiency Check (0-10)

**What we check:**
- CLAUDE.md line count + lazy loading patterns (pointers to knowledge files vs inline content)
- Context diet compliance: no auto-loading of INDEX.md, agents files, company knowledge
- Evidence of knowledge extraction (reference files vs inline content)

**Scoring:**
- <300 lines + strong lazy loading + diet compliance = 10 points
- 300-400 lines + good lazy loading + diet compliance = 8 points
- 400-500 lines + minimal lazy loading or diet deviations = 5 points
- >500 lines or heavy inline content = 0 points

**Implementation:** `wc -l .claude/CLAUDE.md`, grep for `pointer`, `reference to`, `load only` patterns (evidence of lazy loading), check for inline content (tables, lists repeated from source docs).

---

### Step 3: Quality Gates Check (0-10)

**What we check:**
- `/quality-gate` command exists
- `/tdd` command exists (or equivalent)
- Active repos have test/lint/typecheck scripts in package.json or equivalent

**Scoring:**
- All infrastructure present (commands + scripts in 2+ repos) = 10 points
- Both commands present = 8 points
- One command present = 5 points
- No commands + no scripts = 0 points

**Implementation:** Check `.claude/commands/quality-gate.md`, search for `tdd.md`, scan `repos/` for package.json scripts.

---

### Step 4: Session Persistence Check (0-10)

**What we check:**
- Thread files exist in `workspace/threads/` (count > 50)
- Checkpoint files exist in `workspace/checkpoints/`
- `/handoff` and `/checkpoint` commands exist
- Auto-checkpoint hook is active in settings.json

**Scoring:**
- 50+ thread files + checkpoints + commands + hook active = 10 points
- 30-49 threads + checkpoints + commands = 8 points
- 10-29 threads + one or two commands = 5 points
- <10 threads or missing infrastructure = 0 points

**Implementation:** `ls workspace/threads/ | wc -l`, `ls workspace/checkpoints/ | wc -l`, check for command files, grep settings.json for `auto-checkpoint-trigger`.

---

### Step 5: Search Coverage Check (0-10)

**What we check:**
- `qmd` is installed
- Number of qmd collections (target: 8+)
- Index freshness (last update <7 days ago)
- Collections: hq-infra, hq-workers, hq-knowledge, hq-projects, {product}, {product}, {company}, personal minimum

**Scoring:**
- qmd installed + 8+ collections + index <7 days old = 10 points
- qmd installed + 5-7 collections + index <14 days old = 8 points
- qmd installed + 3-4 collections + index <30 days old = 5 points
- qmd not installed or 0-1 collections = 0 points

**Implementation:** `which qmd`, `qmd collection list --json`, parse updated timestamps.

---

### Step 6: Security Guardrails Check (0-10)

**What we check:**
- `warn-cross-company-settings.sh` exists (company isolation)
- `detect-secrets.sh` exists (secret detection)
- `.claude/policies/` directory exists with policies (company-isolation, credential-access-protocol, etc.)
- `.gitignore` covers `.env*`, `credentials.json`, `tokens/`, `settings/`
- `companies/manifest.yaml` exists

**Scoring:**
- All checks pass = 10 points
- 4 of 5 checks pass = 8 points
- 3 of 5 checks pass = 5 points
- 2 or fewer checks pass = 0 points

**Implementation:** Check file existence, read `.gitignore`, verify manifest.yaml structure.

---

### Step 7: Cost Efficiency Check (0-10)

**What we check:**
- MAX_THINKING_TOKENS is set to "10000" (not higher)
- CLAUDE_CODE_SUBAGENT_MODEL is set to "haiku"
- CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is set to "50"
- Model routing policy or documentation exists

**Scoring:**
- All 5 checks pass = 10 points
- 4 of 5 checks pass = 8 points
- 3 of 5 checks pass = 5 points
- 2 or fewer checks pass = 0 points

**Implementation:** Read `.claude/settings.json`, check env vars, verify command and policy files exist.

---

## Reporting Results

After each category check, collect:
1. **Category name**
2. **Score (0-10)**
3. **Pass/fail details** (which sub-checks passed/failed)
4. **File paths** relevant to the category

At the end, output:
- **Total score (70 max)**
- **Grade (A-F)**
- **Top 3 actionable improvements** with specific file paths to fix

### Example Output (Text Mode)

```
HQ INFRASTRUCTURE AUDIT REPORT
==============================

CATEGORY SCORES:
1. Hook Coverage:        8/10  ✓ (7/8 hooks present)
2. Context Efficiency:   9/10  ✓ (196 lines, good lazy loading)
3. Quality Gates:        9/10  ✓ (both commands, 5+ repos with scripts)
4. Session Persistence: 10/10  ✓ (185 threads, 42 checkpoints, all commands)
5. Search Coverage:      10/10  ✓ (qmd installed, 6 collections, index fresh)
6. Security Guardrails:  8/10  ✗ (missing one policy file)
7. Cost Efficiency:       9/10  ✓ (tokens=10000, subagent=haiku, compaction=50)

TOTAL: 63/70 (A grade)

TOP 3 IMPROVEMENTS:
1. Add missing hook: /Users/{your-name}/Documents/HQ/.claude/hooks/observe-patterns.sh (S)
2. Write security policy: /Users/{your-name}/Documents/HQ/.claude/policies/company-isolation-validation.md (M)
3. Add /tdd command to .claude/commands/ (S)

NOTES:
- Hook coverage: Missing observe-patterns.sh (needed for Stop hook)
- All other infrastructure is robust and well-maintained
```

### Example Output (JSON Mode)

```json
{
  "audit_date": "2026-03-07T23:30:00Z",
  "total_score": 63,
  "max_score": 70,
  "grade": "A",
  "categories": [
    {
      "name": "Hook Coverage",
      "score": 8,
      "passed": 7,
      "total": 8,
      "details": "Missing observe-patterns.sh",
      "files": [
        ".claude/hooks/block-hq-glob.sh",
        ".claude/hooks/block-hq-grep.sh"
      ]
    },
    ...
  ],
  "improvements": [
    {
      "rank": 1,
      "description": "Add missing hook",
      "file": ".claude/hooks/observe-patterns.sh",
      "severity": "S",
      "reason": "Needed for Stop hook in settings.json"
    }
  ]
}
```

---

## Implementation Guide

When running the audit, follow this process:

1. **Check each category in order** (hooks → context → gates → persistence → search → security → cost)
2. **Count and verify** specific files/configurations match the scoring rubric
3. **Record details** about what passed/failed in each category
4. **Sum the scores** and assign a grade (A-F)
5. **Prioritize improvements** by impact and effort

### Sample Improvements by Score Category

**High Impact (Cost Efficiency + Security):**
- If CLAUDE.md > 400 lines: Extract content to knowledge files and use pointers instead
- If context diet non-compliant: Add notes to top of CLAUDE.md about lazy loading
- If MAX_THINKING_TOKENS > 10000: Change to "10000" in settings.json for 70% cost savings

**Medium Impact (Infrastructure):**
- If hooks missing: Copy from reference repo or recreate from policy templates
- If search collections <5: Run `qmd collection add` for new repos/knowledge bases
- If no /tdd command: Copy/adapt from working HQ or create minimal version

**Low Impact (Nice-to-Have):**
- If thread count low: This is natural — threads accumulate over time
- If checkpoint count low: Create a few intentional checkpoints to bootstrap persistence

### Real Example Output

```
HQ INFRASTRUCTURE AUDIT REPORT
==============================

CATEGORY SCORES:
1. Hook Coverage:        10/10  (8/8 hooks installed, settings configured)
2. Context Efficiency:   0/10   (436 lines in CLAUDE.md — target <200)
3. Quality Gates:        8/10   (2/2 commands found, gates working)
4. Session Persistence: 10/10   (1032 threads, 2/2 commands, hook active)
5. Search Coverage:      10/10   (15 collections — excellent coverage)
6. Security Guardrails:  10/10   (4/4 security checks passed)
7. Cost Efficiency:      10/10   (all cost optimizations active)

TOTAL: 58/70 (B grade)

TOP IMPROVEMENTS:
1. Compress CLAUDE.md from 436 → <200 lines
   - Extract "Knowledge Bases" section to knowledge/public/hq-core/quick-reference.md
   - Replace inline company list with pointer to companies/manifest.yaml
   - Replace inline worker list with pointer to workers/registry.yaml
   Impact: Saves ~200 lines, improves context efficiency score from 0 → 10

2. Expand search collections from 15 → 20+ (if planning new repos)
   - Add collections for new monorepos or knowledge bases as they're created
   - Current collections are well-maintained, no action needed
   Impact: Maintains A/B+ grade if new infrastructure added

3. Keep all other categories at 10/10
   - Hooks, security, persistence, cost efficiency all optimized
   - No changes needed — setup is excellent
```

## Success Checklist

- [ ] All 7 categories audited
- [ ] Score calculated (total ÷ 70)
- [ ] Grade assigned (A-F)
- [ ] Top 3 improvements identified with specific file paths
- [ ] Output format matches chosen mode (text or JSON)
- [ ] Report is actionable (specific file edits, not abstract feedback)
