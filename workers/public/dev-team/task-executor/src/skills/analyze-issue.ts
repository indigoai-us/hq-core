import * as fs from 'fs';
import * as path from 'path';

interface Story {
  id: string;
  title: string;
  description?: string;
  acceptance_criteria: string[];
  priority: number;
  passes: boolean;
  worker_hints?: string[];
}

interface AnalyzeOptions {
  issue: string;
  project: string;
  repo?: string;
}

export interface AnalysisResult {
  issue: string;
  title: string;
  workers: string[];
  sequence: Array<{ worker: string; phase: string }>;
  estimated_files: string[];
  complexity: 'simple' | 'medium' | 'complex';
  reasoning: string;
}

// Worker detection patterns
const WORKER_PATTERNS: Record<string, string[]> = {
  'backend-dev': ['api', 'endpoint', 'route', 'server', 'middleware', 'controller'],
  'database-dev': ['database', 'schema', 'migration', 'table', 'query', 'sql'],
  'frontend-dev': ['component', 'ui', 'page', 'form', 'button', 'modal', 'react', 'next'],
  'motion-designer': ['animation', 'transition', 'motion', 'polish', 'effect', 'visual'],
  'infra-dev': ['ci/cd', 'deploy', 'pipeline', 'docker', 'kubernetes', 'terraform'],
  'qa-tester': ['test', 'coverage', 'accessibility', 'a11y', 'e2e', 'integration'],
  'architect': ['architecture', 'design', 'refactor', 'restructure', 'pattern'],
};

// Standard worker sequences
const SEQUENCES: Record<string, string[]> = {
  'api': ['backend-dev', 'qa-tester'],
  'api-with-db': ['architect', 'database-dev', 'backend-dev', 'qa-tester'],
  'frontend': ['frontend-dev', 'qa-tester'],
  'frontend-polished': ['frontend-dev', 'motion-designer', 'qa-tester'],
  'fullstack': ['architect', 'database-dev', 'backend-dev', 'frontend-dev', 'qa-tester'],
  'infra': ['architect', 'infra-dev', 'qa-tester'],
};

export async function analyzeIssue(options: AnalyzeOptions): Promise<AnalysisResult | null> {
  const { issue, project, repo } = options;

  // Find PRD
  const prdPath = path.join(process.cwd(), '..', '..', '..', 'projects', project, 'prd.json');

  if (!fs.existsSync(prdPath)) {
    console.error(`PRD not found at ${prdPath}`);
    return null;
  }

  const prd = JSON.parse(fs.readFileSync(prdPath, 'utf-8'));

  // Find the issue
  let story: Story | null = null;
  for (const epic of prd.epics) {
    for (const s of epic.stories) {
      if (s.id === issue) {
        story = s;
        break;
      }
    }
  }

  if (!story) {
    console.error(`Issue ${issue} not found in PRD`);
    return null;
  }

  console.log(`\n=== Analysis: ${issue} ===\n`);
  console.log(`Title: ${story.title}`);
  if (story.description) {
    console.log(`Description: ${story.description}`);
  }

  // Check for explicit worker hints
  let workers: string[] = [];
  let reasoning = '';

  if (story.worker_hints && story.worker_hints.length > 0) {
    workers = story.worker_hints;
    reasoning = 'Using explicit worker_hints from PRD';
    console.log(`\nUsing worker_hints: ${workers.join(', ')}`);
  } else {
    // Auto-detect workers
    const text = `${story.title} ${story.description || ''} ${story.acceptance_criteria.join(' ')}`.toLowerCase();

    const detectedWorkers: Set<string> = new Set();
    const detectedPatterns: string[] = [];

    for (const [worker, patterns] of Object.entries(WORKER_PATTERNS)) {
      for (const pattern of patterns) {
        if (text.includes(pattern)) {
          detectedWorkers.add(worker);
          detectedPatterns.push(`"${pattern}" → ${worker}`);
          break;
        }
      }
    }

    // Always add qa-tester at the end if not present
    if (!detectedWorkers.has('qa-tester')) {
      detectedWorkers.add('qa-tester');
    }

    workers = Array.from(detectedWorkers);
    reasoning = `Detected patterns: ${detectedPatterns.join(', ')}`;

    console.log('\nDetected patterns:');
    for (const p of detectedPatterns) {
      console.log(`  - ${p}`);
    }
  }

  // Order workers properly
  const orderedWorkers = orderWorkers(workers);

  // Build sequence with descriptions
  const sequence = orderedWorkers.map(worker => ({
    worker,
    phase: getPhaseDescription(worker, story!.title),
  }));

  // Estimate complexity
  const complexity = estimateComplexity(sequence.length, story.acceptance_criteria.length);

  // Estimate files (placeholder - would need repo analysis)
  const estimated_files = estimateFiles(workers, repo);

  const result: AnalysisResult = {
    issue,
    title: story.title,
    workers: orderedWorkers,
    sequence,
    estimated_files,
    complexity,
    reasoning,
  };

  console.log(`\nRecommended sequence:`);
  for (let i = 0; i < sequence.length; i++) {
    console.log(`  ${i + 1}. ${sequence[i].worker}: ${sequence[i].phase}`);
  }

  console.log(`\nEstimated files: ${estimated_files.join(', ')}`);
  console.log(`Complexity: ${complexity}`);

  console.log('\n[Human approval required]');
  console.log('Confirm sequence? [y/n/modify]');

  return result;
}

function orderWorkers(workers: string[]): string[] {
  const order = [
    'architect',
    'database-dev',
    'backend-dev',
    'frontend-dev',
    'motion-designer',
    'infra-dev',
    'qa-tester',
    'code-reviewer',
  ];

  return workers.sort((a, b) => {
    const aIndex = order.indexOf(a);
    const bIndex = order.indexOf(b);
    return (aIndex === -1 ? 99 : aIndex) - (bIndex === -1 ? 99 : bIndex);
  });
}

function getPhaseDescription(worker: string, issueTitle: string): string {
  const descriptions: Record<string, string> = {
    'architect': `Design approach for: ${issueTitle}`,
    'database-dev': `Schema changes for: ${issueTitle}`,
    'backend-dev': `Implement backend for: ${issueTitle}`,
    'frontend-dev': `Build UI for: ${issueTitle}`,
    'motion-designer': `Add polish/animations for: ${issueTitle}`,
    'infra-dev': `Configure infrastructure for: ${issueTitle}`,
    'qa-tester': `Verify: ${issueTitle}`,
    'code-reviewer': `Review changes for: ${issueTitle}`,
  };
  return descriptions[worker] || `Execute: ${issueTitle}`;
}

function estimateComplexity(phases: number, criteria: number): 'simple' | 'medium' | 'complex' {
  const score = phases + criteria / 2;
  if (score <= 3) return 'simple';
  if (score <= 6) return 'medium';
  return 'complex';
}

function estimateFiles(workers: string[], repo?: string): string[] {
  // Placeholder - would analyze repo in production
  const files: string[] = [];

  if (workers.includes('backend-dev')) {
    files.push('src/api/*.ts');
  }
  if (workers.includes('database-dev')) {
    files.push('src/db/*.ts', 'migrations/*.sql');
  }
  if (workers.includes('frontend-dev')) {
    files.push('src/components/*.tsx', 'src/pages/*.tsx');
  }

  return files.length > 0 ? files : ['(analysis requires --repo)'];
}
