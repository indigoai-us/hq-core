export const meta = {
  name: 'orchestrate-pipeline',
  description: 'One-run idea -> brainstorm -> PRD -> executed deliverable; continuous by default, human gates opt-in',
  phases: [
    { title: 'Capture', detail: 'board entry for the idea' },
    { title: 'Brainstorm', detail: 'research + premise check + approaches -> brainstorm.md' },
    { title: 'Decide', detail: 'approach: auto-take recommended (default) or human gate (--gated)' },
    { title: 'PRD', detail: 'prd.json + README from the chosen approach' },
    { title: 'Resolve', detail: 'open questions: auto-decide/defer (default) or human gates (--gated)' },
    { title: 'Execute', detail: 'run the stories in order, one agent each, until delivered or blocked' },
  ],
}

// args contract (all strings unless noted):
//   company      REQUIRED  company slug from companies/manifest.yaml, or "personal"
//   description  REQUIRED  the idea, 1-3 sentences
//   engine       optional  "codex" (default), "grok", or "claude" — which agent CLI runs the stages
//   boardId      optional  existing board idea id ({prefix}-proj-NNN) to expand
//   direction    optional  speed | quality | exploration | cost  (interview answer)
//   constraints  optional  free text (timeline, must-use tech, budget)
//   planOnly     optional  boolean, default false. True: stop at the
//                execution-ready PRD (the pre-full-arc behavior) and skip the
//                Execute phase entirely.
//   gated        optional  boolean, default false. False (default): the run never
//                pauses — every decision point takes the recommended option and
//                records it in the decision ledger (decidedBy "auto
//                (recommended)"), and open questions WITHOUT a recommendation
//                defer to pre-flight investigation stories. True: decision
//                points pause as human gates (the launching session relays
//                them), per the workflow-gates spec.
//   maxQuestionGates optional number, cap on open-question gates when gated
//                (default 6). Ignored in continuous mode.
//
// Continuous mode never auto-parks: a WEAK premise is logged loudly and the
// run continues — stopping the work is a human call, so it is the one
// recommendation the pipeline refuses to take on its own. Gate ids (gated
// mode) are scoped by the project slug per
// core/knowledge/public/hq-core/workflow-gates-spec.md, so answers never
// collide across projects and a crashed re-run sails through prior decisions.

const co = args?.company
const description = args?.description
if (!co || !description) {
  throw new Error('ideate-pipeline needs args {company, description} — got ' + JSON.stringify(args))
}
const engine = args?.engine || 'codex'
if (engine !== 'codex' && engine !== 'grok' && engine !== 'claude') {
  throw new Error('ideate-pipeline args.engine must be "codex", "grok", or "claude" — got ' + JSON.stringify(engine))
}
const direction = args?.direction || ''
const constraints = args?.constraints || ''
const gated = args?.gated === true || args?.gated === 'true'
const planOnly = args?.planOnly === true || args?.planOnly === 'true'
const maxQuestionGates = Number(args?.maxQuestionGates) > 0 ? Number(args.maxQuestionGates) : 6

// Decision seam: one function, two modes. Gated -> a real human gate (pause,
// durable answer). Continuous -> take the recommended option (or the first
// one), log it, and keep going; the choice lands in the same decision ledger
// a human answer would, so the PRD records WHO decided either way.
const decide = async (id, question, opts) => {
  if (gated) return gate(id, question, opts)
  const labels = (opts.options || []).map((o) => (typeof o === 'string' ? o : o.label))
  const choice = opts.recommended && labels.includes(opts.recommended)
    ? opts.recommended
    : (opts.recommended || labels[0])
  if (choice === undefined) throw new Error(`continuous mode has no option to take for "${id}"`)
  log(`auto-decided ${id}: ${choice} (recommended)`)
  return { choice, decidedBy: 'auto (recommended)', auto: true }
}

