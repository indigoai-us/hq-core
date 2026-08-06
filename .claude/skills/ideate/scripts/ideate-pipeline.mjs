export const meta = {
  name: 'ideate-pipeline',
  description: 'One-run idea -> brainstorm -> PRD pipeline with human gates at real decisions',
  phases: [
    { title: 'Capture', detail: 'board entry for the idea' },
    { title: 'Brainstorm', detail: 'research + premise check + approaches -> brainstorm.md' },
    { title: 'Decide', detail: 'human gates: premise (if weak), approach' },
    { title: 'PRD', detail: 'prd.json + README from the chosen approach' },
    { title: 'Resolve', detail: 'human gates on open questions, then bake decisions in' },
  ],
}

// args contract (all strings unless noted):
//   company      REQUIRED  company slug from companies/manifest.yaml, or "personal"
//   description  REQUIRED  the idea, 1-3 sentences
//   engine       optional  "codex" (default) or "grok" — which agent CLI runs the stages
//   boardId      optional  existing board idea id ({prefix}-proj-NNN) to expand
//   direction    optional  speed | quality | exploration | cost  (interview answer)
//   constraints  optional  free text (timeline, must-use tech, budget)
//   maxQuestionGates optional number, cap on open-question gates (default 6)
//
// Human gates use ids scoped by the project slug (per
// core/knowledge/public/hq-core/workflow-gates-spec.md), so answers never
// collide across projects and a crashed re-run sails through prior decisions.

const co = args?.company
const description = args?.description
if (!co || !description) {
  throw new Error('ideate-pipeline needs args {company, description} — got ' + JSON.stringify(args))
}
const engine = args?.engine || 'codex'
if (engine !== 'codex' && engine !== 'grok') {
  throw new Error('ideate-pipeline args.engine must be "codex" or "grok" — got ' + JSON.stringify(engine))
}
const direction = args?.direction || ''
const constraints = args?.constraints || ''
const maxQuestionGates = Number(args?.maxQuestionGates) > 0 ? Number(args.maxQuestionGates) : 6

// Every stage agent executes the SHIPPED skill file for its stage instead of
// re-implementing it, so the pipeline stays in lockstep with /idea,
// /brainstorm, and the PRD skill. Stages run non-interactively: session-coupled
// steps (interviews, journal pointers, background pulse spawns, deck deploys,
// auto-checkpoint thread files) are skipped — the launching session owns those.
const NONINTERACTIVE = `
Run non-interactively; you have no user to ask. Never call a tool that asks a
human and waits — one may exist in your toolset, but nobody is attached, so it
will stall or cancel the run. Skip any step that requires a live user, a
session journal pointer, a background sub-agent spawn, a visual deck deploy, or
an auto-checkpoint thread file — the launching session handles those. Do not
run a glob/file-search tool from the repo root: HQ denies it (it would scan
over a million files through symlinked repos) and a denied tool call cancels
your whole run — scope the path, or use a shell 'ls'. Company isolation
applies: read and write only under this company's scope (or personal/ for the
personal scope). Do not run git commands; HQ-local writes autosave.`

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
}

const approachAnswer = await gate(`${slug}-approach`,
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
Read the PRD skill at .claude/skills/hq-pack-engineering:prd/SKILL.md (fall
back to .claude/skills/plan/SKILL.md if that path is absent) and execute it for
company "${co}", project slug "${slug}". A brainstorm.md exists at the project
dir — use the skill's brainstorm-detection path so its content pre-fills the
interview. The chosen approach is ${JSON.stringify(chosenApproach)}${approachAnswer.notes ? ` (user note: ${JSON.stringify(approachAnswer.notes)})` : ''};
direction: ${direction || 'unstated'}; constraints: ${constraints || 'none'}.
Treat those as the interview answers and take sensible defaults for the rest —
but do NOT silently decide anything contentious: put every unresolved,
consequential question into metadata.openQuestions[] instead of running the
skill's interactive decision mode (the launching session resolves them via
gates after you return). Write prd.json + README.md, mark the brainstorm
promoted, update the board, and register orchestrator state per the skill.
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
  else decisions.push({ question: q.question, answer: a.choice + (a.notes ? ` (${a.notes})` : '') })
}

const finalize = await agent(`
Project "${co}/${prd.name}" has a freshly generated prd.json at ${prd.prdPath}.
Apply the decision-mode write-back rules from the PRD skill's open-question
resolution step (read .claude/skills/hq-pack-engineering:prd/SKILL.md or
.claude/skills/plan/SKILL.md, the step that resolves metadata.openQuestions):
- Resolved decisions (append to metadata.decisions[], remove from
  metadata.openQuestions[]): ${JSON.stringify(decisions)}
- Deferred questions (keep in metadata.openQuestions[] annotated, and create
  pre-flight investigation stories wired into dependsOn per the skill):
  ${JSON.stringify(deferred)}
Then re-derive README.md from the updated prd.json and bump the project's
orchestrator state and board entry timestamps. ${NONINTERACTIVE}
Return ONLY JSON: {"decisionsApplied": <n>, "investigationStories": <n>,
"storiesTotal": <n>}`,
  { engine, tier: 'exec', label: 'finalize-prd', phase: 'Resolve', timeoutSecs: 900,
    schema: { type: 'object', required: ['decisionsApplied', 'investigationStories', 'storiesTotal'],
      properties: { decisionsApplied: { type: 'number' },
        investigationStories: { type: 'number' }, storiesTotal: { type: 'number' } } } })

return {
  status: 'prd_ready',
  boardId: capture.boardId,
  title: capture.title,
  slug,
  prdPath: prd.prdPath,
  premiseVerdict: brainstorm.premiseVerdict,
  chosenApproach,
  storiesTotal: finalize.storiesTotal,
  decisionsApplied: finalize.decisionsApplied,
  investigationStories: finalize.investigationStories,
}
