import * as fs from 'fs';
import * as path from 'path';

interface CreatePrdOptions {
  name: string;
  input?: string;
  template?: string;
}

export async function createPrd(options: CreatePrdOptions): Promise<void> {
  const { name, input, template = 'feature' } = options;

  const projectDir = path.join(process.cwd(), '..', '..', '..', 'projects', name);
  const prdPath = path.join(projectDir, 'prd.json');

  // Check if PRD already exists
  if (fs.existsSync(prdPath)) {
    console.error(`PRD already exists at ${prdPath}`);
    console.log('Use project-status to view current state.');
    process.exit(1);
  }

  // Read input requirements if provided
  let requirements = '';
  if (input && fs.existsSync(input)) {
    requirements = fs.readFileSync(input, 'utf-8');
    console.log(`Read requirements from ${input}`);
  }

  // Create project directory
  if (!fs.existsSync(projectDir)) {
    fs.mkdirSync(projectDir, { recursive: true });
    console.log(`Created project directory: ${projectDir}`);
  }

  // Create skeleton PRD
  const prd = {
    project: name,
    created: new Date().toISOString().split('T')[0],
    template,
    epics: [
      {
        id: 'E1',
        title: 'Main Epic',
        stories: [
          {
            id: 'US-001',
            title: 'First User Story',
            description: 'As a user, I want to...',
            acceptance_criteria: [
              'Criterion 1',
              'Criterion 2'
            ],
            priority: 1,
            passes: false,
            worker_hints: ['architect', 'backend-dev', 'qa-tester']
          }
        ]
      }
    ]
  };

  // Write PRD
  fs.writeFileSync(prdPath, JSON.stringify(prd, null, 2));
  console.log(`\nCreated PRD at ${prdPath}`);

  console.log('\n=== PRD Structure ===');
  console.log(`Project: ${name}`);
  console.log(`Template: ${template}`);
  console.log(`Epics: 1`);
  console.log(`Stories: 1 (placeholder)`);

  console.log('\n[Human action required]');
  console.log('Edit the PRD to add your user stories:');
  console.log(`  ${prdPath}`);

  if (requirements) {
    console.log('\nInput requirements were loaded. Consider:');
    console.log('  1. Breaking requirements into user stories');
    console.log('  2. Adding acceptance criteria for each');
    console.log('  3. Setting priorities and worker hints');
  }

  console.log('\nOnce ready, create beads with:');
  console.log(`  bd init --project ${name}`);
}
