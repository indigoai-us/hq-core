#!/usr/bin/env node
import 'dotenv/config';
import { Command } from 'commander';

const program = new Command();

program
  .name('codex-engine')
  .description('MCP server wrapping @openai/codex-sdk for Codex-powered code workers')
  .version('1.0.0');

program
  .command('serve')
  .description('Start the MCP server (stdio transport)')
  .action(async () => {
    // Dynamically import to avoid loading MCP deps for CLI commands
    await import('./mcp-server');
  });

program
  .command('status')
  .description('Check Codex SDK availability and auth status')
  .action(async () => {
    const fs = await import('fs');
    const path = await import('path');
    const authPath = path.join(
      process.env['HOME'] || process.env['USERPROFILE'] || '~',
      '.codex',
      'auth.json'
    );
    const hasAuth = fs.existsSync(authPath);
    console.log(JSON.stringify({
      sdk: '@openai/codex-sdk',
      authFile: authPath,
      authenticated: hasAuth,
      model: process.env['CODEX_MODEL'] || 'gpt-5.1-codex-max',
      hint: hasAuth ? 'Ready' : 'Run: codex login',
    }, null, 2));
  });

program
  .command('tools')
  .description('List available MCP tools')
  .action(() => {
    const tools = [
      { name: 'codex_generate', description: 'Generate new code from a task description' },
      { name: 'codex_review', description: 'Analyze code for quality issues' },
      { name: 'codex_debug', description: 'Diagnose and fix issues' },
      { name: 'codex_improve', description: 'Apply best-practice improvements' },
    ];
    console.log(JSON.stringify({ tools }, null, 2));
  });

program.parse();
