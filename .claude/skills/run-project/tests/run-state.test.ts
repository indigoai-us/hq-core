import { describe, expect, test } from 'claude-code/testing'

import { summarize } from '../hooks/progress'
import { applyPipeline, changes, parseInvocation, runFromState, statePath } from '../hooks/run-state'
import { PIPELINE_STORIES, PRD, STATE } from './fixtures'

const MIN = 60_000
const T0 = Date.parse('2026-10-14T10:00:00Z')

describe('runFromState', () => {
  test('maps state.json and the PRD to stories in PRD order', () => {
    const run = runFromState('demo-proj', STATE, PRD)

    expect(run.isFinished).toBe(false)
    expect(run.startedAt).toBe(T0)
    expect(run.stories.map(one => `${one.id}:${one.status}`)).toEqual([
      'US-001:done',
      'US-002:done',
      'US-003:failed',
      'US-004:running',
      'US-005:pending',
    ])
    expect(run.stories[3]?.title).toBe('CLI')
    expect(run.gates).toEqual([{ afterStory: 'US-002', passed: true }])
  })

  test('finished stories, failed ones included, are timed back to back from the run start', () => {
    const run = runFromState('demo-proj', STATE, PRD)
    const s = summarize(run, T0 + 30 * MIN)

    expect(run.stories[0]).toMatchObject({ startedAt: T0, finishedAt: T0 + 10 * MIN })
    expect(run.stories[1]).toMatchObject({ startedAt: T0 + 10 * MIN, finishedAt: T0 + 20 * MIN })
    expect(run.stories[2]).toMatchObject({ status: 'failed', startedAt: T0 + 20 * MIN, finishedAt: T0 + 25 * MIN })
    expect(s.avgMs).toBe((25 * MIN) / 3)
    expect(s.etaMs).toBe((2 * 25 * MIN) / 3)
    expect(s.runningForMs).toBe(5 * MIN)
  })

  test('passes: true counts as done even when state.json has not caught up', () => {
    const prd = { userStories: PRD.userStories.map(one => (one.id === 'US-005' ? { ...one, passes: true } : one)) }

    expect(runFromState('demo-proj', STATE, prd).stories[4]?.status).toBe('done')
  })

  test('a story that passed on retry is done, not failed', () => {
    const state = {
      ...STATE,
      completed_tasks: [...STATE.completed_tasks, { id: 'US-003', completed_at: '2026-10-14T10:40:00Z' }],
    }

    expect(runFromState('demo-proj', state, PRD).stories[2]?.status).toBe('done')
  })

  test('without a PRD it falls back to state.json ids and progress.total', () => {
    const run = runFromState('demo-proj', STATE, null)
    const s = summarize(run, T0)

    expect(s.total).toBe(5)
    expect(s.done).toBe(2)
    expect(s.failed).toBe(1)
    expect(s.running?.id).toBe('US-004')
    expect(s.remaining).toBe(2)
  })

  test('a completed run is finished', () => {
    const run = runFromState('demo-proj', { ...STATE, status: 'completed', current_tasks: [] }, PRD)

    expect(run.isFinished).toBe(true)
    expect(summarize(run, T0).isComplete).toBe(true)
  })

  test('a run whose last stories failed is not finished until state.json says so', () => {
    const state = { ...STATE, current_tasks: [], failed_tasks: [...STATE.failed_tasks, { id: 'US-004' }, { id: 'US-005' }] }
    const s = summarize(runFromState('demo-proj', state, PRD), T0)

    expect(s.remaining).toBe(0)
    expect(s.isComplete).toBe(false)
  })

  test('blocked outcomes recorded in state.json show as blocked', () => {
    const state = {
      ...STATE,
      failed_tasks: [{ id: 'US-003', error: 'blocked: TIMEOUT', timestamp: '2026-10-14T10:25:00Z' }],
      blocked_tasks: [{ id: 'US-005', reason: 'INVALID_RETURN_FORMAT' }],
    }
    const run = runFromState('demo-proj', state, PRD)

    expect(run.stories[2]?.status).toBe('blocked')
    expect(run.stories[4]?.status).toBe('blocked')
  })

  test('fields of an unexpected shape are ignored, not thrown on', () => {
    const state = { ...STATE, current_tasks: { id: 'US-004' }, completed_tasks: 'US-001', failed_tasks: [null, 7] }
    const run = runFromState('demo-proj', state as never, PRD)

    expect(run.stories.map(one => one.status)).toEqual(['done', 'done', 'pending', 'pending', 'pending'])
  })

  test('tolerates a sparse state.json', () => {
    const run = runFromState('demo-proj', {}, null)

    expect(run.stories).toEqual([])
    expect(summarize(run, T0).total).toBe(0)
  })
})

