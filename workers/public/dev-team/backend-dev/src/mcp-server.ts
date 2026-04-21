#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  { name: 'backend-dev', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'implement_endpoint',
        description: 'Create a new API endpoint',
        inputSchema: {
          type: 'object',
          properties: {
            spec: { type: 'string', description: 'Endpoint spec (e.g., "POST /api/users")' },
            repo: { type: 'string', description: 'Target repository' },
            types: { type: 'string', description: 'TypeScript types file' },
          },
          required: ['spec'],
        },
      },
      {
        name: 'implement_service',
        description: 'Create a service/business logic layer',
        inputSchema: {
          type: 'object',
          properties: {
            name: { type: 'string', description: 'Service name' },
            repo: { type: 'string', description: 'Target repository' },
            methods: { type: 'string', description: 'Comma-separated method names' },
          },
          required: ['name'],
        },
      },
      {
        name: 'add_middleware',
        description: 'Add Express/Next.js middleware',
        inputSchema: {
          type: 'object',
          properties: {
            name: { type: 'string', description: 'Middleware name' },
            repo: { type: 'string', description: 'Target repository' },
          },
          required: ['name'],
        },
      },
      {
        name: 'fix_backend_bug',
        description: 'Fix server-side bug',
        inputSchema: {
          type: 'object',
          properties: {
            issue: { type: 'string', description: 'Bug description' },
            repo: { type: 'string', description: 'Target repository' },
          },
          required: ['issue'],
        },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case 'implement_endpoint': {
        const { implementEndpoint } = await import('./skills/implement-endpoint');
        const result = await captureOutput(() => implementEndpoint(args as any));
        return { content: [{ type: 'text', text: result }] };
      }
      case 'implement_service': {
        const { implementService } = await import('./skills/implement-service');
        const result = await captureOutput(() => implementService(args as any));
        return { content: [{ type: 'text', text: result }] };
      }
      default:
        return { content: [{ type: 'text', text: `Tool ${name} not yet implemented` }] };
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { content: [{ type: 'text', text: `Error: ${message}` }], isError: true };
  }
});

async function captureOutput(fn: () => Promise<any>): Promise<string> {
  const logs: string[] = [];
  const orig = { log: console.log, error: console.error };
  console.log = (...args) => logs.push(args.join(' '));
  console.error = (...args) => logs.push(`ERROR: ${args.join(' ')}`);
  try { await fn(); } finally { Object.assign(console, orig); }
  return logs.join('\n');
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
