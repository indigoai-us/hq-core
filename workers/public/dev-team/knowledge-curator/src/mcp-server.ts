#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  { name: 'knowledge-curator', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'process_learnings',
      description: 'Process learnings from completed tasks and route to appropriate locations',
      inputSchema: {
        type: 'object',
        properties: {
          learnings: { type: 'object', description: 'Learnings JSON object' },
          project: { type: 'string', description: 'Source project name' },
          worker: { type: 'string', description: 'Source worker ID' },
          task: { type: 'string', description: 'Source task ID' },
        },
        required: ['learnings'],
      },
    },
    {
      name: 'update_patterns',
      description: 'Update or create reusable patterns in the knowledge base',
      inputSchema: {
        type: 'object',
        properties: {
          category: { type: 'string', enum: ['backend', 'frontend', 'database', 'infra', 'testing', 'security'], description: 'Pattern category' },
          pattern: { type: 'string', description: 'Specific pattern name' },
          content: { type: 'string', description: 'Pattern content in markdown' },
        },
        required: ['category'],
      },
    },
    {
      name: 'curate_troubleshooting',
      description: 'Add or update troubleshooting entries for common issues',
      inputSchema: {
        type: 'object',
        properties: {
          issue: { type: 'string', description: 'Issue description' },
          solution: { type: 'string', description: 'Solution that worked' },
          category: { type: 'string', enum: ['build', 'runtime', 'database', 'network', 'auth', 'deploy', 'performance'], description: 'Issue category' },
          tags: { type: 'array', items: { type: 'string' }, description: 'Tags for searchability' },
        },
        required: ['issue'],
      },
    },
    {
      name: 'sync_documentation',
      description: 'Sync and update documentation across the HQ system',
      inputSchema: {
        type: 'object',
        properties: {
          scope: { type: 'string', enum: ['worker', 'project', 'knowledge', 'all'], description: 'Documentation scope' },
          target: { type: 'string', description: 'Specific file to update' },
          dry_run: { type: 'boolean', description: 'Preview changes without writing' },
        },
        required: ['scope'],
      },
    },
    {
      name: 'search_knowledge',
      description: 'Search the knowledge base for relevant information',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Search query' },
          scope: { type: 'string', enum: ['patterns', 'troubleshooting', 'workflows', 'all'], description: 'Search scope' },
        },
        required: ['query'],
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
