#!/usr/bin/env node
/**
 * Frontend Designer Worker CLI
 *
 * Commands:
 *   design-component  Generate a single React component
 *   design-page       Generate a full page layout
 *   design-system     Create a component library
 *   refine            Iterate on existing component
 *   install-skill     Install/update Anthropic frontend-design skill
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKER_ROOT = join(__dirname, '..');
const SKILL_PATH = join(WORKER_ROOT, 'skills', 'frontend-design', 'SKILL.md');

interface DesignTask {
  type: 'component' | 'page' | 'design-system' | 'refine';
  name: string;
  prompt: string;
  outputPath?: string;
  existingFile?: string;
  feedback?: string;
}

function loadSkill(): string {
  if (!existsSync(SKILL_PATH)) {
    console.error('❌ Skill not found. Run: node dist/index.js install-skill');
    process.exit(1);
  }
  return readFileSync(SKILL_PATH, 'utf-8');
}

function printUsage(): void {
  console.log(`
Frontend Designer Worker

Usage:
  node dist/index.js <command> [options]

Commands:
  design-component  Generate a single React component
    --name <name>       Component name (e.g., "HeroSection")
    --prompt <prompt>   Design description
    --output <path>     Output directory (default: ./output)

  design-page       Generate a full page layout
    --name <name>       Page name (e.g., "LandingPage")
    --prompt <prompt>   Design description
    --output <path>     Output directory

  design-system     Create a component library
    --name <name>       System name (e.g., "CoreUI")
    --prompt <prompt>   Design description
    --output <path>     Output directory

  refine            Iterate on existing component
    --file <path>       Path to existing component
    --feedback <text>   What to improve

  install-skill     Install/update Anthropic frontend-design skill

Examples:
  node dist/index.js design-component --name "HeroSection" --prompt "Brutalist hero with bold typography"
  node dist/index.js design-page --name "LandingPage" --prompt "Luxury SaaS landing page"
  node dist/index.js refine --file "src/components/Hero.tsx" --feedback "More contrast"
`);
}

function parseArgs(args: string[]): Record<string, string> {
  const result: Record<string, string> = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) {
      const key = args[i].slice(2);
      const value = args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : 'true';
      result[key] = value;
      if (value !== 'true') i++;
    }
  }
  return result;
}

function generateComponentPrompt(task: DesignTask, skill: string): string {
  return `${skill}

---

## Task: Generate ${task.type === 'component' ? 'Component' : task.type === 'page' ? 'Page' : 'Design System'}

**Name:** ${task.name}
**Description:** ${task.prompt}

Generate production-ready React + TypeScript code with:
- Tailwind CSS for styling
- shadcn/ui components where appropriate
- Framer Motion for animations (if needed)
- Proper TypeScript types

Remember: NO generic aesthetics. Be BOLD and DISTINCTIVE.
`;
}

function generateRefinePrompt(task: DesignTask, skill: string, existingCode: string): string {
  return `${skill}

---

## Task: Refine Existing Component

**Feedback:** ${task.feedback}

**Existing Code:**
\`\`\`tsx
${existingCode}
\`\`\`

Improve the component based on the feedback while maintaining the same structure.
Apply the frontend-design skill principles to make it more distinctive.
`;
}

async function designComponent(args: Record<string, string>): Promise<void> {
  const skill = loadSkill();
  const name = args.name;
  const prompt = args.prompt;
  const output = args.output || './output';

  if (!name || !prompt) {
    console.error('❌ Missing required args: --name and --prompt');
    process.exit(1);
  }

  const task: DesignTask = { type: 'component', name, prompt };
  const fullPrompt = generateComponentPrompt(task, skill);

  // Ensure output directory exists
  if (!existsSync(output)) {
    mkdirSync(output, { recursive: true });
  }

  // Write prompt to file for Claude to process
  const promptFile = join(output, `${name}.prompt.md`);
  writeFileSync(promptFile, fullPrompt);

  console.log(`✅ Generated prompt: ${promptFile}`);
  console.log(`\nNext: Use this prompt with Claude to generate the component.`);
  console.log(`The skill instructions are embedded in the prompt.`);
}

async function designPage(args: Record<string, string>): Promise<void> {
  const skill = loadSkill();
  const name = args.name;
  const prompt = args.prompt;
  const output = args.output || './output';

  if (!name || !prompt) {
    console.error('❌ Missing required args: --name and --prompt');
    process.exit(1);
  }

  const task: DesignTask = { type: 'page', name, prompt };
  const fullPrompt = generateComponentPrompt(task, skill);

  if (!existsSync(output)) {
    mkdirSync(output, { recursive: true });
  }

  const promptFile = join(output, `${name}.prompt.md`);
  writeFileSync(promptFile, fullPrompt);

  console.log(`✅ Generated prompt: ${promptFile}`);
  console.log(`\nNext: Use this prompt with Claude to generate the page.`);
}

async function designSystem(args: Record<string, string>): Promise<void> {
  const skill = loadSkill();
  const name = args.name;
  const prompt = args.prompt;
  const output = args.output || './output';

  if (!name || !prompt) {
    console.error('❌ Missing required args: --name and --prompt');
    process.exit(1);
  }

  const task: DesignTask = { type: 'design-system', name, prompt };
  const fullPrompt = generateComponentPrompt(task, skill);

  if (!existsSync(output)) {
    mkdirSync(output, { recursive: true });
  }

  const promptFile = join(output, `${name}.prompt.md`);
  writeFileSync(promptFile, fullPrompt);

  console.log(`✅ Generated prompt: ${promptFile}`);
  console.log(`\nNext: Use this prompt with Claude to generate the design system.`);
}

async function refine(args: Record<string, string>): Promise<void> {
  const skill = loadSkill();
  const file = args.file;
  const feedback = args.feedback;

  if (!file || !feedback) {
    console.error('❌ Missing required args: --file and --feedback');
    process.exit(1);
  }

  if (!existsSync(file)) {
    console.error(`❌ File not found: ${file}`);
    process.exit(1);
  }

  const existingCode = readFileSync(file, 'utf-8');
  const task: DesignTask = { type: 'refine', name: file, prompt: '', feedback };
  const fullPrompt = generateRefinePrompt(task, skill, existingCode);

  const output = dirname(file);
  const promptFile = join(output, `refine.prompt.md`);
  writeFileSync(promptFile, fullPrompt);

  console.log(`✅ Generated refine prompt: ${promptFile}`);
  console.log(`\nNext: Use this prompt with Claude to refine the component.`);
}

async function installSkill(): Promise<void> {
  console.log('📦 Installing Anthropic frontend-design skill...');

  try {
    execSync('npx skills add anthropics/claude-code --skill frontend-design', {
      cwd: WORKER_ROOT,
      stdio: 'inherit'
    });
    console.log('✅ Skill installed successfully');
  } catch {
    console.log('⚠️  Auto-install failed. Skill is already bundled at:');
    console.log(`   ${SKILL_PATH}`);

    if (existsSync(SKILL_PATH)) {
      console.log('✅ Bundled skill is ready to use.');
    } else {
      console.error('❌ No skill found. Please install manually.');
    }
  }
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
    printUsage();
    process.exit(0);
  }

  const command = args[0];
  const options = parseArgs(args.slice(1));

  switch (command) {
    case 'design-component':
      await designComponent(options);
      break;
    case 'design-page':
      await designPage(options);
      break;
    case 'design-system':
      await designSystem(options);
      break;
    case 'refine':
      await refine(options);
      break;
    case 'install-skill':
      await installSkill();
      break;
    default:
      console.error(`❌ Unknown command: ${command}`);
      printUsage();
      process.exit(1);
  }
}

main().catch(console.error);
