#!/usr/bin/env node
import { Command } from 'commander';
import { systemDesign } from './skills/system-design';
import { apiDesign } from './skills/api-design';
import { refactorPlan } from './skills/refactor-plan';

const program = new Command();

program
  .name('architect')
  .description('System design, planning, and technical decision-making')
  .version('1.0.0');

program
  .command('system-design')
  .description('Design system architecture for a feature')
  .requiredOption('--feature <description>', 'Feature to design')
  .option('--repo <path>', 'Target repository')
  .option('--scope <level>', 'Scope: small|medium|large')
  .action(async (options) => {
    await systemDesign(options);
  });

program
  .command('api-design')
  .description('Design API contracts and interfaces')
  .option('--endpoint <path>', 'API endpoint path')
  .option('--feature <name>', 'Feature name')
  .option('--repo <path>', 'Target repository')
  .option('--format <type>', 'Output format: openapi|typescript')
  .action(async (options) => {
    if (!options.endpoint && !options.feature) {
      console.error('Either --endpoint or --feature is required');
      process.exit(1);
    }
    await apiDesign(options);
  });

program
  .command('refactor-plan')
  .description('Plan a refactoring approach')
  .requiredOption('--target <path>', 'Target file, directory, or pattern')
  .option('--repo <path>', 'Target repository')
  .option('--goal <description>', 'Refactoring goal')
  .action(async (options) => {
    await refactorPlan(options);
  });

program.parse();
