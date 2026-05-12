#!/usr/bin/env node
import { Command } from 'commander';
import { execute } from './skills/execute';
import { analyzeIssue } from './skills/analyze-issue';
import { validateCompletion } from './skills/validate-completion';
import { reportLearnings } from './skills/report-learnings';

const program = new Command();

program
  .name('task-executor')
  .description('Execute issues by routing to workers and managing execution loop')
  .version('1.0.0');

program
  .command('execute')
  .description('Execute issue end-to-end: analyze, spawn workers, validate, report')
  .requiredOption('--issue <id>', 'Issue ID')
  .requiredOption('--project <name>', 'Project name')
  .option('--repo <path>', 'Target repository path')
  .option('--skip-validation', 'Skip back pressure checks')
  .action(async (options) => {
    await execute(options);
  });

program
  .command('analyze-issue')
  .description('Analyze issue to determine worker sequence')
  .requiredOption('--issue <id>', 'Issue ID')
  .requiredOption('--project <name>', 'Project name')
  .option('--repo <path>', 'Target repository for file analysis')
  .action(async (options) => {
    await analyzeIssue(options);
  });

program
  .command('validate-completion')
  .description('Run back pressure checks on completed work')
  .requiredOption('--repo <path>', 'Repository path')
  .option('--checks <list>', 'Comma-separated checks to run')
  .option('--strict', 'Fail on warnings')
  .action(async (options) => {
    await validateCompletion(options);
  });

program
  .command('report-learnings')
  .description('Extract and format learnings from execution')
  .option('--verbose', 'Include detailed execution trace')
  .action(async (options) => {
    await reportLearnings(options);
  });

program.parse();