// Every stage agent executes the SHIPPED skill file for its stage instead of
// re-implementing it, so the pipeline stays in lockstep with /idea,
// /brainstorm, and the PRD skill. Stages run non-interactively: session-coupled
// steps (interviews, journal pointers, background pulse spawns, deck deploys,
// auto-checkpoint thread files) are skipped — the launching session owns those.
const NONINTERACTIVE = `
Run non-interactively; you have no user to ask. Skip any step that requires a
live user, a session journal pointer, a background sub-agent spawn, a visual
deck deploy, or an auto-checkpoint thread file — the launching session handles
those.

TOOL RULES — breaking these ends your run, they are not advice:
- NEVER call a glob / file-search / codebase-search tool at the repo root. HQ
  hard-denies it (the root fans out to ~1.38M files through symlinked repos),
  and after a few denials your run is cancelled with nothing returned.
- To find files, use a SHELL command with an explicit scoped path, e.g.
  \`ls companies/\${co}/projects\` or \`rg --files companies/\${co} | head -50\`.
  If you must glob, scope it to a subdirectory, never '.' or the root.
- To search content, use qmd: \`qmd query "<terms>" --json -n 10\` (add
  \`-c <collection>\` when the company has one). Never substitute a root glob.
- If ANY tool call comes back denied, do not retry it and do not stop: switch
  to a scoped shell command and carry on to your deliverable.

Company isolation applies: read and write only under this company's scope (or
personal/ for the personal scope). Do not run git commands; HQ-local writes
autosave.`

phase('Capture')
const capture = await agent(`
Read .claude/skills/idea/SKILL.md and execute its board-entry flow for:
  company: ${co}
  description: ${JSON.stringify(description)}
  ${args?.boardId ? `existing board id (skip creation, just return it): ${args.boardId}` : ''}
All information you need is provided above, so use the skill's inline mode —
zero questions. If the company has no board.json yet, create a fresh one per
the skill. ${NONINTERACTIVE}
Return ONLY JSON: {"boardId": "<id>", "title": "<concise title>"}`,
  { engine, tier: 'exec', label: 'capture-idea', phase: 'Capture', timeoutSecs: 600,
    schema: { type: 'object', required: ['boardId', 'title'],
      properties: { boardId: { type: 'string' }, title: { type: 'string' } } } })

phase('Brainstorm')
const brainstorm = await agent(`
Read .claude/skills/brainstorm/SKILL.md and execute it end to end for company
"${co}", expanding board idea ${capture.boardId} ("${capture.title}"):
  description: ${JSON.stringify(description)}
  direction preference: ${direction || 'none stated'}
  hard constraints: ${constraints || 'none stated'}
Do the full HQ research (qmd, existing projects, workers, policies), the
premise challenge with an honest STRONG/QUESTIONABLE/WEAK verdict, and write
brainstorm.md plus the board update exactly as the skill specifies. Treat the
direction/constraints above as the Step 3 interview answers — do not invent
others. Layer-3 live web research is out of scope. ${NONINTERACTIVE}
Return ONLY JSON with: slug (the project slug you derived), premiseVerdict
(STRONG|QUESTIONABLE|WEAK), premiseSummary (1-2 sentences), approaches (array
of {name, effort, summary, whenToChoose}), recommended (the name of the
approach you recommend), biggestRisk (1 sentence).`,
  { engine, tier: 'plan', label: 'brainstorm', phase: 'Brainstorm', timeoutSecs: 1800,
    schema: { type: 'object',
      required: ['slug', 'premiseVerdict', 'premiseSummary', 'approaches', 'recommended', 'biggestRisk'],
      properties: {
        slug: { type: 'string' },
        premiseVerdict: { type: 'string', enum: ['STRONG', 'QUESTIONABLE', 'WEAK'] },
        premiseSummary: { type: 'string' },
        approaches: { type: 'array', items: { type: 'object',
          required: ['name', 'effort', 'summary'],
          properties: { name: { type: 'string' }, effort: { type: 'string' },
            summary: { type: 'string' }, whenToChoose: { type: 'string' } } } },
        recommended: { type: 'string' },
        biggestRisk: { type: 'string' },
      } } })

const slug = brainstorm.slug

phase('Decide')
if (brainstorm.premiseVerdict === 'WEAK') {
  if (gated) {
    const premise = await gate(`${slug}-premise`,
      `Premise check came back WEAK: ${brainstorm.premiseSummary} Continue to a PRD anyway?`, {
        options: [
          { label: 'continue', description: 'Proceed to approach selection and a PRD' },
          { label: 'park', description: 'Stop here — keep the brainstorm on the board as "exploring"' },
        ],
        context: `Idea: ${capture.title}. Biggest risk: ${brainstorm.biggestRisk}`,
        recommended: 'park',
      })
    if (premise.choice === 'park') {
      log(`parked at premise gate — brainstorm.md stands, no PRD`)
      return { status: 'parked', boardId: capture.boardId, slug,
        brainstorm: { verdict: brainstorm.premiseVerdict, recommended: brainstorm.recommended } }
    }
  } else {
    // Parking is the one call continuous mode never makes for the human —
    // surface the verdict loudly and keep going; the brainstorm's premise
    // section carries the full argument for a later human read.
    log(`PREMISE WEAK (continuing — continuous mode never auto-parks): ${brainstorm.premiseSummary}`)
  }
}

