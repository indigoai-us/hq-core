import type { Run, Story } from '../types'
import { isFinished } from './progress'
import type { ProgressEvent } from './progress'

/**
 * The fields of workspace/orchestrator/{project}/state.json this reads
 * (schema: core/settings/orchestrator.yaml). Every field is checked before use:
 * other processes write the file and it may hold anything.
 */
export type OrchestratorState = {
  status?: unknown
  company?: unknown
  started_at?: unknown
  updated_at?: unknown
  prd_path?: unknown
  progress?: unknown
  current_tasks?: unknown
  completed_tasks?: unknown
  failed_tasks?: unknown
  blocked_tasks?: unknown
  regression_gates?: unknown
}

/** The fields of the project's prd.json this reads. */
export type Prd = {
  userStories?: unknown
}

/** What a /run-project invocation runs. */
export type Invocation = { project: string; isPipeline: boolean }

type Fields = Record<string, unknown>

/** The object entries of an array field; anything else reads as empty. */
export const entries = (value: unknown): Fields[] =>
  Array.isArray(value) ? value.filter((one): one is Fields => one !== null && typeof one === 'object') : []

const text = (value: unknown) => (typeof value === 'string' ? value : undefined)

const SAFE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

/** Flags under which /run-project reports and stops instead of running stories. */
const NON_RUN_FLAGS = new Set(['--status', '--dry-run', '--help', '-h'])

/** Options written `--name value` (`--name=value` is one word already). */
const VALUE_FLAGS = new Set(['--timeout', '--account'])

export const statePath = (project: string) => `workspace/orchestrator/${project}/state.json`

export const pipelineStoriesPath = (project: string) => `workspace/orchestrator/${project}/pipeline/state/stories`

/**
 * The project a /run-project invocation runs, read from the skill's expanded
 * text (`**User's input:** {project} [flags]`); undefined when it runs none.
 */
export function parseInvocation(prompt: string): Invocation | undefined {
  const line = /\*\*User's input:\*\*[ \t]*(.*)/.exec(prompt)?.[1]
  if (line === undefined) return undefined
  const words = line.trim().split(/\s+/).filter(Boolean)
  if (words.some(word => NON_RUN_FLAGS.has(word))) return undefined
  const positional = words.filter((word, i) => !word.startsWith('-') && !VALUE_FLAGS.has(words[i - 1] ?? ''))
  const project = positional[0]

  return project !== undefined && SAFE_NAME.test(project)
    ? { project, isPipeline: words.includes('--pipeline') }
    : undefined
}

/** A PRD path state.json names, kept when it stays inside the HQ root. */
export function safePrdPath(path: unknown): string | undefined {
  if (typeof path !== 'string' || path === '' || path.startsWith('/') || path.split('/').includes('..')) {
    return undefined
  }

  return path
}

const time = (iso: unknown) => {
  const ms = typeof iso === 'string' ? Date.parse(iso) : NaN
  return Number.isNaN(ms) ? undefined : ms
}

/** A failed_tasks entry that recorded a block (`blocked: TIMEOUT`, `blocked: true`). */
const isBlockedFailure = (one: Fields) => one.blocked === true || /^blocked\b/i.test(text(one.error) ?? '')

/** Each entry's id with the time its `at` field names. */
function byId(list: unknown, at: string) {
  const found = new Map<string, number | undefined>()
  for (const one of entries(list)) {
    const id = text(one.id)
    if (id) found.set(id, time(one[at]))
  }
  return found
}

