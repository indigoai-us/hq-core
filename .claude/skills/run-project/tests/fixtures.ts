/** A run part-way through: 2 done, 1 failed, 1 running, 1 pending. */
export const STATE = {
  project: 'demo-proj',
  status: 'in_progress',
  started_at: '2026-10-14T10:00:00Z',
  prd_path: 'companies/acme/projects/demo-proj/prd.json',
  progress: { total: 5, completed: 2, failed: 1, in_progress: 1 },
  current_tasks: [{ id: 'US-004', started_at: '2026-10-14T10:25:00Z' }],
  completed_tasks: [
    { id: 'US-002', completed_at: '2026-10-14T10:20:00Z' },
    { id: 'US-001', completed_at: '2026-10-14T10:10:00Z' },
  ],
  failed_tasks: [{ id: 'US-003', error: 'passes not set after attempt 2', timestamp: '2026-10-14T10:25:00Z' }],
  regression_gates: [{ after_story: 'US-002', passed: true }],
}

/** This session's company lock, as core/scripts/hq-session.sh writes it. */
export const SESSION_ID = 'sess-1'
export const CAPABILITY_PATH = `workspace/sessions/${SESSION_ID}/scope-capability.json`
export const CAPABILITY = { session_id: SESSION_ID, company_slug: 'acme' }

/** pipeline-conductor.sh story files (`routed_at` is in seconds). */
export const PIPELINE_DIR = 'workspace/orchestrator/demo-proj/pipeline/state/stories'
export const PIPELINE_STORIES = {
  'US-004': { id: 'US-004', state: 'verified', routed_at: Date.parse('2026-10-14T10:25:00Z') / 1000 },
  'US-005': { id: 'US-005', state: 'in_flight', routed_at: Date.parse('2026-10-14T10:28:00Z') / 1000 },
}

export const PRD = {
  name: 'demo-proj',
  userStories: [
    { id: 'US-001', title: 'Schema', passes: true },
    { id: 'US-002', title: 'Read path', passes: true },
    { id: 'US-003', title: 'Write path', passes: false },
    { id: 'US-004', title: 'CLI', passes: false },
    { id: 'US-005', title: 'Docs', passes: false },
  ],
}
