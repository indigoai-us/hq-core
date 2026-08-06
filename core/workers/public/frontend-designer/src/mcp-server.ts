#!/usr/bin/env node
/**
 * Frontend Designer MCP Server
 *
 * Exposes frontend design tools via Model Context Protocol
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WORKER_ROOT = join(__dirname, '..');
const SKILL_PATH = join(WORKER_ROOT, 'skills', 'frontend-design', 'SKILL.md');

function loadSkill(): string {
  if (!existsSync(SKILL_PATH)) {
    return '# Skill not found\n\nPlease install the frontend-design skill.';
  }
  return readFileSync(SKILL_PATH, 'utf-8');
}

const server = new Server(
  {
    name: 'frontend-designer',
    version: '1.0.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'design_component',
      description: 'Generate a single React component with bold, distinctive aesthetics. Returns a prompt with embedded skill instructions for Claude to execute.',
      inputSchema: {
        type: 'object',
        properties: {
          name: {
            type: 'string',
            description: 'Component name (e.g., "HeroSection", "PricingCard")',
          },
          prompt: {
            type: 'string',
            description: 'Design description (e.g., "Brutalist hero with bold typography and grain texture")',
          },
          outputPath: {
            type: 'string',
            description: 'Output directory path (optional)',
          },
        },
        required: ['name', 'prompt'],
      },
    },
    {
      name: 'design_page',
      description: 'Generate a full page layout (landing page, dashboard, etc.) with distinctive aesthetics.',
      inputSchema: {
        type: 'object',
        properties: {
          name: {
            type: 'string',
            description: 'Page name (e.g., "LandingPage", "Dashboard")',
          },
          prompt: {
            type: 'string',
            description: 'Design description (e.g., "Luxury SaaS landing page with editorial typography")',
          },
          outputPath: {
            type: 'string',
            description: 'Output directory path (optional)',
          },
        },
        required: ['name', 'prompt'],
      },
    },
    {
      name: 'design_system',
      description: 'Create a component library with consistent aesthetic across multiple components.',
      inputSchema: {
        type: 'object',
        properties: {
          name: {
            type: 'string',
            description: 'Design system name (e.g., "CoreUI")',
          },
          prompt: {
            type: 'string',
            description: 'Design system description and aesthetic direction',
          },
          components: {
            type: 'array',
            items: { type: 'string' },
            description: 'List of components to generate (e.g., ["Button", "Card", "Input"])',
          },
          outputPath: {
            type: 'string',
            description: 'Output directory path (optional)',
          },
        },
        required: ['name', 'prompt'],
      },
    },
    {
      name: 'refine_design',
      description: 'Iterate on an existing component with specific feedback.',
      inputSchema: {
        type: 'object',
        properties: {
          filePath: {
            type: 'string',
            description: 'Path to existing component file',
          },
          feedback: {
            type: 'string',
            description: 'What to improve (e.g., "More contrast, bigger headlines, add grain texture")',
          },
        },
        required: ['filePath', 'feedback'],
      },
    },
    {
      name: 'get_skill',
      description: 'Get the frontend-design skill instructions. Use this to understand design principles before generating.',
      inputSchema: {
        type: 'object',
        properties: {},
        required: [],
      },
    },
  ],
}));

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const skill = loadSkill();

  switch (name) {
    case 'design_component': {
      const { name: componentName, prompt, outputPath } = args as {
        name: string;
        prompt: string;
        outputPath?: string;
      };

      const fullPrompt = `${skill}

---

## Task: Generate Component

**Name:** ${componentName}
**Description:** ${prompt}

Generate production-ready React + TypeScript code with:
- Tailwind CSS for styling
- shadcn/ui components where appropriate
- Framer Motion for animations (if needed)
- Proper TypeScript types

Remember: NO generic aesthetics. Be BOLD and DISTINCTIVE.
`;

      if (outputPath) {
        if (!existsSync(outputPath)) {
          mkdirSync(outputPath, { recursive: true });
        }
        const promptFile = join(outputPath, `${componentName}.prompt.md`);
        writeFileSync(promptFile, fullPrompt);
        return {
          content: [
            {
              type: 'text',
              text: `Prompt saved to: ${promptFile}\n\nUse this prompt to generate the component.`,
            },
          ],
        };
      }

      return {
        content: [
          {
            type: 'text',
            text: fullPrompt,
          },
        ],
      };
    }

    case 'design_page': {
      const { name: pageName, prompt, outputPath } = args as {
        name: string;
        prompt: string;
        outputPath?: string;
      };

      const fullPrompt = `${skill}

---

## Task: Generate Page

**Name:** ${pageName}
**Description:** ${prompt}

Generate a complete page with:
- React + TypeScript
- Tailwind CSS for styling
- shadcn/ui components where appropriate
- Framer Motion for page transitions and micro-interactions
- Proper component composition

Create multiple components as needed for the page layout.
Remember: NO generic aesthetics. Be BOLD and DISTINCTIVE.
`;

      if (outputPath) {
        if (!existsSync(outputPath)) {
          mkdirSync(outputPath, { recursive: true });
        }
        const promptFile = join(outputPath, `${pageName}.prompt.md`);
        writeFileSync(promptFile, fullPrompt);
        return {
          content: [
            {
              type: 'text',
              text: `Prompt saved to: ${promptFile}\n\nUse this prompt to generate the page.`,
            },
          ],
        };
      }

      return {
        content: [
          {
            type: 'text',
            text: fullPrompt,
          },
        ],
      };
    }

    case 'design_system': {
      const { name: systemName, prompt, components, outputPath } = args as {
        name: string;
        prompt: string;
        components?: string[];
        outputPath?: string;
      };

      const componentList = components?.join(', ') || 'Button, Card, Input, Modal';

      const fullPrompt = `${skill}

---

## Task: Generate Design System

**Name:** ${systemName}
**Description:** ${prompt}
**Components:** ${componentList}

Generate a cohesive design system with:
- Shared CSS variables for colors, spacing, typography
- Consistent aesthetic across all components
- React + TypeScript implementation
- Tailwind CSS configuration
- Component variants (size, color, state)

Structure:
- /components - Individual component files
- /styles - Shared styles and Tailwind config
- /types - Shared TypeScript types

Remember: Every component should feel like part of the same family.
NO generic aesthetics. Be BOLD and DISTINCTIVE.
`;

      if (outputPath) {
        if (!existsSync(outputPath)) {
          mkdirSync(outputPath, { recursive: true });
        }
        const promptFile = join(outputPath, `${systemName}.prompt.md`);
        writeFileSync(promptFile, fullPrompt);
        return {
          content: [
            {
              type: 'text',
              text: `Prompt saved to: ${promptFile}\n\nUse this prompt to generate the design system.`,
            },
          ],
        };
      }

      return {
        content: [
          {
            type: 'text',
            text: fullPrompt,
          },
        ],
      };
    }

    case 'refine_design': {
      const { filePath, feedback } = args as {
        filePath: string;
        feedback: string;
      };

      if (!existsSync(filePath)) {
        return {
          content: [
            {
              type: 'text',
              text: `Error: File not found: ${filePath}`,
            },
          ],
          isError: true,
        };
      }

      const existingCode = readFileSync(filePath, 'utf-8');

      const fullPrompt = `${skill}

---

## Task: Refine Existing Component

**File:** ${filePath}
**Feedback:** ${feedback}

**Existing Code:**
\`\`\`tsx
${existingCode}
\`\`\`

Improve the component based on the feedback while maintaining the same structure.
Apply the frontend-design skill principles to make it more distinctive.

Return the complete updated component code.
`;

      return {
        content: [
          {
            type: 'text',
            text: fullPrompt,
          },
        ],
      };
    }

    case 'get_skill': {
      return {
        content: [
          {
            type: 'text',
            text: skill,
          },
        ],
      };
    }

    default:
      return {
        content: [
          {
            type: 'text',
            text: `Unknown tool: ${name}`,
          },
        ],
        isError: true,
      };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error('Frontend Designer MCP server running');
}

main().catch(console.error);
