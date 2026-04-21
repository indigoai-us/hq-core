#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  {
    name: 'project-manager',
    version: '1.0.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'next_issue',
        description: 'Select next issue from project PRD/beads to work on',
        inputSchema: {
          type: 'object',
          properties: {
            project: {
              type: 'string',
              description: 'Project name',
            },
            filter: {
              type: 'string',
              description: 'Filter by label (optional)',
            },
            priority: {
              type: 'string',
              enum: ['high', 'medium', 'low'],
              description: 'Filter by priority (optional)',
            },
          },
          required: ['project'],
        },
      },
      {
        name: 'create_prd',
        description: 'Create new PRD from requirements',
        inputSchema: {
          type: 'object',
          properties: {
            name: {
              type: 'string',
              description: 'Project name',
            },
            input: {
              type: 'string',
              description: 'Path to input requirements file (optional)',
            },
            template: {
              type: 'string',
              enum: ['feature', 'bugfix', 'refactor'],
              description: 'Template type (optional, default: feature)',
            },
          },
          required: ['name'],
        },
      },
      {
        name: 'update_learnings',
        description: 'Route learnings to appropriate knowledge locations',
        inputSchema: {
          type: 'object',
          properties: {
            project: {
              type: 'string',
              description: 'Project context (optional)',
            },
            learnings: {
              type: 'array',
              items: {
                type: 'object',
                properties: {
                  type: {
                    type: 'string',
                    enum: ['project', 'pattern', 'troubleshoot', 'workflow'],
                  },
                  category: {
                    type: 'string',
                    description: 'Category for patterns (e.g., backend, frontend)',
                  },
                  content: {
                    type: 'string',
                    description: 'The learning content',
                  },
                },
                required: ['type', 'content'],
              },
              description: 'Array of learnings to route',
            },
            dryRun: {
              type: 'boolean',
              description: 'Show routing without writing (optional)',
            },
          },
          required: ['learnings'],
        },
      },
      {
        name: 'project_status',
        description: 'Show project progress and blockers',
        inputSchema: {
          type: 'object',
          properties: {
            project: {
              type: 'string',
              description: 'Project name',
            },
            verbose: {
              type: 'boolean',
              description: 'Show detailed story status (optional)',
            },
            format: {
              type: 'string',
              enum: ['table', 'json', 'markdown'],
              description: 'Output format (optional, default: table)',
            },
          },
          required: ['project'],
        },
      },
    ],
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case 'next_issue': {
        // Import and call the skill
        const { nextIssue } = await import('./skills/next-issue');
        // Capture console output
        const result = await captureOutput(() => nextIssue(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      case 'create_prd': {
        const { createPrd } = await import('./skills/create-prd');
        const result = await captureOutput(() => createPrd(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      case 'update_learnings': {
        const { updateLearnings } = await import('./skills/update-learnings');
        const result = await captureOutput(() => updateLearnings(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      case 'project_status': {
        const { projectStatus } = await import('./skills/project-status');
        const result = await captureOutput(() => projectStatus(args as any));
        return { content: [{ type: 'text', text: result }] };
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: 'text', text: `Error: ${message}` }],
      isError: true,
    };
  }
});

// Helper to capture console output
async function captureOutput(fn: () => Promise<void>): Promise<string> {
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

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
