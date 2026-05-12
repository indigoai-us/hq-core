interface Learning {
  type: 'project' | 'pattern' | 'troubleshoot' | 'workflow';
  category?: string;
  content: string;
  source?: string;
}

interface ReportOptions {
  verbose?: boolean;
}

interface ExecutionContext {
  task: string;
  project: string;
  phases: number;
  retries: number;
  duration: string;
  workers: string[];
  errors: string[];
}

export async function reportLearnings(options: ReportOptions): Promise<void> {
  const { verbose } = options;

  console.log('=== Learning Extraction ===\n');

  // In production, this would receive context from execute skill
  // For now, show the expected format and process

  console.log('This skill extracts learnings from task execution.\n');

  console.log('Expected input (from execute skill):');
  const sampleContext: ExecutionContext = {
    task: 'US-003',
    project: 'auth-feature',
    phases: 2,
    retries: 0,
    duration: '5m',
    workers: ['backend-dev', 'qa-tester'],
    errors: [],
  };
  console.log(JSON.stringify(sampleContext, null, 2));

  console.log('\n' + '-'.repeat(40) + '\n');

  // Learning extraction logic
  const learnings: Learning[] = [];

  // Analyze execution for learnings
  learnings.push({
    type: 'workflow',
    content: `Sequence ${sampleContext.workers.join(' → ')} worked well for auth endpoints`,
  });

  if (sampleContext.retries === 0) {
    learnings.push({
      type: 'pattern',
      category: 'general',
      content: 'Clean execution with no retries indicates well-scoped task',
    });
  }

  // Format output
  console.log('Extracted learnings:\n');

  for (let i = 0; i < learnings.length; i++) {
    const l = learnings[i];
    const category = l.category ? `/${l.category}` : '';
    console.log(`${i + 1}. [${l.type}${category}]`);
    console.log(`   ${l.content}`);
    if (l.source) {
      console.log(`   Source: ${l.source}`);
    }
    console.log();
  }

  // Routing info
  console.log('Routing destinations:');
  for (const l of learnings) {
    let dest = '';
    switch (l.type) {
      case 'project':
        dest = `projects/${sampleContext.project}/learnings/`;
        break;
      case 'pattern':
        dest = `knowledge/dev-team/patterns/${l.category || 'general'}/`;
        break;
      case 'troubleshoot':
        dest = 'knowledge/dev-team/troubleshooting/';
        break;
      case 'workflow':
        dest = 'knowledge/dev-team/workflows/';
        break;
    }
    console.log(`  - [${l.type}] → ${dest}`);
  }

  console.log('\n[Human approval required]');
  console.log('Approve learnings for routing? [y/n/edit]');

  console.log('\nTo route approved learnings:');
  console.log(`  project-manager update-learnings --project ${sampleContext.project}`);

  // Output format for project-manager
  if (verbose) {
    console.log('\n' + '-'.repeat(40));
    console.log('\nJSON output for project-manager:');
    console.log(JSON.stringify({
      task: sampleContext.task,
      project: sampleContext.project,
      execution: {
        phases: sampleContext.phases,
        retries: sampleContext.retries,
        duration: sampleContext.duration,
      },
      learnings,
    }, null, 2));
  }
}
