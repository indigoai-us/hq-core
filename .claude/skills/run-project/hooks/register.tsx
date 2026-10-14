import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Run, Story } from '../types'
import { bar, formatDuration, isRunProjectSkill, summarize } from './progress'
import type { ProgressEvent } from './progress'
import {
  applyPipeline,
  changes,
  parseInvocation,
  pipelineStoriesPath,
  runFromState,
  safePrdPath,
  statePath,
} from './run-state'
import type { Invocation, OrchestratorState, Prd } from './run-state'
import { capabilityPath, lockedCompanies, stateScope } from './scope'

const PANE = 'story-progress'
const POLL_MS = 5_000

const runAtom = atom({ plugin: 'run-project', key: 'run' } as const, null)
const watchAtom = atom({ plugin: 'run-project', key: 'watch' } as const, null)
const isHidden = atom({ plugin: 'run-project', key: 'isHidden' } as const, false)

const ICON: Record<Story['status'], string> = {
  done: '✓',
  failed: '✗',
  blocked: '⊘',
  running: '▶',
  pending: '·',
}

const COLOR: Record<Story['status'], string | undefined> = {
  done: 'success',
  failed: 'error',
  blocked: 'warning',
  running: 'claude',
  pending: undefined,
}

let timer: { cancel: () => void } | undefined

function statusLine(run: Run | null, now: number) {
  if (run === null) return undefined
  const s = summarize(run, now)
  const bad = s.failed + s.blocked

  return `stories ${s.done}/${s.total}${bad > 0 ? ` · ${bad} ✗` : ''}${s.isComplete ? ' · finished' : ''}`
}

function announce($: EngineInterface, events: ProgressEvent[], run: Run, now: number) {
  const s = summarize(run, now)
  for (const one of events) {
    const name = one.kind === 'complete' ? '' : `${one.story}${'title' in one && one.title ? ` ${one.title}` : ''}`
    if (one.kind === 'done') $.ui.toast(`✓ ${name} · ${s.done}/${s.total} done`)
    if (one.kind === 'failed') $.ui.toast(`✗ ${name} failed`)
    if (one.kind === 'blocked') $.ui.toast(`⊘ ${name} blocked`)
    if (one.kind === 'gate' && !one.passed) $.ui.toast(`Regression gate after ${one.story} failed`)
    if (one.kind === 'complete') {
      $.ui.toast(`${run.project}: ${s.done} done, ${s.failed} failed, ${s.blocked} blocked`)
    }
  }
}

function stopTimer() {
  timer?.cancel()
  timer = undefined
}

async function readJson<T>($: EngineInterface, path: string): Promise<T> {
  return JSON.parse(await $.fs.read(path)) as T
}

const brief = (error: unknown) => String(error).slice(0, 80)

/** state.json as an object, or why it is not one. */
async function readState($: EngineInterface, path: string): Promise<{ state?: OrchestratorState; error?: string }> {
  try {
    const parsed = await readJson<unknown>($, path)
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return { error: 'not a JSON object' }
    return { state: parsed as OrchestratorState }
  } catch (error) {
    return { error: brief(error) }
  }
}

/** Identifies one run's state.json across reads. */
const runKey = (state: OrchestratorState) => `${String(state.started_at)}|${String(state.updated_at)}`

/**
 * The companies this session is locked to, from its scope capability. Like the
 * shell resolver, a company whose folder is missing or a symbolic link grants nothing.
 */
async function sessionCompanies($: EngineInterface): Promise<string[]> {
  const sessionId = await $.session.id()
  const path = capabilityPath(sessionId)
  if (path === undefined || !(await $.fs.exists(path))) return []
  try {
    const locked = lockedCompanies(await readJson<unknown>($, path), sessionId)
    for (const company of locked) {
      if (company === 'personal') continue
      const folder = await $.fs.stat(`companies/${company}`)
      if (folder.kind !== 'dir' || folder.isLink) return []
    }
    return locked
  } catch {
    return []
  }
}

/** The PRD state.json names; `note` says why it could not be read. */
async function readPrd($: EngineInterface, prdPath: string | undefined): Promise<{ prd: Prd | null; note?: string }> {
  if (prdPath === undefined || !(await $.fs.exists(prdPath))) return { prd: null }
  try {
    return { prd: await readJson<Prd>($, prdPath) }
  } catch (error) {
    return { prd: null, note: `PRD unreadable: ${brief(error)}` }
  }
}

/** `--pipeline` story files; one that does not parse is left out. */
async function readPipeline($: EngineInterface, project: string): Promise<unknown[]> {
  const dir = pipelineStoriesPath(project)
  if (!(await $.fs.exists(dir))) return []
  const stories: unknown[] = []
  for (const file of await $.fs.list(dir)) {
    if (file.kind !== 'file' || !file.name.endsWith('.json')) continue
    try {
      stories.push(await readJson<unknown>($, `${dir}/${file.name}`))
    } catch {
      // A file the conductor is mid-write on; the next read picks it up.
    }
  }
  return stories
}

