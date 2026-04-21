#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  { name: 'frontend-dev', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'create_component',
      description: 'Create new React component',
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'Component name' },
          repo: { type: 'string', description: 'Target repository' },
          type: { type: 'string', enum: ['functional', 'class'], description: 'Component type' },
          withTest: { type: 'boolean', description: 'Include test file' },
        },
        required: ['name'],
      },
    },
    {
      name: 'create_page',
      description: 'Create new page/route',
      inputSchema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Page path' },
          repo: { type: 'string', description: 'Target repository' },
        },
        required: ['path'],
      },
    },
    {
      name: 'fix_ui_bug',
      description: 'Fix frontend bug',
      inputSchema: {
        type: 'object',
        properties: {
          issue: { type: 'string', description: 'Bug description' },
          repo: { type: 'string', description: 'Target repository' },
        },
        required: ['issue'],
      },
    },
    {
      name: 'add_form',
      description: 'Add form with validation',
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'Form name' },
          fields: { type: 'string', description: 'Comma-separated field names' },
          repo: { type: 'string', description: 'Target repository' },
        },
        required: ['name'],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  return { content: [{ type: 'text', text: `Tool ${name} called with: ${JSON.stringify(args)}` }] };
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
