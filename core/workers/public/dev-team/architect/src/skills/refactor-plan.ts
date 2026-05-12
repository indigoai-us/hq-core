import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';

interface RefactorPlanOptions {
  target: string;
  repo?: string;
  goal?: string;
}

interface RefactorStep {
  description: string;
  files: string[];
  risk: 'low' | 'medium' | 'high';
  tests: string[];
}

export async function refactorPlan(options: RefactorPlanOptions): Promise<void> {
  const { target, repo, goal } = options;

  console.log(`\n=== Refactor Plan: ${target} ===\n`);

  if (goal) {
    console.log(`Goal: ${goal}\n`);
  }

  // Analyze target
  let analysis: { issues: string[]; metrics: Record<string, number> } = {
    issues: [],
    metrics: {},
  };

  if (repo) {
    console.log('Analyzing target code...');
    analysis = analyzeTarget(repo, target);

    console.log('\nCurrent state:');
    for (const issue of analysis.issues) {
      console.log(`  - ${issue}`);
    }

    if (Object.keys(analysis.metrics).length > 0) {
      console.log('\nMetrics:');
      for (const [key, value] of Object.entries(analysis.metrics)) {
        console.log(`  - ${key}: ${value}`);
      }
    }
  }

  // Generate refactoring steps
  const steps = generateSteps(target, goal, analysis.issues);

  console.log('\n' + '-'.repeat(40));
  console.log('\nRefactoring Steps:\n');

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i];
    const riskColor = step.risk === 'high' ? '⚠️' : step.risk === 'medium' ? '⚡' : '✓';
    console.log(`${i + 1}. [ ] ${step.description} ${riskColor}`);
    console.log(`   Files: ${step.files.join(', ')}`);
    console.log(`   Risk: ${step.risk}`);
    if (step.tests.length > 0) {
      console.log(`   Tests: ${step.tests.join(', ')}`);
    }
    console.log();
  }

  // Test strategy
  console.log('-'.repeat(40));
  console.log('\nTest Strategy:');
  console.log('  - Run existing tests after each step');
  console.log('  - Verify no regressions');
  if (analysis.issues.some(i => i.includes('test'))) {
    console.log('  - Add missing tests before refactoring');
  }

  // Rollback plan
  console.log('\nRollback Plan:');
  console.log('  If issues arise at step N:');
  console.log('    1. git revert to commit before step N');
  console.log('    2. Analyze failure');
  console.log('    3. Adjust approach and retry');

  // Effort estimate
  const complexity = steps.length <= 3 ? 'simple' :
    steps.length <= 6 ? 'medium' : 'complex';
  console.log(`\nEstimated effort: ${steps.length} phases, ${complexity} complexity`);

  console.log('\n[Human approval required]');
  console.log('Approve plan? [y/n/modify]');
}

function analyzeTarget(repoPath: string, target: string): { issues: string[]; metrics: Record<string, number> } {
  const issues: string[] = [];
  const metrics: Record<string, number> = {};

  const fullPath = path.join(repoPath, target);

  if (!fs.existsSync(fullPath)) {
    issues.push(`Target not found: ${target}`);
    return { issues, metrics };
  }

  // Check if it's a directory or file
  const stat = fs.statSync(fullPath);

  if (stat.isDirectory()) {
    // Count files
    try {
      const files = fs.readdirSync(fullPath, { recursive: true }) as string[];
      const tsFiles = files.filter(f => f.endsWith('.ts') || f.endsWith('.tsx'));
      metrics['files'] = tsFiles.length;
    } catch (e) {
      // Ignore
    }
  }

  // Look for common issues
  try {
    const content = stat.isFile()
      ? fs.readFileSync(fullPath, 'utf-8')
      : '';

    // Check for 'any' types
    const anyCount = (content.match(/: any/g) || []).length;
    if (anyCount > 0) {
      issues.push(`${anyCount} uses of 'any' type`);
      metrics['any_types'] = anyCount;
    }

    // Check for @ts-ignore
    const ignoreCount = (content.match(/@ts-ignore/g) || []).length;
    if (ignoreCount > 0) {
      issues.push(`${ignoreCount} @ts-ignore comments`);
      metrics['ts_ignore'] = ignoreCount;
    }

    // Check for TODO comments
    const todoCount = (content.match(/TODO/gi) || []).length;
    if (todoCount > 0) {
      issues.push(`${todoCount} TODO comments`);
      metrics['todos'] = todoCount;
    }

  } catch (e) {
    // Ignore read errors
  }

  if (issues.length === 0) {
    issues.push('No obvious issues detected (manual review recommended)');
  }

  return { issues, metrics };
}

function generateSteps(target: string, goal?: string, issues: string[] = []): RefactorStep[] {
  const goalLower = (goal || '').toLowerCase();

  // TypeScript strict mode refactoring
  if (goalLower.includes('strict') || goalLower.includes('typescript')) {
    return [
      {
        description: 'Add explicit types to function parameters',
        files: [target],
        risk: 'low',
        tests: ['npm run typecheck'],
      },
      {
        description: 'Add explicit return types to functions',
        files: [target],
        risk: 'low',
        tests: ['npm run typecheck'],
      },
      {
        description: 'Replace "any" with proper types',
        files: [target],
        risk: 'medium',
        tests: ['npm run typecheck', 'npm test'],
      },
      {
        description: 'Add null checks for optional values',
        files: [target],
        risk: 'medium',
        tests: ['npm run typecheck', 'npm test'],
      },
      {
        description: 'Remove @ts-ignore comments',
        files: [target],
        risk: 'low',
        tests: ['npm run typecheck'],
      },
      {
        description: 'Enable strict mode in tsconfig',
        files: ['tsconfig.json'],
        risk: 'low',
        tests: ['npm run typecheck', 'npm run build'],
      },
    ];
  }

  // Performance refactoring
  if (goalLower.includes('performance') || goalLower.includes('optimize')) {
    return [
      {
        description: 'Profile current performance',
        files: [target],
        risk: 'low',
        tests: ['manual performance measurement'],
      },
      {
        description: 'Identify bottlenecks',
        files: [target],
        risk: 'low',
        tests: [],
      },
      {
        description: 'Implement optimizations',
        files: [target],
        risk: 'medium',
        tests: ['npm test', 'performance benchmark'],
      },
      {
        description: 'Verify performance improvement',
        files: [],
        risk: 'low',
        tests: ['performance benchmark'],
      },
    ];
  }

  // Default: General refactoring steps
  return [
    {
      description: 'Identify code to refactor',
      files: [target],
      risk: 'low',
      tests: [],
    },
    {
      description: 'Add tests for existing behavior',
      files: [target],
      risk: 'low',
      tests: ['npm test'],
    },
    {
      description: 'Perform refactoring',
      files: [target],
      risk: 'medium',
      tests: ['npm run typecheck', 'npm test'],
    },
    {
      description: 'Update documentation',
      files: [target],
      risk: 'low',
      tests: [],
    },
    {
      description: 'Final verification',
      files: [],
      risk: 'low',
      tests: ['npm run typecheck', 'npm run lint', 'npm test'],
    },
  ];
}
