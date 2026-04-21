#!/usr/bin/env node
import 'dotenv/config';
import * as fs from 'fs';
import * as path from 'path';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { CodexClient, type CodexResult } from './codex-client';

const server = new Server(
  { name: 'codex-engine', version: '1.0.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'codex_generate',
        description: 'Generate new code from a task description using Codex',
        inputSchema: {
          type: 'object' as const,
          properties: {
            task: { type: 'string', description: 'Task description for code generation' },
            cwd: { type: 'string', description: 'Working directory for the Codex session' },
            contextFiles: {
              type: 'array',
              items: { type: 'string' },
              description: 'Paths to context files (max 10, max 50KB total)',
            },
            outputSchema: {
              type: 'object',
              description: 'Optional JSON schema for structured output',
            },
          },
          required: ['task', 'cwd'],
        },
      },
      {
        name: 'codex_review',
        description: 'Analyze code for quality issues using Codex',
        inputSchema: {
          type: 'object' as const,
          properties: {
            cwd: { type: 'string', description: 'Working directory for the Codex session' },
            files: {
              type: 'array',
              items: { type: 'string' },
              description: 'Files to review',
            },
            focus: {
              type: 'string',
              enum: ['security', 'performance', 'style', 'correctness', 'all'],
              description: 'Review focus area',
            },
          },
          required: ['cwd', 'files'],
        },
      },
      {
        name: 'codex_debug',
        description: 'Diagnose and fix issues using Codex',
        inputSchema: {
          type: 'object' as const,
          properties: {
            cwd: { type: 'string', description: 'Working directory for the Codex session' },
            issue: { type: 'string', description: 'Issue description' },
            errorOutput: { type: 'string', description: 'Error output from failing command' },
            relevantFiles: {
              type: 'array',
              items: { type: 'string' },
              description: 'Files related to the issue',
            },
          },
          required: ['cwd', 'issue'],
        },
      },
      {
        name: 'codex_improve',
        description: 'Apply best-practice improvements to code using Codex',
        inputSchema: {
          type: 'object' as const,
          properties: {
            cwd: { type: 'string', description: 'Working directory for the Codex session' },
            files: {
              type: 'array',
              items: { type: 'string' },
              description: 'Files to improve',
            },
            goals: {
              type: 'array',
              items: { type: 'string' },
              description: 'Improvement goals (e.g., error handling, type safety)',
            },
          },
          required: ['cwd', 'files'],
        },
      },
      {
        name: 'codex_exec',
        description: 'Run an arbitrary Codex task — catch-all for tasks that don\'t fit generate/review/debug/improve',
        inputSchema: {
          type: 'object' as const,
          properties: {
            prompt: { type: 'string', description: 'Task prompt for Codex' },
            cwd: { type: 'string', description: 'Working directory for the Codex session' },
            outputSchema: {
              type: 'object',
              description: 'Optional JSON schema for structured output',
            },
          },
          required: ['prompt', 'cwd'],
        },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case 'codex_generate': {
        const task = args?.task as string | undefined;
        const cwd = args?.cwd as string | undefined;
        const contextFiles = (args?.contextFiles ?? []) as string[];
        const outputSchema = args?.outputSchema as Record<string, unknown> | undefined;

        if (!task || !cwd) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({ error: 'Missing required arguments: task, cwd' }) }],
            isError: true,
          };
        }

        // Read context files (max 10 files, max 50KB total)
        const MAX_FILES = 10;
        const MAX_BYTES = 50 * 1024;
        let contextContent = '';
        let totalBytes = 0;
        const filesToRead = contextFiles.slice(0, MAX_FILES);

        for (const filePath of filesToRead) {
          try {
            const resolved = path.resolve(cwd, filePath);
            const stat = fs.statSync(resolved);
            if (totalBytes + stat.size > MAX_BYTES) {
              break;
            }
            const content = fs.readFileSync(resolved, 'utf-8');
            totalBytes += stat.size;
            contextContent += `\n--- ${filePath} ---\n${content}\n`;
          } catch {
            // Skip unreadable files silently
          }
        }

        // Build prompt
        let prompt = `Generate code for: ${task}`;
        if (contextContent) {
          prompt += `\n\nContext files:\n${contextContent}`;
        }

        // Create client and thread, run task
        const client = new CodexClient();
        const thread = client.createThread(cwd);
        const result: CodexResult = await client.runTask(thread, prompt, {
          outputSchema,
        });

        return {
          content: [{
            type: 'text' as const,
            text: JSON.stringify({
              summary: result.summary,
              filesCreated: result.filesChanged,
              filesModified: result.filesChanged,
              threadId: result.threadId,
              suggestions: [],
            }),
          }],
        };
      }

      case 'codex_review': {
        const cwd = args?.cwd as string | undefined;
        const files = args?.files as string[] | undefined;
        const focus = (args?.focus as string | undefined) ?? 'all';

        if (!cwd || !files || files.length === 0) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({ error: 'Missing required arguments: cwd, files (non-empty array)' }) }],
            isError: true,
          };
        }

        // Validate focus value
        const validFocusAreas = ['security', 'performance', 'style', 'correctness', 'all'] as const;
        if (!validFocusAreas.includes(focus as typeof validFocusAreas[number])) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({ error: `Invalid focus area: ${focus}. Must be one of: ${validFocusAreas.join(', ')}` }) }],
            isError: true,
          };
        }

        // Read file contents, skip non-existent files with warning
        const warnings: string[] = [];
        let fileContents = '';

        for (const filePath of files) {
          try {
            const resolved = path.resolve(cwd, filePath);
            if (!fs.existsSync(resolved)) {
              warnings.push(`Skipped non-existent file: ${filePath}`);
              continue;
            }
            const content = fs.readFileSync(resolved, 'utf-8');
            fileContents += `\n--- ${filePath} ---\n${content}\n`;
          } catch {
            warnings.push(`Skipped unreadable file: ${filePath}`);
          }
        }

        if (!fileContents) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({ error: 'No readable files found', warnings }) }],
            isError: true,
          };
        }

        // Build focus-specific review instructions
        const focusInstructions: Record<string, string> = {
          security: 'Check for injection, auth bypass, secret exposure, XSS, CSRF',
          performance: 'Check for N+1 queries, memory leaks, unnecessary re-renders, blocking operations',
          style: 'Check naming conventions, code patterns, readability, consistency',
          correctness: 'Check logic errors, edge cases, off-by-one, null handling',
        };

        let reviewFocus: string;
        if (focus === 'all') {
          reviewFocus = Object.values(focusInstructions).join('. ');
        } else {
          reviewFocus = focusInstructions[focus] ?? '';
        }

        const reviewPrompt = `Review the following code files. Focus: ${reviewFocus}\n\nFiles:\n${fileContents}`;

        // Structured output schema for the review
        const reviewOutputSchema = {
          type: 'object' as const,
          properties: {
            overallScore: { type: 'number' as const, description: 'Overall code quality score from 1 (worst) to 10 (best)' },
            issues: {
              type: 'array' as const,
              items: {
                type: 'object' as const,
                properties: {
                  file: { type: 'string' as const },
                  line: { type: 'number' as const },
                  severity: { type: 'string' as const, enum: ['critical', 'high', 'medium', 'low'] },
                  category: { type: 'string' as const },
                  description: { type: 'string' as const },
                  suggestedFix: { type: 'string' as const },
                },
                required: ['file', 'line', 'severity', 'category', 'description', 'suggestedFix'],
              },
            },
            summary: { type: 'string' as const },
          },
          required: ['overallScore', 'issues', 'summary'],
        };

        const reviewClient = new CodexClient();
        const reviewThread = reviewClient.createThread(cwd);
        const reviewResult: CodexResult = await reviewClient.runTask(reviewThread, reviewPrompt, {
          outputSchema: reviewOutputSchema,
        });

        // Parse structured response — fallback to raw response if not valid JSON
        let parsedReview: { overallScore?: number; issues?: unknown[]; summary?: string };
        try {
          parsedReview = JSON.parse(reviewResult.response) as { overallScore?: number; issues?: unknown[]; summary?: string };
        } catch {
          parsedReview = {
            overallScore: 0,
            issues: [],
            summary: reviewResult.response,
          };
        }

        return {
          content: [{
            type: 'text' as const,
            text: JSON.stringify({
              overallScore: parsedReview.overallScore ?? 0,
              issues: parsedReview.issues ?? [],
              summary: parsedReview.summary ?? reviewResult.summary,
              threadId: reviewResult.threadId,
              ...(warnings.length > 0 ? { warnings } : {}),
            }),
          }],
        };
      }

      case 'codex_debug': {
        const debugCwd = args?.cwd as string | undefined;
        const issue = args?.issue as string | undefined;
        const errorOutput = args?.errorOutput as string | undefined;
        const relevantFiles = (args?.relevantFiles ?? []) as string[];

        if (!debugCwd || !issue) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({ error: 'Missing required arguments: cwd, issue' }) }],
            isError: true,
          };
        }

        // Read relevant files from disk, skip non-existent
        const debugWarnings: string[] = [];
        let debugFileContents = '';

        for (const filePath of relevantFiles) {
          try {
            const resolved = path.resolve(debugCwd, filePath);
            if (!fs.existsSync(resolved)) {
              debugWarnings.push(`Skipped non-existent file: ${filePath}`);
              continue;
            }
            const content = fs.readFileSync(resolved, 'utf-8');
            debugFileContents += `\n--- ${filePath} ---\n${content}\n`;
          } catch {
            debugWarnings.push(`Skipped unreadable file: ${filePath}`);
          }
        }

        // Build prompt
        let debugPrompt = `Diagnose and fix: ${issue}`;
        if (errorOutput) {
          debugPrompt += `\n\nError output:\n${errorOutput}`;
        }
        if (debugFileContents) {
          debugPrompt += `\n\nRelevant files:\n${debugFileContents}`;
        }

        // Structured output schema for debug analysis
        const debugOutputSchema = {
          type: 'object' as const,
          properties: {
            rootCause: { type: 'string' as const, description: 'Root cause of the issue' },
            affectedFiles: {
              type: 'array' as const,
              items: { type: 'string' as const },
              description: 'Files affected by the issue',
            },
            fix: {
              type: 'object' as const,
              properties: {
                description: { type: 'string' as const, description: 'Description of the fix applied' },
                filesModified: {
                  type: 'array' as const,
                  items: { type: 'string' as const },
                  description: 'Files modified by the fix',
                },
              },
              required: ['description', 'filesModified'] as const,
            },
            confidence: {
              type: 'string' as const,
              enum: ['high', 'medium', 'low'],
              description: 'Confidence level of the diagnosis',
            },
          },
          required: ['rootCause', 'affectedFiles', 'fix', 'confidence'] as const,
        };

        // Full-auto mode — Codex applies fixes in cwd
        const debugClient = new CodexClient();
        const debugThread = debugClient.createThread(debugCwd);
        const debugResult: CodexResult = await debugClient.runTask(debugThread, debugPrompt, {
          outputSchema: debugOutputSchema,
        });

        // Parse structured response — fallback to raw response if not valid JSON
        let parsedDebug: {
          rootCause?: string;
          affectedFiles?: string[];
          fix?: { description?: string; filesModified?: string[] };
          confidence?: string;
        };
        try {
          parsedDebug = JSON.parse(debugResult.response) as typeof parsedDebug;
        } catch {
          parsedDebug = {
            rootCause: debugResult.response,
            affectedFiles: [],
            fix: { description: debugResult.summary, filesModified: debugResult.filesChanged },
            confidence: 'low',
          };
        }

        return {
          content: [{
            type: 'text' as const,
            text: JSON.stringify({
              rootCause: parsedDebug.rootCause ?? debugResult.response,
              affectedFiles: parsedDebug.affectedFiles ?? [],
              fix: parsedDebug.fix ?? { description: '', filesModified: [] },
              confidence: parsedDebug.confidence ?? 'low',
              threadId: debugResult.threadId,
              ...(debugWarnings.length > 0 ? { warnings: debugWarnings } : {}),
            }),
          }],
        };
      }

      case 'codex_improve': {
        const improveCwd = args?.cwd as string | undefined;
        const improveFiles = args?.files as string[] | undefined;
        const goals = (args?.goals as string[] | undefined) ?? [
          'readability', 'error handling', 'type safety', 'performance', 'best practices',
        ];

        if (!improveCwd || !improveFiles || improveFiles.length === 0) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({ error: 'Missing required arguments: cwd, files (non-empty array)' }) }],
            isError: true,
          };
        }

        // Read files, skip non-existent
        const improveWarnings: string[] = [];
        let improveFileContents = '';

        for (const filePath of improveFiles) {
          try {
            const resolved = path.resolve(improveCwd, filePath);
            if (!fs.existsSync(resolved)) {
              improveWarnings.push(`Skipped non-existent file: ${filePath}`);
              continue;
            }
            const content = fs.readFileSync(resolved, 'utf-8');
            improveFileContents += `\n--- ${filePath} ---\n${content}\n`;
          } catch {
            improveWarnings.push(`Skipped unreadable file: ${filePath}`);
          }
        }

        if (!improveFileContents) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({ error: 'No readable files found', warnings: improveWarnings }) }],
            isError: true,
          };
        }

        // Build prompt with goals
        const goalsText = goals.map((g, i) => `${i + 1}. ${g}`).join('\n');
        const improvePrompt = `Apply improvements to these files.\n\nGoals:\n${goalsText}\n\nFiles:\n${improveFileContents}`;

        // Structured output schema for improvements
        const improveOutputSchema = {
          type: 'object' as const,
          properties: {
            improvements: {
              type: 'array' as const,
              items: {
                type: 'object' as const,
                properties: {
                  file: { type: 'string' as const },
                  description: { type: 'string' as const },
                  before: { type: 'string' as const },
                  after: { type: 'string' as const },
                },
                required: ['file', 'description', 'before', 'after'] as const,
              },
            },
            summary: { type: 'string' as const, description: 'Overall summary of improvements' },
            filesModified: {
              type: 'array' as const,
              items: { type: 'string' as const },
              description: 'List of files that were modified',
            },
          },
          required: ['improvements', 'summary', 'filesModified'] as const,
        };

        // Full-auto mode — Codex modifies files in cwd
        const improveClient = new CodexClient();
        const improveThread = improveClient.createThread(improveCwd);
        const improveResult: CodexResult = await improveClient.runTask(improveThread, improvePrompt, {
          outputSchema: improveOutputSchema,
        });

        // Parse structured response — fallback to raw response if not valid JSON
        let parsedImprove: {
          improvements?: Array<{ file: string; description: string; before: string; after: string }>;
          summary?: string;
          filesModified?: string[];
        };
        try {
          parsedImprove = JSON.parse(improveResult.response) as typeof parsedImprove;
        } catch {
          parsedImprove = {
            improvements: [],
            summary: improveResult.response,
            filesModified: improveResult.filesChanged,
          };
        }

        return {
          content: [{
            type: 'text' as const,
            text: JSON.stringify({
              improvements: parsedImprove.improvements ?? [],
              summary: parsedImprove.summary ?? improveResult.summary,
              filesModified: parsedImprove.filesModified ?? improveResult.filesChanged,
              threadId: improveResult.threadId,
              ...(improveWarnings.length > 0 ? { warnings: improveWarnings } : {}),
            }),
          }],
        };
      }

      case 'codex_exec': {
        const execPrompt = args?.prompt as string | undefined;
        const execCwd = args?.cwd as string | undefined;
        const execOutputSchema = args?.outputSchema as Record<string, unknown> | undefined;

        if (!execPrompt || !execCwd) {
          return {
            content: [{ type: 'text' as const, text: JSON.stringify({ error: 'Missing required arguments: prompt, cwd' }) }],
            isError: true,
          };
        }

        const execClient = new CodexClient();
        const execThread = execClient.createThread(execCwd);
        const execResult: CodexResult = await execClient.runTask(execThread, execPrompt, {
          outputSchema: execOutputSchema,
        });

        return {
          content: [{
            type: 'text' as const,
            text: JSON.stringify({
              response: execResult.response,
              summary: execResult.summary,
              filesChanged: execResult.filesChanged,
              threadId: execResult.threadId,
            }),
          }],
        };
      }

      default:
        return {
          content: [{ type: 'text' as const, text: `Unknown tool: ${name}` }],
          isError: true,
        };
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: 'text' as const, text: `Error: ${message}` }],
      isError: true,
    };
  }
});

async function main(): Promise<void> {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
