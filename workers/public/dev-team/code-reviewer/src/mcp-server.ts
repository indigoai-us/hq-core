#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  { name: 'code-reviewer', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'review_pr',
      description: 'Review a pull request for code quality and correctness',
      inputSchema: {
        type: 'object',
        properties: {
          pr: { type: 'number', description: 'PR number' },
          repo: { type: 'string', description: 'Target repository path' },
          focus: { type: 'string', enum: ['security', 'performance', 'style', 'all'], description: 'Review focus area' },
          strict: { type: 'boolean', description: 'Enable strict review mode' },
        },
        required: ['pr'],
      },
    },
    {
      name: 'merge_to_staging',
      description: 'Merge approved PR to staging branch',
      inputSchema: {
        type: 'object',
        properties: {
          pr: { type: 'number', description: 'PR number' },
          repo: { type: 'string', description: 'Target repository path' },
        },
        required: ['pr'],
      },
    },
    {
      name: 'merge_to_production',
      description: 'Merge staging to production (requires human approval)',
      inputSchema: {
        type: 'object',
        properties: {
          repo: { type: 'string', description: 'Target repository path' },
          tag: { type: 'string', description: 'Version tag to create' },
        },
        required: ['repo'],
      },
    },
    {
      name: 'request_changes',
      description: 'Request changes on a pull request',
      inputSchema: {
        type: 'object',
        properties: {
          pr: { type: 'number', description: 'PR number' },
          repo: { type: 'string', description: 'Target repository path' },
          blocking: { type: 'boolean', description: 'Mark as blocking review' },
        },
        required: ['pr'],
      },
    },
    {
      name: 'get_pr_diff',
      description: 'Get the diff for a pull request',
      inputSchema: {
        type: 'object',
        properties: {
          pr: { type: 'number', description: 'PR number' },
          repo: { type: 'string', description: 'Target repository path' },
        },
        required: ['pr'],
      },
    },
    {
      name: 'list_pr_comments',
      description: 'List comments on a pull request',
      inputSchema: {
        type: 'object',
        properties: {
          pr: { type: 'number', description: 'PR number' },
          repo: { type: 'string', description: 'Target repository path' },
        },
        required: ['pr'],
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