export function runFromState(project: string, state: OrchestratorState, prd: Prd | null): Run {
  const startedAt = time(state.started_at) ?? 0
  const completed = byId(state.completed_tasks, 'completed_at')
  const current = byId(state.current_tasks, 'started_at')
  const blocked = byId(state.blocked_tasks, 'timestamp')
  const failed = new Map<string, number | undefined>()
  for (const one of entries(state.failed_tasks)) {
    const id = text(one.id)
    if (!id) continue
    if (isBlockedFailure(one)) blocked.set(id, time(one.timestamp))
    else failed.set(id, time(one.timestamp))
  }

  const fromPrd = entries(prd?.userStories).filter(one => typeof one.id === 'string')
  const ids =
    fromPrd.length > 0
      ? fromPrd.map(one => one.id as string)
      : [...new Set([...completed.keys(), ...failed.keys(), ...blocked.keys(), ...current.keys()])]
  const meta = new Map(fromPrd.map(one => [one.id as string, one]))

  const stories: Story[] = ids.map(id => {
    const one = meta.get(id)
    const worker = text(one?.worker)
    const base = { id, title: text(one?.title) ?? '', ...(worker ? { worker } : {}) }
    const at = (finishedAt: number | undefined) => (finishedAt === undefined ? {} : { finishedAt })
    if (one?.passes === true || completed.has(id)) return { ...base, status: 'done', ...at(completed.get(id)) }
    if (current.has(id)) {
      const runningSince = current.get(id)
      return { ...base, status: 'running', ...(runningSince === undefined ? {} : { startedAt: runningSince }) }
    }
    if (blocked.has(id)) return { ...base, status: 'blocked', ...at(blocked.get(id)) }
    if (failed.has(id)) return { ...base, status: 'failed', ...at(failed.get(id)) }
    if (one?.status === 'blocked') return { ...base, status: 'blocked' }

    return { ...base, status: 'pending' }
  })

  // Without a PRD, state.json's total says how many stories are still to come.
  const progress = state.progress !== null && typeof state.progress === 'object' ? (state.progress as Fields) : {}
  const total = typeof progress.total === 'number' ? progress.total : 0
  for (let n = stories.length; fromPrd.length === 0 && n < total; n++) {
    stories.push({ id: `#${n + 1}`, title: '', status: 'pending' })
  }

  timeBackToBack(stories, startedAt)

  return {
    project,
    isFinished: state.status === 'completed',
    startedAt,
    stories,
    gates: entries(state.regression_gates)
      .filter(g => typeof g.after_story === 'string')
      .map(g => ({ afterStory: g.after_story as string, passed: g.passed === true })),
  }
}

/**
 * Lanes record when a story finished, not when it began: time finished stories
 * (done, failed or blocked) back to back from the run's start, in the order
 * they finished.
 */
function timeBackToBack(stories: Story[], startedAt: number) {
  let previous = startedAt
  for (const one of stories
    .filter(s => isFinished(s) && s.finishedAt !== undefined)
    .sort((a, b) => a.finishedAt! - b.finishedAt!)) {
    one.startedAt = Math.min(previous, one.finishedAt!)
    previous = one.finishedAt!
  }
}

/** pipeline-conductor.sh story states, as the band counts them. */
const PIPELINE_STATUS: Record<string, Story['status'] | 'skipped'> = {
  verified: 'done',
  accepted_partial: 'done',
  in_flight: 'running',
  awaiting_recheck: 'running',
  blocked_needs_owner: 'blocked',
  parked: 'blocked',
  parked_dependency: 'blocked',
  failed_report: 'failed',
  skipped: 'skipped',
}

/**
 * Lays `--pipeline` story files (pipeline/state/stories/{id}.json) over the
 * run: the conductor owns story state in pipeline mode and does not set
 * `passes`. Stories state.json does not list are added; skipped ones dropped.
 */
export function applyPipeline(run: Run, files: unknown[]): Run {
  const stories = run.stories.map(one => ({ ...one }))
  const skipped = new Set<string>()
  for (const file of entries(files)) {
    const id = text(file.id)
    if (!id) continue
    const status = PIPELINE_STATUS[text(file.state) ?? ''] ?? 'pending'
    if (status === 'skipped') {
      skipped.add(id)
      continue
    }
    let one = stories.find(s => s.id === id)
    if (one === undefined) {
      one = { id, title: text(file.title) ?? '', status }
      stories.push(one)
    }
    one.status = status
    if (status === 'running' || status === 'pending') delete one.finishedAt
    if (status === 'running' && typeof file.routed_at === 'number') one.startedAt = file.routed_at * 1000
  }

  return { ...run, stories: stories.filter(one => !skipped.has(one.id)) }
}

/** What changed between two reads of a run, as toasts announce it. */
export function changes(before: Run | null, after: Run): ProgressEvent[] {
  if (before === null) return []
  const was = new Map(before.stories.map(one => [one.id, one.status]))
  const events: ProgressEvent[] = []
  for (const one of after.stories) {
    if (!isFinished(one) || was.get(one.id) === one.status) continue
    if (one.status === 'done' || one.status === 'failed' || one.status === 'blocked') {
      events.push({ kind: one.status, story: one.id, title: one.title })
    }
  }
  for (const gate of after.gates.slice(before.gates.length)) {
    events.push({ kind: 'gate', story: gate.afterStory, passed: gate.passed })
  }
  if (after.isFinished && !before.isFinished) events.push({ kind: 'complete' })

  return events
}
