import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';

interface Story {
  id: string;
  title: string;
  description?: string;
  acceptance_criteria: string[];
  priority: number;
  passes: boolean;
  dependsOn?: string[];
  worker_hints?: string[];
}

interface Epic {
  id: string;
  title: string;
  stories: Story[];
}

interface PRD {
  project: string;
  epics: Epic[];
}

interface NextIssueOptions {
  project: string;
  filter?: string;
  priority?: string;
}

export async function nextIssue(options: NextIssueOptions): Promise<void> {
  const { project, filter, priority } = options;

  // Find PRD file
  const prdPath = path.join(process.cwd(), '..', '..', '..', 'projects', project, 'prd.json');

  if (!fs.existsSync(prdPath)) {
    console.error(`PRD not found at ${prdPath}`);
    console.log('\nTo create a new PRD, run:');
    console.log(`  project-manager create-prd --name ${project} --input requirements.md`);
    process.exit(1);
  }

  const prd: PRD = JSON.parse(fs.readFileSync(prdPath, 'utf-8'));

  // Collect all stories with their pass status
  const allStories: (Story & { epicId: string; epicTitle: string })[] = [];
  for (const epic of prd.epics) {
    for (const story of epic.stories) {
      allStories.push({ ...story, epicId: epic.id, epicTitle: epic.title });
    }
  }

  // Build pass map for dependency checking
  const passMap = new Map<string, boolean>();
  for (const story of allStories) {
    passMap.set(story.id, story.passes);
  }

  // Filter to incomplete stories with met dependencies
  let candidates = allStories.filter(story => {
    if (story.passes) return false;

    // Check dependencies
    if (story.dependsOn && story.dependsOn.length > 0) {
      for (const dep of story.dependsOn) {
        if (!passMap.get(dep)) return false;
      }
    }

    return true;
  });

  // Apply optional filters
  if (priority) {
    const priorityMap: Record<string, number> = { high: 1, medium: 2, low: 3 };
    const priorityValue = priorityMap[priority.toLowerCase()];
    if (priorityValue) {
      candidates = candidates.filter(s => s.priority <= priorityValue);
    }
  }

  if (candidates.length === 0) {
    console.log('No eligible issues found.');
    console.log('\nPossible reasons:');
    console.log('  - All stories are complete (passes: true)');
    console.log('  - Remaining stories have unmet dependencies');
    process.exit(0);
  }

  // Score and sort candidates
  candidates.sort((a, b) => {
    // Priority first (lower number = higher priority)
    if (a.priority !== b.priority) return a.priority - b.priority;

    // Then by number of stories blocked by this one
    const aBlocks = allStories.filter(s => s.dependsOn?.includes(a.id)).length;
    const bBlocks = allStories.filter(s => s.dependsOn?.includes(b.id)).length;
    return bBlocks - aBlocks;
  });

  // Present top candidates
  const top = candidates.slice(0, 3);
  const recommended = top[0];

  console.log(`\n=== Next Issue Selection for ${project} ===\n`);
  console.log(`Recommended: ${recommended.id} "${recommended.title}"`);
  console.log(`  Epic: ${recommended.epicTitle}`);
  console.log(`  Priority: ${recommended.priority}`);

  const blocksCount = allStories.filter(s => s.dependsOn?.includes(recommended.id)).length;
  if (blocksCount > 0) {
    console.log(`  Blocks: ${blocksCount} other stories`);
  }

  if (recommended.worker_hints && recommended.worker_hints.length > 0) {
    console.log(`  Workers: ${recommended.worker_hints.join(' → ')}`);
  }

  console.log('\n  Acceptance Criteria:');
  for (const criterion of recommended.acceptance_criteria) {
    console.log(`    - ${criterion}`);
  }

  if (top.length > 1) {
    console.log('\nAlternatives:');
    for (let i = 1; i < top.length; i++) {
      const alt = top[i];
      console.log(`  - ${alt.id}: "${alt.title}" (Priority: ${alt.priority})`);
    }
  }

  console.log('\n[Human approval required to proceed]');
  console.log('To execute, run task-executor with the selected issue.');
}
