import type { Run, Story } from '../types'

export type Summary = {
  total: number
  done: number
  failed: number
  blocked: number
  remaining: number
  running: Story | undefined
  runningForMs: number | undefined
  avgMs: number | undefined
  etaMs: number | undefined
  isComplete: boolean
}

export const isFinished = (one: Story) =>
  one.status === 'done' || one.status === 'failed' || one.status === 'blocked'

export function summarize(run: Run, now: number): Summary {
  const count = (status: Story['status']) => run.stories.filter(one => one.status === status).length
  const timed = run.stories.filter(
    one => isFinished(one) && one.startedAt !== undefined && one.finishedAt !== undefined,
  )
  const avgMs =
    timed.length === 0
      ? undefined
      : timed.reduce((sum, one) => sum + (one.finishedAt! - one.startedAt!), 0) / timed.length
  const remaining = count('pending') + count('running')
  const running = run.stories.find(one => one.status === 'running')
  const etaMs = avgMs === undefined || remaining === 0 ? undefined : avgMs * remaining

  return {
    total: run.stories.length,
    done: count('done'),
    failed: count('failed'),
    blocked: count('blocked'),
    remaining,
    running,
    runningForMs: running?.startedAt === undefined ? undefined : Math.max(0, now - running.startedAt),
    avgMs,
    etaMs,
    // Only the orchestrator says a run is over: with every story finished but
    // some failed or blocked, a run stays open for a retry or an owner's answer.
    isComplete: run.isFinished,
  }
}

export type ProgressEvent =
  | { kind: 'done' | 'failed' | 'blocked'; story: string; title: string }
  | { kind: 'gate'; story: string; passed: boolean }
  | { kind: 'complete' }

export function bar(done: number, total: number, width: number): string {
  const filled = total === 0 ? 0 : Math.round((done / total) * width)

  return '█'.repeat(filled) + '░'.repeat(Math.max(0, width - filled))
}

export function formatDuration(ms: number): string {
  const s = Math.round(ms / 1000)
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return s % 60 === 0 ? `${m}m` : `${m}m ${s % 60}s`

  return `${Math.floor(m / 60)}h ${m % 60}m`
}

export const isRunProjectSkill = (skill: string) => /(^|:|-)run-project$/.test(skill)
