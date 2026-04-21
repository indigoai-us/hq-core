#!/usr/bin/env node
import { Command } from 'commander';
import { nextIssue } from './skills/next-issue';
import { createPrd } from './skills/create-prd';
import { updateLearnings } from './skills/update-learnings';
import { projectStatus } from './skills/project-status';

const program = new Command();

program
  .name('project-manager')
  .description('Project orchestration: PRD lifecycle, issue selection, learning aggregation')
  .version('1.0.0');

program
  .command('next-issue')
  .description('Select next issue from project to work on')
  .requiredOption('--project <name>', 'Project name')
  .option('--filter <label>', 'Filter by label')
  .option('--priority <level>', 'Filter by priority (high|medium|low)')
  .action(async (options) => {
    await nextIssue(options);
  });

program
  .command('create-prd')
  .description('Create new PRD from requirements')
  .requiredOption('--name <name>', 'Project name')
  .option('--input <file>', 'Input requirements file')
  .option('--template <type>', 'Template type (feature|bugfix|refactor)')
  .action(async (options) => {
    await createPrd(options);
  });

program
  .command('update-learnings')
  .description('Route learnings to appropriate knowledge locations')
  .option('--project <name>', 'Project context')
  .option('--dry-run', 'Show routing without writing')
  .action(async (options) => {
    await updateLearnings(options);
  });

program
  .command('project-status')
  .description('Show project progress and blockers')
  .requiredOption('--project <name>', 'Project name')
  .option('--verbose', 'Show detailed story status')
  .option('--format <type>', 'Output format (table|json|markdown)')
  .action(async (options) => {
    await projectStatus(options);
  });

program.parse();
