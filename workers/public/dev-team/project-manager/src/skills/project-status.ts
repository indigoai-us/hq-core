import * as fs from 'fs';
import * as path from 'path';

interface Story {
  id: string;
  title: string;
  passes: boolean;
  dependsOn?: string[];
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

interface ProjectStatusOptions {
  project: string;
  verbose?: boolean;
  format?: string;
}

export async function projectStatus(options: ProjectStatusOptions): Promise<void> {
  const { project, verbose, format = 'table' } = options;

  const prdPath = path.join(process.cwd(), '..', '..', '..', 'projects', project, 'prd.json');

  if (!fs.existsSync(prdPath)) {
    console.error(`PRD not found at ${prdPath}`);
    process.exit(1);
  }

  const prd: PRD = JSON.parse(fs.readFileSync(prdPath, 'utf-8'));

  // Collect all stories
  const allStories: (Story & { epicTitle: string })[] = [];
  for (const epic of prd.epics) {
    for (const story of epic.stories) {
      allStories.push({ ...story, epicTitle: epic.title });
    }
  }

  // Calculate stats
  const total = allStories.length;
  const completed = allStories.filter(s => s.passes).length;
  const pending = allStories.filter(s => !s.passes).length;
  const percentage = Math.round((completed / total) * 100);

  // Build pass map for dependency checking
  const passMap = new Map<string, boolean>();
  for (const story of allStories) {
    passMap.set(story.id, story.passes);
  }

  // Find blocked stories
  const blocked = allStories.filter(story => {
    if (story.passes) return false;
    if (!story.dependsOn || story.dependsOn.length === 0) return false;
    return story.dependsOn.some(dep => !passMap.get(dep));
  });

  // Find ready stories (not passed, dependencies met)
  const ready = allStories.filter(story => {
    if (story.passes) return false;
    if (!story.dependsOn || story.dependsOn.length === 0) return true;
    return story.dependsOn.every(dep => passMap.get(dep));
  });

  // Output
  if (format === 'json') {
    console.log(JSON.stringify({
      project,
      total,
      completed,
      pending,
      percentage,
      blocked: blocked.map(s => s.id),
      ready: ready.map(s => s.id)
    }, null, 2));
    return;
  }

  // Progress bar
  const barLength = 20;
  const filledLength = Math.round((percentage / 100) * barLength);
  const bar = '█'.repeat(filledLength) + '░'.repeat(barLength - filledLength);

  console.log(`\n=== ${project} ===`);
  console.log(`Progress: ${bar} ${percentage}% (${completed}/${total} stories)\n`);

  if (completed > 0) {
    console.log(`✅ Completed (${completed}):`);
    for (const story of allStories.filter(s => s.passes)) {
      console.log(`   - ${story.id}: ${story.title}`);
    }
    console.log();
  }

  if (ready.length > 0) {
    console.log(`⏳ Ready (${ready.length}):`);
    for (const story of ready) {
      console.log(`   - ${story.id}: ${story.title}`);
    }
    console.log();
  }

  if (blocked.length > 0) {
    console.log(`🚫 Blocked (${blocked.length}):`);
    for (const story of blocked) {
      const blockedBy = story.dependsOn?.filter(dep => !passMap.get(dep)) || [];
      console.log(`   - ${story.id}: ${story.title}`);
      console.log(`     blocked by: ${blockedBy.join(', ')}`);
    }
    console.log();
  }

  // Next recommendation
  if (ready.length > 0) {
    console.log(`Next: Run task-executor on ${ready[0].id}`);
    console.log(`  task-executor execute --issue ${ready[0].id} --project ${project}`);
  } else if (pending > 0) {
    console.log('⚠️  All pending stories are blocked. Resolve dependencies first.');
  } else {
    console.log('🎉 All stories complete!');
  }
}