const approachAnswer = await decide(`${slug}-approach`,
  `Which approach should the PRD build on?`, {
    options: brainstorm.approaches.map((a) => ({
      label: a.name,
      description: `${a.effort} — ${a.summary}`.slice(0, 200),
    })),
    context: `Premise: ${brainstorm.premiseVerdict}. Biggest risk: ${brainstorm.biggestRisk}. Full tradeoffs in the project's brainstorm.md.`,
    recommended: brainstorm.recommended,
  })
const chosenApproach = approachAnswer.choice

phase('PRD')
const prd = await agent(`
Read the PRD skill at .claude/skills/prd/SKILL.md (fall
back to .claude/skills/plan/SKILL.md if that path is absent) and execute it for
company "${co}", project slug "${slug}". A brainstorm.md exists at the project
dir — use the skill's brainstorm-detection path so its content pre-fills the
interview. The chosen approach is ${JSON.stringify(chosenApproach)}${approachAnswer.notes ? ` (user note: ${JSON.stringify(approachAnswer.notes)})` : ''};
direction: ${direction || 'unstated'}; constraints: ${constraints || 'none'}.
Treat those as the interview answers and take sensible defaults for the rest —
but do NOT silently decide anything contentious: put every unresolved,
consequential question into metadata.openQuestions[] with a recommended answer
whenever you have one (the launching flow resolves them after you return).
Write prd.json + README.md, mark the brainstorm promoted, update the board,
and register orchestrator state per the skill.
${NONINTERACTIVE}
Return ONLY JSON with: name (project name), prdPath, stories (count),
openQuestions (array of {question, options (array of 2-3 short candidate
answers, may be empty), recommended (may be empty), whyItMatters (1
sentence)}).`,
  { engine, tier: 'plan', label: 'prd', phase: 'PRD', timeoutSecs: 1800,
    schema: { type: 'object', required: ['name', 'prdPath', 'stories', 'openQuestions'],
      properties: {
        name: { type: 'string' }, prdPath: { type: 'string' }, stories: { type: 'number' },
        openQuestions: { type: 'array', items: { type: 'object', required: ['question'],
          properties: { question: { type: 'string' },
            options: { type: 'array', items: { type: 'string' } },
            recommended: { type: 'string' }, whyItMatters: { type: 'string' } } } },
      } } })

phase('Resolve')
const decisions = []
const deferred = []
if (gated) {
  const toGate = prd.openQuestions.slice(0, maxQuestionGates)
  const overflow = prd.openQuestions.slice(maxQuestionGates)
  if (overflow.length) {
    log(`open-question gates capped at ${maxQuestionGates} — ${overflow.length} more auto-deferred to pre-flight stories`)
    deferred.push(...overflow.map((q) => q.question))
  }
  for (let i = 0; i < toGate.length; i++) {
    const q = toGate[i]
    const opts = (q.options || []).map((o) => ({ label: o }))
    opts.push({ label: 'defer', description: 'Track as a pre-flight investigation story instead of deciding now' })
    const a = await gate(`${slug}-q${i + 1}`, q.question, {
      options: opts,
      context: q.whyItMatters || '',
      recommended: q.recommended || 'defer',
    })
    if (a.choice === 'defer') deferred.push(q.question)
    else decisions.push({ question: q.question, answer: a.choice + (a.notes ? ` (${a.notes})` : ''), decidedBy: a.answered_by || 'operator' })
  }
} else {
  // Continuous: a question WITH a recommendation becomes a ledgered decision;
  // one without becomes a pre-flight investigation story. Nothing pauses.
  for (const q of prd.openQuestions) {
    if (q.recommended) {
      decisions.push({ question: q.question, answer: q.recommended, decidedBy: 'auto (recommended)' })
      log(`auto-decided: ${q.question.slice(0, 70)} -> ${q.recommended.slice(0, 50)}`)
    } else {
      deferred.push(q.question)
    }
  }
  if (deferred.length) log(`${deferred.length} question(s) had no recommendation — deferred to pre-flight stories`)
}

