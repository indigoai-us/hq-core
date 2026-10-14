export type StoryStatus = 'pending' | 'running' | 'done' | 'failed' | 'blocked'

export type Story = {
  id: string
  title: string
  worker?: string
  status: StoryStatus
  startedAt?: number
  finishedAt?: number
}

export type Gate = { afterStory: string; passed: boolean }

export type Run = {
  project: string
  /** The orchestrator marked the run completed (state.json `status`). */
  isFinished: boolean
  startedAt: number
  stories: Story[]
  gates: Gate[]
}

/** The project /run-project is running, and what reading its state last said. */
export type Watch = {
  project: string
  /** `/run-project --pipeline`: story state is in pipeline/state/stories/. */
  isPipeline?: boolean
  /**
   * The `started_at|updated_at` of a completed state.json left by an earlier
   * run, seen when this invocation began; polling goes on until it changes.
   */
  priorRun?: string
  /** What the last read could not show, and why. */
  note?: string
}

declare module 'claude-code' {
  interface PluginState {
    'run-project': { run: Run | null; watch: Watch | null; isHidden: boolean }
  }
}
