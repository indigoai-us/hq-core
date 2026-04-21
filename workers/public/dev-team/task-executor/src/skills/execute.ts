import * as fs from 'fs';
import * as path from 'path';
import { analyzeIssue, AnalysisResult } from './analyze-issue';
import { validateCompletion } from './validate-completion';

interface ExecuteOptions {
  issue: string;
  project: string;
  repo?: string;
  skipValidation?: boolean;
}

interface ExecutionPhase {
  worker: string;
  description: string;
  status: 'pending' | 'running' | 'completed' | 'failed';
  result?: string;
  error?: string;
}

interface ExecutionState {
  issue: string;
  project: string;
  phases: ExecutionPhase[];
  currentPhase: number;
  learnings: Array<{ type: string; content: string }>;
  startTime: Date;
}

export async function execute(options: ExecuteOptions): Promise<void> {
  const { issue, project, repo, skipValidation } = options;

  console.log(`\n=== Executing ${issue} ===\n`);

  // Step 1: Analyze issue
  console.log('Analyzing issue...');
  const analysis = await analyzeIssue({ issue, project, repo });

  if (!analysis) {
    console.error('Failed to analyze issue');
    process.exit(1);
  }

  // Step 2: Present plan
  console.log('\nPlanned execution:');
  for (let i = 0; i < analysis.sequence.length; i++) {
    const phase = analysis.sequence[i];
    console.log(`  ${i + 1}. ${phase.worker}: ${phase.phase}`);
  }

  console.log(`\nComplexity: ${analysis.complexity}`);
  console.log(`Estimated files: ${analysis.estimated_files.join(', ')}`);

  console.log('\n[Human approval required]');
  console.log('Approve plan? [y/n/modify]');
  console.log('(In production, this waits for human input)\n');

  // Step 3: Execute phases
  const state: ExecutionState = {
    issue,
    project,
    phases: analysis.sequence.map(s => ({
      worker: s.worker,
      description: s.phase,
      status: 'pending' as const,
    })),
    currentPhase: 0,
    learnings: [],
    startTime: new Date(),
  };

  for (let i = 0; i < state.phases.length; i++) {
    state.currentPhase = i;
    const phase = state.phases[i];

    console.log(`\n--- Phase ${i + 1}/${state.phases.length} ---`);
    console.log(`Spawning ${phase.worker}: ${phase.description}`);
    console.log('\n[Human approval required]');
    console.log('Approve? [y/inject context/skip]');

    // Mark as running
    phase.status = 'running';

    // In production, this would spawn the worker via Task tool
    console.log(`\n[Would spawn ${phase.worker} worker here]`);
    console.log('Task tool call:');
    console.log(JSON.stringify({
      description: `${phase.worker}: ${phase.description}`,
      prompt: `Execute ${phase.worker} worker for issue ${issue}...`,
      subagent_type: 'general-purpose',
    }, null, 2));

    // Simulate completion
    phase.status = 'completed';
    phase.result = `Completed ${phase.description}`;

    console.log(`\n${phase.worker} completed:`);
    console.log(`  Result: ${phase.result}`);
    console.log('\n[Human approval required]');
    console.log('Approve changes? [y/n/rollback]');

    // Step 4: Validate (if not skipped)
    if (!skipValidation && repo) {
      console.log('\nRunning validation...');
      await validateCompletion({ repo });
    }
  }

  // Step 5: Extract learnings
  console.log('\n=== Execution Complete ===\n');

  const duration = Math.round((Date.now() - state.startTime.getTime()) / 1000);
  console.log(`Duration: ${duration}s`);
  console.log(`Phases: ${state.phases.filter(p => p.status === 'completed').length}/${state.phases.length} completed`);

  // Sample learnings
  state.learnings.push({
    type: 'workflow',
    content: `Sequence ${analysis.sequence.map(s => s.worker).join(' → ')} worked well for ${issue}`,
  });

  console.log('\nLearnings extracted:');
  for (const learning of state.learnings) {
    console.log(`  - [${learning.type}] ${learning.content}`);
  }

  console.log('\n[Human approval required]');
  console.log('Mark issue as passing? [y/n]');

  console.log('\nTo route learnings, run:');
  console.log(`  project-manager update-learnings --project ${project}`);
}