const finalize = await agent(`
Project "${co}/${prd.name}" has a freshly generated prd.json at ${prd.prdPath}.
Apply the decision-mode write-back rules from the PRD skill's open-question
resolution step (read .claude/skills/prd/SKILL.md or
.claude/skills/plan/SKILL.md, the step that resolves metadata.openQuestions):
- Resolved decisions (append to metadata.decisions[] preserving each entry's
  decidedBy, remove from metadata.openQuestions[]): ${JSON.stringify(decisions)}
- Deferred questions (keep in metadata.openQuestions[] annotated, and create
  pre-flight investigation stories wired into dependsOn per the skill):
  ${JSON.stringify(deferred)}
Then re-derive README.md from the updated prd.json and bump the project's
orchestrator state and board entry timestamps. ${NONINTERACTIVE}
Also return stories: EVERY story now in prd.json, in execution order
(investigation/pre-flight stories first, then by dependsOn and priority), as
[{id, title}].
Return ONLY JSON: {"decisionsApplied": <n>, "investigationStories": <n>,
"storiesTotal": <n>, "stories": [{"id": "US-...", "title": "..."}]}`,
  { engine, tier: 'exec', label: 'finalize-prd', phase: 'Resolve', timeoutSecs: 900,
    schema: { type: 'object', required: ['decisionsApplied', 'investigationStories', 'storiesTotal', 'stories'],
      properties: { decisionsApplied: { type: 'number' },
        investigationStories: { type: 'number' }, storiesTotal: { type: 'number' },
        stories: { type: 'array', items: { type: 'object', required: ['id', 'title'],
          properties: { id: { type: 'string' }, title: { type: 'string' } } } } } } })

const planning = {
  mode: gated ? 'gated' : 'continuous',
  boardId: capture.boardId,
  title: capture.title,
  slug,
  prdPath: prd.prdPath,
  premiseVerdict: brainstorm.premiseVerdict,
  chosenApproach,
  autoDecided: gated ? 0 : decisions.length,
  storiesTotal: finalize.storiesTotal,
  decisionsApplied: finalize.decisionsApplied,
  investigationStories: finalize.investigationStories,
}

if (planOnly) return { status: 'prd_ready', ...planning }

// Full arc: execute the stories in order, one agent each, sequentially —
// later stories routinely build on earlier artifacts (reference chains,
// pre-flight findings), and a blocked story stops the line (back-pressure)
// rather than letting dependents run against a hole.
phase('Execute')
const executed = []
let blockedStory = null
for (const st of finalize.stories) {
  const r = await agent(`
Execute story ${st.id} ("${st.title}") of project "${co}/${prd.name}".
Read ${prd.prdPath} for the story's description, acceptanceCriteria, and
metadata (qualityGates, repoPath), and the project dir's planning files
(brainstorm.md, script/references files if present) for context. Do the work
so EVERY acceptance criterion is satisfied: write artifacts under the project
dir (or metadata.repoPath when set), run any runnable quality-gate commands
named in metadata.qualityGates, and update ${prd.prdPath} — set passes:true
for ${st.id} and add a one-line completion note. If a criterion cannot be
satisfied, do not fake it: report blocked with the reason. ${NONINTERACTIVE}
Return ONLY JSON: {"storyId": "${st.id}", "status": "passed"|"blocked",
"artifacts": ["<created/modified paths>"], "note": "<1 line>"}`,
    { engine, tier: 'exec', label: `execute-${st.id}`, phase: 'Execute', timeoutSecs: 1800,
      schema: { type: 'object', required: ['storyId', 'status', 'artifacts', 'note'],
        properties: { storyId: { type: 'string' },
          status: { type: 'string', enum: ['passed', 'blocked'] },
          artifacts: { type: 'array', items: { type: 'string' } },
          note: { type: 'string' } } } })
  executed.push(r)
  if (r.status !== 'passed') {
    blockedStory = r
    log(`story ${st.id} BLOCKED: ${r.note || 'no reason given'} — stopping the line (back-pressure)`)
    break
  }
  log(`story ${st.id} passed (${(r.artifacts || []).length} artifact(s))`)
}

return {
  status: blockedStory ? 'execution_blocked' : 'delivered',
  ...planning,
  storiesExecuted: executed.length,
  deliverables: executed.flatMap((e) => e.artifacts || []),
  blockedStory: blockedStory ? { id: blockedStory.storyId, note: blockedStory.note } : null,
}