/** Reads the watched project's state.json (and its PRD) into the band. */
async function refresh($: EngineInterface) {
  const watch = await read($, watchAtom)
  if (watch === null) {
    stopTimer()
    return
  }
  const path = statePath(watch.project)
  // state.json names the run's company, so nothing is shown without it.
  if (!(await $.fs.exists(path))) {
    await update($, watchAtom, () => ({ ...watch, note: `waiting for ${path}` }))
    return
  }

  const loaded = await readState($, path)
  if (loaded.state === undefined) {
    // Keep the last good view; the band shows why it stopped moving.
    await update($, watchAtom, () => ({ ...watch, note: `state.json unreadable: ${loaded.error}` }))
    return
  }
  const state = loaded.state
  if (watch.priorRun !== undefined && state.status === 'completed' && runKey(state) === watch.priorRun) {
    await update($, watchAtom, () => ({ ...watch, note: 'last run completed; waiting for this run to start' }))
    return
  }

  const prdPath = safePrdPath(state.prd_path)
  const company = typeof state.company === 'string' ? state.company : undefined
  const scope = stateScope(company, prdPath, await sessionCompanies($))
  if (!scope.isAllowed) {
    await update($, runAtom, () => null)
    await update($, watchAtom, () => ({ ...watch, ...(scope.note ? { note: scope.note } : {}) }))
    $.ui.status(undefined)
    return
  }

  const pipeline = watch.isPipeline ? await readPipeline($, watch.project) : []
  const { prd, note } = await readPrd($, prdPath)
  const fromState = runFromState(watch.project, state, prd)
  const run = watch.isPipeline ? applyPipeline(fromState, pipeline) : fromState
  const before = await read($, runAtom)
  const now = await $.clock.now()
  await update($, runAtom, () => run)
  await update($, watchAtom, () => ({
    project: watch.project,
    ...(watch.isPipeline ? { isPipeline: true } : {}),
    ...(note ? { note } : {}),
  }))
  $.ui.status(statusLine(run, now))
  announce($, changes(before, run), run, now)
  if (run.isFinished) stopTimer()
}

/** A refresh from the timer: a failure goes on the band instead of ending the polling. */
async function poll($: EngineInterface) {
  try {
    await refresh($)
  } catch (error) {
    const watch = await read($, watchAtom)
    if (watch !== null) await update($, watchAtom, () => ({ ...watch, note: `refresh failed: ${brief(error)}` }))
  }
}

/**
 * Starts reading a run. `isNewRun` (the skill just expanded): a completed
 * state.json already on disk belongs to an earlier run, so keep polling until
 * this one rewrites it.
 */
async function startWatching($: EngineInterface, invocation: Invocation, isNewRun: boolean) {
  stopTimer()
  const path = statePath(invocation.project)
  let priorRun: string | undefined
  if (isNewRun && (await $.fs.exists(path))) {
    const { state } = await readState($, path)
    if (state?.status === 'completed') priorRun = runKey(state)
  }
  await update($, runAtom, () => null)
  $.ui.status(undefined)
  await update($, watchAtom, () => ({
    project: invocation.project,
    ...(invocation.isPipeline ? { isPipeline: true } : {}),
    ...(priorRun === undefined ? {} : { priorRun }),
  }))
  await update($, isHidden, () => false)
  await poll($)
  if ((await read($, runAtom))?.isFinished !== true) {
    timer = $.clock.every(POLL_MS, () => void poll($))
  }
}

