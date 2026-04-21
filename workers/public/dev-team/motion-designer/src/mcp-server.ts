#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const server = new Server(
  { name: 'motion-designer', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'add_animation',
      description: 'Add animation to component',
      inputSchema: {
        type: 'object',
        properties: {
          component: { type: 'string', description: 'Component name' },
          repo: { type: 'string', description: 'Target repository' },
          type: { type: 'string', enum: ['entrance', 'exit', 'hover', 'loop'], description: 'Animation type' },
          library: { type: 'string', enum: ['framer', 'gsap', 'css'], description: 'Animation library' },
        },
        required: ['component'],
      },
    },
    {
      name: 'add_transition',
      description: 'Add page/element transition',
      inputSchema: {
        type: 'object',
        properties: {
          target: { type: 'string', description: 'Target element or page' },
          repo: { type: 'string', description: 'Target repository' },
        },
        required: ['target'],
      },
    },
    {
      name: 'polish_component',
      description: 'Polish visual design of component',
      inputSchema: {
        type: 'object',
        properties: {
          component: { type: 'string', description: 'Component name' },
          repo: { type: 'string', description: 'Target repository' },
        },
        required: ['component'],
      },
    },
    {
      name: 'generate_image',
      description: 'Generate image via gnb (gemini-nano-banana)',
      inputSchema: {
        type: 'object',
        properties: {
          prompt: { type: 'string', description: 'Image prompt' },
          aspect: { type: 'string', enum: ['1:1', '16:9', '9:16', '4:3'], description: 'Aspect ratio' },
          variants: { type: 'number', description: 'Number of variants (max 10)' },
          output: { type: 'string', description: 'Output directory' },
          type: { type: 'string', enum: ['logo', 'social', 'thumbnail'], description: 'Preset type' },
        },
        required: ['prompt'],
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
