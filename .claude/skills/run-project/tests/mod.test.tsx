import type { On } from 'claude-code'
import { describe, expect, mock, test } from 'claude-code/testing'

import { CAPABILITY, CAPABILITY_PATH, PIPELINE_DIR, PIPELINE_STORIES, PRD, SESSION_ID, STATE } from './fixtures'

const NOW = Date.parse('2026-10-14T10:30:00Z')
const STATE_PATH = 'workspace/orchestrator/demo-proj/state.json'
const PRD_PATH = 'companies/acme/projects/demo-proj/prd.json'

const BAND = {
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: true,
    maxRows: 10,
    bodyColumns: 100,
    scroll: { offset: 0, bodyRows: 9 },
    view: {},
  },
} as const

const START = { cwd: '/hq', surface: 'terminal', isInteractive: true } as const

const skillText = (args: string) => `# Run Project\n\n**User's input:** ${args}\n`

const typed = (args: string) =>
  ({
    command: 'story-progress',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 120 },
  }) as const

/**
 * What a session supplies beneath the plugins: an empty band, a status line,
 * toasts, the skill's own text, and a file system holding `files`.
 */
function session(on: On, files: Record<string, string>, links: string[] = []) {
  const shown = { status: [] as Array<string | undefined>, toasts: [] as string[], commands: [] as string[] }
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('command.register', ($, e) => {
    shown.commands.push(e.name)
    return { value: { command: e.name } }
  })
  on('ui.render', ($, e) => {
    const { Box } = $.ui.resolve(e)
    return <Box />
  })
  on('ui.status', ($, e) => {
    shown.status.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', ($, e) => {
    shown.toasts.push(e.text)
    return { value: undefined }
  })
  on('skill.prompt', ($, e) => ({ text: e.text }))
  on('session.id', () => ({ value: SESSION_ID }))
  // The engine resolves a relative path against the session's folder.
  const find = (path: string) => Object.keys(files).find(key => path === key || path.endsWith(`/${key}`))
  const inDir = (path: string) => {
    const dir = path.replace(/\/+$/, '')
    return Object.keys(files).filter(key => {
      const parent = key.slice(0, Math.max(0, key.lastIndexOf('/')))
      return parent !== '' && (dir === parent || dir.endsWith(`/${parent}`))
    })
  }
  on('fs.exists', ($, e) => ({ value: find(e.path) !== undefined || inDir(e.path).length > 0 }))
  on('fs.list', ($, e) => {
    const keys = inDir(e.path)
    if (keys.length === 0) return { deny: `ENOENT: ${e.path}` }
    return {
      value: keys.map(key => ({
        name: key.slice(key.lastIndexOf('/') + 1),
        kind: 'file' as const,
        size: files[key]!.length,
        mtimeMs: 0,
        isLink: false,
      })),
    }
  })
  on('fs.read', ($, e) => {
    const key = find(e.path)
    const text = key === undefined ? undefined : files[key]
    return text === undefined ? { deny: `ENOENT: ${e.path}` } : { value: text }
  })
  // A folder exists when a file lies beneath it; `links` are folders that are symbolic links.
  on('fs.stat', ($, e) => {
    const path = e.path.replace(/\/+$/, '')
    const names = (rel: string) => path === rel || path.endsWith(`/${rel}`)
    const folders = (key: string) => key.split('/').slice(0, -1).map((_, i, parts) => parts.slice(0, i + 1).join('/'))
    const file = find(path)
    if (file !== undefined) return { value: { kind: 'file' as const, size: files[file]!.length, mtimeMs: 0, isLink: false } }
    if (!Object.keys(files).some(key => folders(key).some(names))) return { deny: `ENOENT: ${e.path}` }
    return { value: { kind: 'dir' as const, size: 0, mtimeMs: 0, isLink: links.some(names) } }
  })

  return shown
}

const FILES = {
  [STATE_PATH]: JSON.stringify(STATE),
  [PRD_PATH]: JSON.stringify(PRD),
  [CAPABILITY_PATH]: JSON.stringify(CAPABILITY),
}
/** A second company the session holds no lock for. */
const OTHER_PRD_PATH = ['companies', 'globex', 'projects', 'demo-proj', 'prd.json'].join('/')