/** `/story-progress`, which exists only once /run-project has run in the session. */
async function registerCommand($: EngineInterface) {
  await $.command.register({
    name: 'story-progress',
    description: 'The /run-project progress band: show | hide | pane | stop | watch <project>',
  })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    // Nothing happens until /run-project runs. A reload during a run resets
    // module variables, so a watch the session still holds is picked back up.
    const watch = await read($, watchAtom)
    if (watch !== null) {
      await registerCommand($)
      stopTimer()
      timer = $.clock.every(POLL_MS, () => void poll($))
    }

    return next(e)
  })

  on('command.run', { command: 'story-progress' }, async ($, e) => {
    const [verb = '', ...rest] = e.args
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .map(word => word.replace(/[.,;:!?]+$/, ''))

    if (verb === 'watch') {
      const invocation = parseInvocation(`**User's input:** ${rest.join(' ')}`)
      if (invocation === undefined) return { text: 'Usage: /story-progress watch <project> [--pipeline]' }
      await startWatching($, invocation, false)
      return { text: `Watching ${statePath(invocation.project)}.` }
    }
    if (verb === 'show' || verb === '') {
      await update($, isHidden, () => false)
      return { text: 'Story progress band shown.' }
    }
    if (verb === 'hide') {
      await update($, isHidden, () => true)
      return { text: 'Story progress band hidden. /story-progress show brings it back.' }
    }
    if (verb === 'pane') {
      await $.ui.open({ id: PANE, title: 'Stories' })
      return { text: 'Story progress pane opened.' }
    }
    if (verb === 'stop') {
      stopTimer()
      await update($, runAtom, () => null)
      await update($, watchAtom, () => null)
      $.ui.status(undefined)
      return { text: 'Story progress cleared.' }
    }

    return { text: `Unknown option "${verb}". Use show, hide, pane, stop or watch <project>.` }
  })

  on('skill.prompt', async ($, e, next) => {
    const result = await next(e)
    const invocation = isRunProjectSkill(e.skill) ? parseInvocation(e.text) : undefined
    if (invocation !== undefined) {
      await registerCommand($)
      await startWatching($, invocation, true)
    }

    return result
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const run = await read($, runAtom)
    const watch = await read($, watchAtom)
    if (e.props.hasSurvey || (await read($, isHidden)) || (run === null && watch === null)) {
      return next(e)
    }

    const { Box, Button, Text } = $.ui.resolve(e)
    const hide = <Button key="hide" label="Hide" dimColor onPress={() => update($, isHidden, () => true)} />

    if (run === null) {
      return (
        <Box gap={1}>
          <Text color="claude" bold>
            run-project
          </Text>
          <Text dimColor>{watch?.project}</Text>
          <Text dimColor>{watch?.note ?? 'reading state.json'}</Text>
          {hide}
        </Box>
      )
    }

    const s = summarize(run, await $.clock.now())
    const width = Math.max(8, Math.min(24, e.props.bodyColumns - 70))
    const lastGate = run.gates[run.gates.length - 1]

    return (
      <Box flexDirection="column">
        <Box gap={1}>
          <Text color="claude" bold>
            run-project
          </Text>
          <Text dimColor>{run.project}</Text>
          <Text color="success">{bar(s.done, s.total, width)}</Text>
          <Text bold>
            {s.done}/{s.total} done
          </Text>
          {s.failed + s.blocked > 0 && (
            <Text color="error">
              {s.failed} failed{s.blocked > 0 ? `, ${s.blocked} blocked` : ''}
            </Text>
          )}
          <Text>{s.remaining} left</Text>
        </Box>
        <Box gap={1}>
          {s.running ? (
            <Text wrap="truncate-end">
              ▶ {s.running.id}
              {s.running.title ? ` ${s.running.title}` : ''}
              {s.runningForMs === undefined ? '' : ` (${formatDuration(s.runningForMs)})`}
            </Text>
          ) : (
            <Text color={s.isComplete ? 'success' : s.remaining === 0 && s.total > 0 ? 'warning' : undefined}>
              {s.isComplete
                ? 'Run finished'
                : s.remaining === 0 && s.total > 0
                  ? 'Stopped on failed or blocked stories'
                  : 'Between stories'}
            </Text>
          )}
          {!s.isComplete && s.etaMs !== undefined && <Text dimColor>ETA ~{formatDuration(s.etaMs)}</Text>}
          {lastGate && (
            <Text color={lastGate.passed ? 'success' : 'error'}>
              gate {lastGate.passed ? '✓' : '✗'} {lastGate.afterStory}
            </Text>
          )}
          {watch?.note && <Text color="warning">{watch.note}</Text>}
          <Button
            key="details"
            label="Details"
            dimColor
            onPress={() => void $.ui.open({ id: PANE, title: 'Stories' })}
          />
          {hide}
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const run = await read($, runAtom)
    if (run === null) {
      return <Text dimColor>No run in progress. /run-project starts one.</Text>
    }
    const now = await $.clock.now()
    const s = summarize(run, now)

    return (
      <Box flexDirection="column">
        <Text bold>
          {run.project} · {s.done}/{s.total} done · {s.remaining} left
        </Text>
        <Text dimColor>
          avg {s.avgMs === undefined ? 'n/a' : formatDuration(s.avgMs)} per story · elapsed{' '}
          {formatDuration(Math.max(0, now - run.startedAt))}
        </Text>
        <Text> </Text>
        {run.stories.map(one => (
          <Box key={one.id} gap={1}>
            <Text color={COLOR[one.status]}>{ICON[one.status]}</Text>
            <Text dimColor={one.status === 'pending'}>{one.id}</Text>
            <Text dimColor={one.status === 'pending'} wrap="truncate-end">
              {one.title}
            </Text>
            <Text dimColor>
              {one.worker ?? ''}
              {one.startedAt !== undefined && (one.finishedAt !== undefined || one.status === 'running')
                ? ` · ${formatDuration((one.finishedAt ?? now) - one.startedAt)}`
                : ''}
            </Text>
          </Box>
        ))}
        <Text> </Text>
        <Text dimColor>
          Gates:{' '}
          {run.gates.length === 0
            ? 'none yet'
            : run.gates.map(g => `${g.passed ? '✓' : '✗'} ${g.afterStory}`).join('  ')}
        </Text>
      </Box>
    )
  })
}
