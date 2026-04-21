import * as fs from 'fs';
import * as path from 'path';

interface Learning {
  type: 'project' | 'pattern' | 'troubleshoot' | 'workflow';
  category?: string;
  content: string;
  task?: string;
}

interface UpdateLearningsOptions {
  project?: string;
  dryRun?: boolean;
}

const KNOWLEDGE_BASE = path.join(process.cwd(), '..', '..', '..', 'knowledge', 'dev-team');

export async function updateLearnings(options: UpdateLearningsOptions): Promise<void> {
  const { project, dryRun } = options;

  // Read learnings from stdin or prompt
  console.log('=== Update Learnings ===\n');
  console.log('Paste learning report (JSON format), then press Ctrl+D:\n');

  // In practice, this would read from stdin or a file
  // For now, show the expected format
  console.log('Expected format:');
  console.log(JSON.stringify({
    task: 'US-001',
    learnings: [
      { type: 'pattern', category: 'backend', content: 'Use retry wrapper for external APIs' },
      { type: 'troubleshoot', content: 'Redis must connect before auth middleware' }
    ]
  }, null, 2));

  console.log('\n[This skill processes learnings from task-executor]');
  console.log('\nRouting destinations:');
  console.log('  - project    → projects/{name}/learnings/');
  console.log('  - pattern    → knowledge/dev-team/patterns/{category}/');
  console.log('  - troubleshoot → knowledge/dev-team/troubleshooting/');
  console.log('  - workflow   → knowledge/dev-team/workflows/');

  if (dryRun) {
    console.log('\n[Dry run mode - no files will be written]');
  }
}

export function routeLearning(learning: Learning, project?: string): string {
  const date = new Date().toISOString().split('T')[0];
  const slug = learning.content
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .substring(0, 40);

  switch (learning.type) {
    case 'project':
      if (!project) throw new Error('Project required for project-specific learnings');
      return path.join('projects', project, 'learnings', `${date}-${slug}.md`);

    case 'pattern':
      const category = learning.category || 'general';
      return path.join(KNOWLEDGE_BASE, 'patterns', category, `${slug}.md`);

    case 'troubleshoot':
      return path.join(KNOWLEDGE_BASE, 'troubleshooting', `${slug}.md`);

    case 'workflow':
      return path.join(KNOWLEDGE_BASE, 'workflows', `${slug}.md`);

    default:
      throw new Error(`Unknown learning type: ${learning.type}`);
  }
}

export function formatLearning(learning: Learning, task?: string): string {
  const lines = [
    `# ${learning.content.split('.')[0]}`,
    '',
    `## Content`,
    learning.content,
    ''
  ];

  if (task) {
    lines.push(`## Source`);
    lines.push(`Learned from task: ${task}`);
    lines.push('');
  }

  lines.push(`## Date`);
  lines.push(new Date().toISOString().split('T')[0]);

  return lines.join('\n');
}
