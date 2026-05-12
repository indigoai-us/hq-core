#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  {
    name: 'architect',
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
        name: 'system_design',
        description: 'Design system architecture for a feature',
        inputSchema: {
          type: 'object',
          properties: {
            feature: { type: 'string', description: 'Feature to design' },
            repo: { type: 'string', description: 'Target repository path' },
            scope: { type: 'string', enum: ['small', 'medium', 'large'], description: 'Scope of design' },
          },
          required: ['feature'],
        },
      },
      {
        name: 'api_design',
        description: 'Design API contracts and interfaces',
        inputSchema: {
          type: 'object',
          properties: {
            endpoint: { type: 'string', description: 'API endpoint path' },
            feature: { type: 'string', description: 'Feature name' },
            repo: { type: 'string', description: 'Target repository' },
            format: { type: 'string', enum: ['openapi', 'typescript'], description: 'Output format' },
          },
        },
      },
      {
        name: 'refactor_plan',
        description: 'Plan a refactoring approach',
        inputSchema: {
          type: 'object',
          properties: {
            target: { type: 'string', description: 'Target file, directory, or pattern' },
            repo: { type: 'string', description: 'Target repository' },
            goal: { type: 'string', description: 'Refactoring goal' },
          },
          required: ['target'],
        },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case 'system_design': {
        const { systemDesign } = await import('./skills/system-design');
        const result = await captureOutput(() => systemDesign(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      case 'api_design': {
        const { apiDesign } = await import('./skills/api-design');
        const result = await captureOutput(() => apiDesign(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      case 'refactor_plan': {
        const { refactorPlan } = await import('./skills/refactor-plan');
        const result = await captureOutput(() => refactorPlan(args as any));
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
