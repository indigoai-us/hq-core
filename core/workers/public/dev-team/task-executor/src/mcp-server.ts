#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  {
    name: 'task-executor',
    version: '1.0.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'execute',
        description: 'Execute issue end-to-end: analyze, spawn workers, validate, report',
        inputSchema: {
          type: 'object',
          properties: {
            issue: { type: 'string', description: 'Issue ID' },
            project: { type: 'string', description: 'Project name' },
            repo: { type: 'string', description: 'Target repository path' },
            skipValidation: { type: 'boolean', description: 'Skip back pressure checks' },
          },
          required: ['issue', 'project'],
        },
      },
      {
        name: 'analyze_issue',
        description: 'Analyze issue to determine worker sequence',
        inputSchema: {
          type: 'object',
          properties: {
            issue: { type: 'string', description: 'Issue ID' },
            project: { type: 'string', description: 'Project name' },
            repo: { type: 'string', description: 'Target repository for file analysis' },
          },
          required: ['issue', 'project'],
        },
      },
      {
        name: 'validate_completion',
        description: 'Run back pressure checks on completed work',
        inputSchema: {
          type: 'object',
          properties: {
            repo: { type: 'string', description: 'Repository path' },
            checks: { type: 'string', description: 'Comma-separated checks to run' },
            strict: { type: 'boolean', description: 'Fail on warnings' },
          },
          required: ['repo'],
        },
      },
      {
        name: 'report_learnings',
        description: 'Extract and format learnings from execution',
        inputSchema: {
          type: 'object',
          properties: {
            verbose: { type: 'boolean', description: 'Include detailed execution trace' },
          },
        },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case 'execute': {
        const { execute } = await import('./skills/execute');
        const result = await captureOutput(() => execute(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      case 'analyze_issue': {
        const { analyzeIssue } = await import('./skills/analyze-issue');
        const result = await captureOutput(() => analyzeIssue(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      case 'validate_completion': {
        const { validateCompletion } = await import('./skills/validate-completion');
        const result = await captureOutput(() => validateCompletion(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      case 'report_learnings': {
        const { reportLearnings } = await import('./skills/report-learnings');
        const result = await captureOutput(() => reportLearnings(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { content: [{ type: 'text', text: `Error: ${message}` }], isError: true };
  }
});

async function captureOutput(fn: () => Promise<any>): Promise<string> {
  const logs: string[] = [];
  const originalLog = console.log;
  const originalError = console.error;

  console.log = (...args) => logs.push(args.join(' '));
  console.error = (...args) => logs.push(`ERROR: ${args.join(' ')}`);

  try {
    await fn();
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }

  return logs.join('\n');
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
