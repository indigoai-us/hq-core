/**
 * v0.dev Platform API Integration
 *
 * DISABLED BY DEFAULT - Enable when V0_API_KEY is available
 *
 * v0 Platform API: https://vercel.com/blog/build-your-own-ai-app-builder-with-the-v0-platform-api
 */

import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SETTINGS_PATH = join(__dirname, '..', '..', '..', '..', '..', 'settings', 'v0', 'credentials.json');

interface V0Credentials {
  api_key: string;
}

interface V0ChatResponse {
  files: Array<{
    name: string;
    content: string;
  }>;
  demo: string;  // Live preview URL
  url: string;   // v0.dev chat URL
}

interface GenerateOptions {
  prompt: string;
  context?: string[];  // Existing files for context
}

/**
 * Check if v0 integration is enabled and configured
 */
export function isV0Enabled(): boolean {
  if (!existsSync(SETTINGS_PATH)) {
    return false;
  }

  try {
    const creds = JSON.parse(readFileSync(SETTINGS_PATH, 'utf-8')) as V0Credentials;
    return Boolean(creds.api_key);
  } catch {
    return false;
  }
}

/**
 * Get v0 API credentials
 */
function getCredentials(): V0Credentials | null {
  if (!existsSync(SETTINGS_PATH)) {
    return null;
  }

  try {
    return JSON.parse(readFileSync(SETTINGS_PATH, 'utf-8')) as V0Credentials;
  } catch {
    return null;
  }
}

/**
 * Generate UI with v0 Platform API
 *
 * Requires v0-sdk: npm install v0-sdk
 *
 * @example
 * const result = await generateWithV0({
 *   prompt: "Build a todo app with React and TypeScript"
 * });
 * console.log(result.files);  // Generated code files
 * console.log(result.demo);   // Live preview URL
 */
export async function generateWithV0(options: GenerateOptions): Promise<V0ChatResponse | null> {
  const creds = getCredentials();

  if (!creds) {
    console.error('v0 credentials not found. Create settings/v0/credentials.json with api_key.');
    return null;
  }

  // NOTE: Uncomment when v0-sdk is installed
  // import { v0 } from 'v0-sdk';
  //
  // const chat = await v0.chats.create({
  //   message: options.prompt,
  //   files: options.context
  // });
  //
  // return {
  //   files: chat.files || [],
  //   demo: chat.demo,
  //   url: chat.url
  // };

  console.log('v0 integration is scaffolded but not active.');
  console.log('To enable:');
  console.log('1. npm install v0-sdk');
  console.log('2. Add API key to settings/v0/credentials.json');
  console.log('3. Uncomment the v0 SDK code in this file');

  return null;
}

/**
 * Refine existing code with v0
 */
export async function refineWithV0(
  existingCode: string,
  feedback: string
): Promise<V0ChatResponse | null> {
  return generateWithV0({
    prompt: `Improve this code:\n\n${existingCode}\n\nFeedback: ${feedback}`,
    context: [existingCode]
  });
}
