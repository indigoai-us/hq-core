#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  { name: 'database-dev', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'create_schema',
      description: 'Design database schema for feature',
      inputSchema: {
        type: 'object',
        properties: {
          entity: { type: 'string', description: 'Entity name' },
          feature: { type: 'string', description: 'Feature description' },
          repo: { type: 'string', description: 'Target repository' },
          orm: { type: 'string', enum: ['prisma', 'drizzle'], description: 'ORM type' },
        },
      },
    },
    {
      name: 'create_migration',
      description: 'Create database migration',
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'Migration name' },
          repo: { type: 'string', description: 'Target repository' },
        },
        required: ['name'],
      },
    },
    {
      name: 'optimize_query',
      description: 'Optimize slow query',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Query to optimize' },
          repo: { type: 'string', description: 'Target repository' },
        },
        required: ['query'],
      },
    },
    {
      name: 'add_indexes',
      description: 'Add database indexes',
      inputSchema: {
        type: 'object',
        properties: {
          table: { type: 'string', description: 'Table name' },
          columns: { type: 'string', description: 'Comma-separated columns' },
          repo: { type: 'string', description: 'Target repository' },
        },
        required: ['table'],
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