describe('parseInvocation', () => {
  const prompt = (args: string) => `# Run Project\n\n**User's input:** ${args}\n\n## Script Resolution\n`

  test('takes the project from the expanded skill text', () => {
    expect(parseInvocation(prompt('demo-proj'))).toEqual({ project: 'demo-proj', isPipeline: false })
    expect(parseInvocation(prompt('--resume demo-proj --timeout 30'))?.project).toBe('demo-proj')
  })

  test('skips the value of every option that takes one', () => {
    expect(parseInvocation(prompt('--account claude-team my-project'))?.project).toBe('my-project')
    expect(parseInvocation(prompt('--timeout 30 --account=auto my-project'))?.project).toBe('my-project')
  })

  test('notes pipeline mode', () => {
    expect(parseInvocation(prompt('demo-proj --pipeline'))).toEqual({ project: 'demo-proj', isPipeline: true })
  })

  test('ignores invocations that do not run stories', () => {
    expect(parseInvocation(prompt('demo-proj --status'))).toBeUndefined()
    expect(parseInvocation(prompt('demo-proj --dry-run'))).toBeUndefined()
    expect(parseInvocation(prompt('--help'))).toBeUndefined()
    expect(parseInvocation(prompt(''))).toBeUndefined()
    expect(parseInvocation('no input line here')).toBeUndefined()
  })

  test('refuses project names that could leave workspace/orchestrator', () => {
    expect(parseInvocation(prompt('../etc'))).toBeUndefined()
    expect(parseInvocation(prompt('a/b'))).toBeUndefined()
  })

  test('state.json lives under workspace/orchestrator', () => {
    expect(statePath('demo-proj')).toBe('workspace/orchestrator/demo-proj/state.json')
  })
})

describe('applyPipeline', () => {
  test('pipeline story files override state.json for the stories they name', () => {
    const run = applyPipeline(runFromState('demo-proj', STATE, PRD), Object.values(PIPELINE_STORIES))

    expect(run.stories.map(one => `${one.id}:${one.status}`)).toEqual([
      'US-001:done',
      'US-002:done',
      'US-003:failed',
      'US-004:done',
      'US-005:running',
    ])
    expect(run.stories[4]?.startedAt).toBe(Date.parse('2026-10-14T10:28:00Z'))
  })

  test('maps every conductor state, adds stories state.json lacks, and leaves skipped ones out', () => {
    const files = [
      { id: 'US-001', state: 'accepted_partial' },
      { id: 'US-002', state: 'skipped' },
      { id: 'US-003', state: 'blocked_needs_owner' },
      { id: 'US-004', state: 'failed_report' },
      { id: 'US-005', state: 'awaiting_recheck' },
      { id: 'US-006', state: 'queued' },
      'not a story',
    ]
    const run = applyPipeline(runFromState('demo-proj', STATE, PRD), files)

    expect(run.stories.map(one => `${one.id}:${one.status}`)).toEqual([
      'US-001:done',
      'US-003:blocked',
      'US-004:failed',
      'US-005:running',
      'US-006:pending',
    ])
  })
})

describe('changes', () => {
  test('reports newly finished stories, failed gates and completion', () => {
    const before = runFromState('demo-proj', STATE, PRD)
    const after = runFromState(
      'demo-proj',
      {
        ...STATE,
        status: 'completed',
        current_tasks: [],
        completed_tasks: [
          ...STATE.completed_tasks,
          { id: 'US-004', completed_at: '2026-10-14T10:35:00Z' },
          { id: 'US-005', completed_at: '2026-10-14T10:45:00Z' },
        ],
        regression_gates: [...STATE.regression_gates, { after_story: 'US-005', passed: false }],
      },
      PRD,
    )

    expect(changes(before, after).map(one => one.kind)).toEqual(['done', 'done', 'gate', 'complete'])
  })

  test('no previous run means nothing to announce', () => {
    expect(changes(null, runFromState('demo-proj', STATE, PRD))).toEqual([])
  })
})
