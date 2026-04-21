import * as fs from 'fs';
import * as path from 'path';

interface SystemDesignOptions {
  feature: string;
  repo?: string;
  scope?: 'small' | 'medium' | 'large';
}

interface DesignOption {
  name: string;
  description: string;
  pros: string[];
  cons: string[];
  recommended?: boolean;
}

export async function systemDesign(options: SystemDesignOptions): Promise<void> {
  const { feature, repo, scope = 'medium' } = options;

  console.log(`\n=== System Design: ${feature} ===\n`);

  // Analyze existing architecture if repo provided
  if (repo) {
    console.log('Analyzing existing architecture...');
    const analysis = analyzeRepo(repo);
    console.log('\nExisting patterns:');
    for (const pattern of analysis.patterns) {
      console.log(`  - ${pattern}`);
    }
    console.log('\nKey dependencies:');
    for (const dep of analysis.dependencies.slice(0, 5)) {
      console.log(`  - ${dep}`);
    }
  }

  // Generate design options based on feature
  const designOptions = generateDesignOptions(feature, scope);

  console.log('\n' + '-'.repeat(40));
  console.log('\nDesign Options:\n');

  for (let i = 0; i < designOptions.length; i++) {
    const opt = designOptions[i];
    const rec = opt.recommended ? ' (Recommended)' : '';
    console.log(`${i + 1}. ${opt.name}${rec}`);
    console.log(`   ${opt.description}`);
    console.log('   Pros:');
    for (const pro of opt.pros) {
      console.log(`     + ${pro}`);
    }
    console.log('   Cons:');
    for (const con of opt.cons) {
      console.log(`     - ${con}`);
    }
    console.log();
  }

  console.log('[Human approval required]');
  console.log(`Select approach: [1-${designOptions.length}]`);

  // Show what would be generated
  console.log('\n' + '-'.repeat(40));
  console.log('\nOn approval, will generate:');
  console.log('  - Architecture Decision Record (ADR)');
  console.log('  - Component diagram (Mermaid)');
  console.log('  - Implementation guide for workers');

  // Sample ADR output
  console.log('\n' + '-'.repeat(40));
  console.log('\nSample ADR Preview:');
  console.log(`
# ADR: ${feature}

## Status
Proposed

## Context
Implementation of ${feature} requires architectural decisions
regarding ${scope} scope changes.

## Decision
[Selected option will be documented here]

## Consequences
- Integration with existing patterns
- Changes to: [affected components]
- New dependencies: [if any]

## Implementation Guide
1. [Steps for architect/other workers]
2. ...
`);
}

function analyzeRepo(repoPath: string): { patterns: string[]; dependencies: string[] } {
  const patterns: string[] = [];
  const dependencies: string[] = [];

  // Check for common patterns
  const checks = [
    { file: 'next.config.js', pattern: 'Next.js' },
    { file: 'next.config.mjs', pattern: 'Next.js' },
    { file: 'prisma/schema.prisma', pattern: 'Prisma ORM' },
    { file: 'drizzle.config.ts', pattern: 'Drizzle ORM' },
    { file: 'src/app', pattern: 'Next.js App Router' },
    { file: 'src/pages', pattern: 'Next.js Pages Router' },
    { file: 'tailwind.config.js', pattern: 'Tailwind CSS' },
    { file: 'tailwind.config.ts', pattern: 'Tailwind CSS' },
  ];

  for (const check of checks) {
    const fullPath = path.join(repoPath, check.file);
    if (fs.existsSync(fullPath)) {
      patterns.push(check.pattern);
    }
  }

  // Check package.json for dependencies
  const pkgPath = path.join(repoPath, 'package.json');
  if (fs.existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8'));
      const deps = { ...pkg.dependencies, ...pkg.devDependencies };
      dependencies.push(...Object.keys(deps).slice(0, 10));
    } catch (e) {
      // Ignore parse errors
    }
  }

  if (patterns.length === 0) {
    patterns.push('(Unable to detect patterns - provide --repo)');
  }

  return { patterns, dependencies };
}

function generateDesignOptions(feature: string, scope: string): DesignOption[] {
  // Generate context-aware options based on feature keywords
  const featureLower = feature.toLowerCase();

  if (featureLower.includes('auth')) {
    return [
      {
        name: 'NextAuth.js',
        description: 'Use NextAuth.js for authentication with built-in providers',
        pros: ['Battle-tested', 'Many OAuth providers', 'Session management included'],
        cons: ['Opinionated structure', 'Some flexibility limits'],
        recommended: true,
      },
      {
        name: 'Custom OAuth',
        description: 'Build custom OAuth implementation',
        pros: ['Full control', 'No external dependencies'],
        cons: ['More work', 'Security risks', 'Maintenance burden'],
      },
      {
        name: 'Managed Service (Clerk/Auth0)',
        description: 'Use a managed authentication service',
        pros: ['Zero maintenance', 'Advanced features included'],
        cons: ['Vendor lock-in', 'Monthly cost', 'Less control'],
      },
    ];
  }

  if (featureLower.includes('api') || featureLower.includes('endpoint')) {
    return [
      {
        name: 'REST API',
        description: 'Traditional REST endpoints with JSON',
        pros: ['Simple', 'Well-understood', 'Good tooling'],
        cons: ['Over/under-fetching', 'Multiple requests needed'],
        recommended: true,
      },
      {
        name: 'GraphQL',
        description: 'GraphQL API with schema-first approach',
        pros: ['Flexible queries', 'Strong typing', 'Single endpoint'],
        cons: ['Complexity', 'Learning curve', 'Caching challenges'],
      },
      {
        name: 'tRPC',
        description: 'End-to-end typesafe APIs',
        pros: ['Full type safety', 'No codegen', 'Great DX'],
        cons: ['TypeScript only', 'Tighter coupling'],
      },
    ];
  }

  // Default options for general features
  return [
    {
      name: 'Incremental Addition',
      description: 'Add feature alongside existing code',
      pros: ['Low risk', 'Quick to implement', 'Easy rollback'],
      cons: ['May not optimize for feature', 'Technical debt possible'],
      recommended: true,
    },
    {
      name: 'Refactor First',
      description: 'Refactor existing code, then add feature',
      pros: ['Clean architecture', 'Better long-term'],
      cons: ['More time', 'Higher initial risk'],
    },
    {
      name: 'New Module',
      description: 'Create isolated module for feature',
      pros: ['Clean separation', 'Independent testing'],
      cons: ['Integration overhead', 'Duplication possible'],
    },
  ];
}