describe('run-project progress band in a session', () => {
  test('nothing shows before run-project runs', async ($, on) => {
    session(on, FILES)
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /run-project/ })).toBeUndefined()
  })

  test('a session start registers nothing until run-project runs', async ($, on) => {
    const shown = session(on, FILES)
    mock.clock(on, { now: NOW })
    await $.session.start(START)
    await $.skill.prompt({ skill: 'other-skill', text: skillText('demo-proj') })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj --status') })
    expect(shown.commands).toEqual([])
    expect(shown.status).toEqual([])

    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    expect(shown.commands).toEqual(['story-progress'])
  })

  test('a reload during a run registers the command again and keeps polling', async ($, on) => {
    const files: Record<string, string> = { ...FILES }
    const shown = session(on, files)
    const clock = mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    shown.commands.length = 0
    await $.session.start(START)
    expect(shown.commands).toEqual(['story-progress'])

    files[STATE_PATH] = JSON.stringify({
      ...STATE,
      current_tasks: [],
      completed_tasks: [...STATE.completed_tasks, { id: 'US-004', completed_at: '2026-10-14T10:31:00Z' }],
    })
    await clock.advance(5_000)
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: /3\/5 done/ })).toBeDefined()
  })

  test('run-project shows done vs remaining from state.json', async ($, on) => {
    session(on, FILES)
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })

    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ plugin: 'run-project', surface, ...BAND })
      expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /1 failed/ })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /2 left/ })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /US-004 CLI/ })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /demo-proj/ })).toBeDefined()
      await ui.unmount()
    }
  })

  test('pack-namespaced skill names trigger it too', async ($, on) => {
    session(on, FILES)
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'hq-pack-engineering:run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeDefined()
  })

  test('--status and other skills do not open it', async ($, on) => {
    session(on, FILES)
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj --status') })
    await $.skill.prompt({ skill: 'run-pipeline', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /run-project/ })).toBeUndefined()
  })

  test('before state.json exists it says it is waiting', async ($, on) => {
    session(on, {})
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /waiting for workspace\/orchestrator\/demo-proj/ })).toBeDefined()
  })

  test('it refreshes on the clock and toasts what finished', async ($, on) => {
    const files: Record<string, string> = { ...FILES }
    const shown = session(on, files)
    const clock = mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    expect(shown.toasts).toEqual([])

    files[STATE_PATH] = JSON.stringify({
      ...STATE,
      current_tasks: [{ id: 'US-005', started_at: '2026-10-14T10:31:00Z' }],
      completed_tasks: [...STATE.completed_tasks, { id: 'US-004', completed_at: '2026-10-14T10:31:00Z' }],
    })
    await clock.advance(5_000)

    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: /3\/5 done/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /US-005 Docs/ })).toBeDefined()
    expect(shown.toasts).toEqual(['✓ US-004 CLI · 3/5 done'])
    expect(shown.status.at(-1)).toBe('stories 3/5 · 1 ✗')
  })

  test('a corrupt state.json keeps the last good view and says so', async ($, on) => {
    const files: Record<string, string> = { ...FILES }
    session(on, files)
    const clock = mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    files[STATE_PATH] = '{ not json'
    await clock.advance(5_000)

    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /state\.json unreadable/ })).toBeDefined()
  })

  test('/story-progress stop clears the band and stops reading', async ($, on) => {
    const files: Record<string, string> = { ...FILES }
    const shown = session(on, files)
    const clock = mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeDefined()

    await $.command.run(typed('stop'))
    expect(await ui.find({ type: 'Text', text: /done/ })).toBeUndefined()
    files[STATE_PATH] = JSON.stringify({ ...STATE, completed_tasks: [{ id: 'US-004' }] })
    await clock.advance(5_000)
    expect(await ui.find({ type: 'Text', text: /done/ })).toBeUndefined()
    expect(shown.toasts).toEqual([])
  })

  test('Hide removes the band and /story-progress show brings it back', async ($, on) => {
    session(on, FILES)
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })
    await ui.press({ key: 'hide' })
    expect(await ui.find({ type: 'Text', text: /done/ })).toBeUndefined()

    await $.command.run(typed('show'))
    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeDefined()
  })

  test('trailing punctuation on the option is tolerated', async ($, on) => {
    session(on, FILES)
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })

    expect((await $.command.run(typed('hide.'))).text).toMatch(/hidden/)
  })

  test('/story-progress watch attaches to a run by name', async ($, on) => {
    session(on, FILES)
    mock.clock(on, { now: NOW })
    await $.command.run(typed('watch demo-proj'))
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeDefined()
  })

  test('a run whose PRD is under a company outside the session lock is not shown', async ($, on) => {
    const state = JSON.stringify({ ...STATE, prd_path: OTHER_PRD_PATH })
    const shown = session(on, { ...FILES, [STATE_PATH]: state, [OTHER_PRD_PATH]: JSON.stringify(PRD) })
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /US-004/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /run not shown: globex is outside/ })).toBeDefined()
    expect(shown.status.filter(text => text !== undefined)).toEqual([])
    expect(shown.toasts).toEqual([])
  })

  test('a state.json recorded for another company is not shown', async ($, on) => {
    session(on, { ...FILES, [STATE_PATH]: JSON.stringify({ ...STATE, company: 'globex' }) })
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /run not shown: globex is outside/ })).toBeDefined()
  })

  test('a state.json that names no company is not shown', async ($, on) => {
    const { prd_path: _prd, ...state } = STATE
    session(on, { ...FILES, [STATE_PATH]: JSON.stringify(state) })
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /run not shown: state.json names no company/ })).toBeDefined()
  })

  test('without a company lock the run is not shown', async ($, on) => {
    const { [CAPABILITY_PATH]: _lock, ...files } = FILES
    session(on, files)
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /run not shown: this session has no company lock/ })).toBeDefined()
  })

  test('a locked company whose folder is a symbolic link is not trusted', async ($, on) => {
    session(on, FILES, ['companies/acme'])
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /run not shown/ })).toBeDefined()
  })

  test('watching another project clears the previous status line', async ($, on) => {
    const shown = session(on, FILES)
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    expect(shown.status.at(-1)).toMatch(/stories 2\/5/)

    await $.command.run(typed('watch other-proj'))

    expect(shown.status.at(-1)).toBeUndefined()
  })

  test('an unreadable PRD says so on the band', async ($, on) => {
    session(on, { ...FILES, [PRD_PATH]: '{ not json' })
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /PRD unreadable/ })).toBeDefined()
  })

  test('a state.json of an unexpected shape does not stop the refresh', async ($, on) => {
    const files: Record<string, string> = { ...FILES }
    session(on, files)
    const clock = mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    files[STATE_PATH] = JSON.stringify({ ...STATE, current_tasks: { id: 'US-004' } })
    await clock.advance(5_000)
    files[STATE_PATH] = JSON.stringify({
      ...STATE,
      current_tasks: [],
      completed_tasks: [...STATE.completed_tasks, { id: 'US-004', completed_at: '2026-10-14T10:31:00Z' }],
    })
    await clock.advance(5_000)
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /3\/5 done/ })).toBeDefined()
  })

  test('a completed state.json from an earlier run keeps it polling for the new run', async ($, on) => {
    const earlier = { ...STATE, status: 'completed', current_tasks: [], updated_at: '2026-10-13T09:00:00Z' }
    const files: Record<string, string> = { ...FILES, [STATE_PATH]: JSON.stringify(earlier) }
    session(on, files)
    const clock = mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })
    expect(await ui.find({ type: 'Text', text: /waiting for this run/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Run finished/ })).toBeUndefined()

    files[STATE_PATH] = JSON.stringify({ ...STATE, updated_at: '2026-10-14T10:30:00Z' })
    await clock.advance(5_000)
    expect(await ui.find({ type: 'Text', text: /2\/5 done/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /waiting for this run/ })).toBeUndefined()
  })

  test('a run held on failed stories does not say it finished', async ($, on) => {
    const held = { ...STATE, current_tasks: [], failed_tasks: [...STATE.failed_tasks, { id: 'US-004' }, { id: 'US-005' }] }
    const shown = session(on, { ...FILES, [STATE_PATH]: JSON.stringify(held) })
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /Run finished/ })).toBeUndefined()
    expect(await ui.find({ type: 'Text', text: /Stopped on failed or blocked stories/ })).toBeDefined()
    expect(shown.status.at(-1)).toBe('stories 2/5 · 3 ✗')
  })

  test('--pipeline reads the conductor story files', async ($, on) => {
    const files: Record<string, string> = { ...FILES }
    for (const [id, story] of Object.entries(PIPELINE_STORIES)) files[`${PIPELINE_DIR}/${id}.json`] = JSON.stringify(story)
    session(on, files)
    mock.clock(on, { now: NOW })
    await $.skill.prompt({ skill: 'run-project', text: skillText('demo-proj --pipeline') })
    const ui = await $.ui.mount({ plugin: 'run-project', surface: 'terminal', ...BAND })

    expect(await ui.find({ type: 'Text', text: /3\/5 done/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /US-005 Docs \(2m\)/ })).toBeDefined()
  })
})
