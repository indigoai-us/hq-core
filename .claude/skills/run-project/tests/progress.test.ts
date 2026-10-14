import { describe, expect, test } from 'claude-code/testing'

import { bar, formatDuration, isRunProjectSkill, summarize } from '../hooks/progress'
import type { Run, Story } from '../types'

const MIN = 60_000
const NOW = 1_800_000_000_000

/** 12 stories: 4 done and 1 failed at 8 minutes each, one running for 2, 6 pending. */
function midRun(): Run {
  const startedAt = NOW - 42 * MIN
  const stories: Story[] = Array.from({ length: 12 }, (_, i) => {
    const id = `US-${String(i + 1).padStart(3, '0')}`
    if (i < 5) {
      return {
        id,
        title: '',
        status: i === 4 ? 'failed' : 'done',
        startedAt: startedAt + i * 8 * MIN,
        finishedAt: startedAt + (i + 1) * 8 * MIN,
      }
    }
    if (i === 5) return { id, title: '', status: 'running', startedAt: NOW - 2 * MIN }

    return { id, title: '', status: 'pending' }
  })

  return { project: 'p', isFinished: false, startedAt, stories, gates: [] }
}

describe('progress maths', () => {
  test('counts done, failed and remaining', () => {
    const s = summarize(midRun(), NOW)

    expect(s.total).toBe(12)
    expect(s.done).toBe(4)
    expect(s.failed).toBe(1)
    expect(s.remaining).toBe(7)
    expect(s.running?.id).toBe('US-006')
    expect(s.runningForMs).toBe(2 * MIN)
    expect(s.isComplete).toBe(false)
  })

  test('ETA is the mean finished-story duration times stories left', () => {
    const s = summarize(midRun(), NOW)

    expect(s.avgMs).toBe(8 * MIN)
    expect(s.etaMs).toBe(7 * 8 * MIN)
  })

  test('a run is complete only when the orchestrator says so', () => {
    const run = midRun()
    const allFinished = { ...run, stories: run.stories.map(one => ({ ...one, status: 'failed' as const })) }

    expect(summarize(allFinished, NOW).isComplete).toBe(false)
    expect(summarize({ ...allFinished, isFinished: true }, NOW).isComplete).toBe(true)
  })

  test('an empty run is not complete', () => {
    expect(summarize({ ...midRun(), stories: [] }, NOW).isComplete).toBe(false)
  })

  test('bar and duration formatting', () => {
    expect(bar(3, 12, 12)).toBe('███░░░░░░░░░')
    expect(bar(0, 0, 4)).toBe('░░░░')
    expect(formatDuration(45_000)).toBe('45s')
    expect(formatDuration(3 * MIN + 10_000)).toBe('3m 10s')
    expect(formatDuration(72 * MIN)).toBe('1h 12m')
  })

  test('recognises every run-project skill name', () => {
    expect(isRunProjectSkill('run-project')).toBe(true)
    expect(isRunProjectSkill('hq-run-project')).toBe(true)
    expect(isRunProjectSkill('hq-pack-engineering:run-project')).toBe(true)
    expect(isRunProjectSkill('run-pipeline')).toBe(false)
    expect(isRunProjectSkill('run-projects')).toBe(false)
  })
})
