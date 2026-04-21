#!/usr/bin/env node
import { Command } from 'commander';
import { implementEndpoint } from './skills/implement-endpoint';
import { implementService } from './skills/implement-service';

const program = new Command();

program
  .name('backend-dev')
  .description('API implementation, business logic, and server-side integrations')
  .version('1.0.0');

program
  .command('implement-endpoint')
  .description('Create a new API endpoint')
  .requiredOption('--spec <spec>', 'Endpoint spec (e.g., "POST /api/users")')
  .option('--repo <path>', 'Target repository')
  .option('--types <file>', 'TypeScript types file')
  .action(async (options) => {
    await implementEndpoint(options);
  });

program
  .command('implement-service')
  .description('Create a service/business logic layer')
  .requiredOption('--name <name>', 'Service name')
  .option('--repo <path>', 'Target repository')
  .option('--methods <list>', 'Comma-separated method names')
  .action(async (options) => {
    await implementService(options);
  });

program
  .command('add-middleware')
  .description('Add Express/Next.js middleware')
  .requiredOption('--name <name>', 'Middleware name')
  .option('--repo <path>', 'Target repository')
  .action(async (options) => {
    console.log('add-middleware not yet implemented');
  });

program
  .command('fix-backend-bug')
  .description('Fix server-side bug')
  .requiredOption('--issue <description>', 'Bug description')
  .option('--repo <path>', 'Target repository')
  .action(async (options) => {
    console.log('fix-backend-bug not yet implemented');
  });

program.parse();
