import * as fs from 'fs';
import * as path from 'path';

interface ApiDesignOptions {
  endpoint?: string;
  feature?: string;
  repo?: string;
  format?: 'openapi' | 'typescript';
}

interface EndpointSpec {
  method: string;
  path: string;
  description: string;
  request?: Record<string, string>;
  response: Record<string, string>;
  errors: string[];
  auth: boolean;
}

export async function apiDesign(options: ApiDesignOptions): Promise<void> {
  const { endpoint, feature, repo, format = 'typescript' } = options;

  const target = endpoint || feature;
  console.log(`\n=== API Design: ${target} ===\n`);

  // Analyze existing API patterns if repo provided
  if (repo) {
    console.log('Analyzing existing API patterns...');
    const patterns = analyzeApiPatterns(repo);
    console.log('\nExisting conventions:');
    for (const pattern of patterns) {
      console.log(`  - ${pattern}`);
    }
  }

  // Generate endpoint specifications
  const endpoints = generateEndpoints(target!);

  console.log('\n' + '-'.repeat(40));
  console.log('\nProposed endpoints:\n');

  for (const ep of endpoints) {
    console.log(`${ep.method} ${ep.path}`);
    console.log(`  ${ep.description}`);
    if (ep.request) {
      console.log(`  Request: ${JSON.stringify(ep.request)}`);
    }
    console.log(`  Response: ${JSON.stringify(ep.response)}`);
    if (ep.errors.length > 0) {
      console.log(`  Errors: ${ep.errors.join(', ')}`);
    }
    console.log(`  Auth: ${ep.auth ? 'Required' : 'None'}`);
    console.log();
  }

  // Generate TypeScript interfaces
  if (format === 'typescript') {
    console.log('-'.repeat(40));
    console.log('\nGenerated TypeScript interfaces:\n');
    console.log(generateTypeScriptInterfaces(endpoints, target!));
  }

  console.log('\n[Human approval required]');
  console.log('Approve contract? [y/n/modify]');

  console.log('\nOn approval, will generate:');
  console.log('  - Type definitions in src/types/');
  console.log('  - API route stubs (if Next.js detected)');
  console.log('  - Validation schemas');
}

function analyzeApiPatterns(repoPath: string): string[] {
  const patterns: string[] = [];

  // Check for API directory structure
  const apiDirs = [
    'src/app/api',
    'src/pages/api',
    'pages/api',
    'api',
  ];

  for (const dir of apiDirs) {
    const fullPath = path.join(repoPath, dir);
    if (fs.existsSync(fullPath)) {
      patterns.push(`API routes in ${dir}`);
      break;
    }
  }

  // Check for common API patterns
  const pkgPath = path.join(repoPath, 'package.json');
  if (fs.existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8'));
      const deps = { ...pkg.dependencies, ...pkg.devDependencies };

      if (deps['zod']) patterns.push('Zod validation');
      if (deps['@trpc/server']) patterns.push('tRPC');
      if (deps['express']) patterns.push('Express.js');
      if (deps['next']) patterns.push('Next.js API routes');
    } catch (e) {
      // Ignore
    }
  }

  if (patterns.length === 0) {
    patterns.push('(No existing patterns detected)');
  }

  return patterns;
}

function generateEndpoints(target: string): EndpointSpec[] {
  const targetLower = target.toLowerCase();

  // Auth-related endpoints
  if (targetLower.includes('auth') || targetLower.includes('login')) {
    return [
      {
        method: 'POST',
        path: '/api/auth/login',
        description: 'Authenticate user with credentials',
        request: { email: 'string', password: 'string', rememberMe: 'boolean?' },
        response: { user: 'User', token: 'string', expiresAt: 'string' },
        errors: ['INVALID_CREDENTIALS', 'ACCOUNT_LOCKED', 'RATE_LIMITED'],
        auth: false,
      },
      {
        method: 'POST',
        path: '/api/auth/logout',
        description: 'End user session',
        response: { success: 'boolean' },
        errors: ['UNAUTHORIZED'],
        auth: true,
      },
      {
        method: 'GET',
        path: '/api/auth/me',
        description: 'Get current user profile',
        response: { user: 'User' },
        errors: ['UNAUTHORIZED'],
        auth: true,
      },
      {
        method: 'POST',
        path: '/api/auth/refresh',
        description: 'Refresh authentication token',
        request: { refreshToken: 'string' },
        response: { token: 'string', expiresAt: 'string' },
        errors: ['INVALID_TOKEN', 'EXPIRED_TOKEN'],
        auth: false,
      },
    ];
  }

  // User-related endpoints
  if (targetLower.includes('user')) {
    return [
      {
        method: 'GET',
        path: '/api/users',
        description: 'List users (paginated)',
        request: { page: 'number?', limit: 'number?' },
        response: { users: 'User[]', total: 'number', page: 'number' },
        errors: ['UNAUTHORIZED', 'FORBIDDEN'],
        auth: true,
      },
      {
        method: 'GET',
        path: '/api/users/:id',
        description: 'Get user by ID',
        response: { user: 'User' },
        errors: ['UNAUTHORIZED', 'NOT_FOUND'],
        auth: true,
      },
      {
        method: 'PATCH',
        path: '/api/users/:id',
        description: 'Update user',
        request: { name: 'string?', email: 'string?' },
        response: { user: 'User' },
        errors: ['UNAUTHORIZED', 'FORBIDDEN', 'VALIDATION_ERROR'],
        auth: true,
      },
      {
        method: 'DELETE',
        path: '/api/users/:id',
        description: 'Delete user',
        response: { success: 'boolean' },
        errors: ['UNAUTHORIZED', 'FORBIDDEN', 'NOT_FOUND'],
        auth: true,
      },
    ];
  }

  // Generic CRUD endpoints
  const resource = target.replace(/[^a-zA-Z]/g, '').toLowerCase();
  const Resource = resource.charAt(0).toUpperCase() + resource.slice(1);

  return [
    {
      method: 'GET',
      path: `/api/${resource}`,
      description: `List ${resource} (paginated)`,
      request: { page: 'number?', limit: 'number?' },
      response: { items: `${Resource}[]`, total: 'number' },
      errors: ['UNAUTHORIZED'],
      auth: true,
    },
    {
      method: 'POST',
      path: `/api/${resource}`,
      description: `Create ${resource}`,
      request: { '...fields': 'varies' },
      response: { item: Resource },
      errors: ['UNAUTHORIZED', 'VALIDATION_ERROR'],
      auth: true,
    },
    {
      method: 'GET',
      path: `/api/${resource}/:id`,
      description: `Get ${resource} by ID`,
      response: { item: Resource },
      errors: ['UNAUTHORIZED', 'NOT_FOUND'],
      auth: true,
    },
    {
      method: 'PATCH',
      path: `/api/${resource}/:id`,
      description: `Update ${resource}`,
      request: { '...fields': 'varies' },
      response: { item: Resource },
      errors: ['UNAUTHORIZED', 'NOT_FOUND', 'VALIDATION_ERROR'],
      auth: true,
    },
    {
      method: 'DELETE',
      path: `/api/${resource}/:id`,
      description: `Delete ${resource}`,
      response: { success: 'boolean' },
      errors: ['UNAUTHORIZED', 'NOT_FOUND'],
      auth: true,
    },
  ];
}

function generateTypeScriptInterfaces(endpoints: EndpointSpec[], target: string): string {
  const lines: string[] = [];
  const targetLower = target.toLowerCase();

  // Determine main entity type
  let entityName = 'Item';
  if (targetLower.includes('user') || targetLower.includes('auth')) {
    entityName = 'User';
  }

  lines.push(`// API Types for: ${target}`);
  lines.push('');
  lines.push(`export interface ${entityName} {`);
  lines.push('  id: string;');
  if (entityName === 'User') {
    lines.push('  email: string;');
    lines.push('  name: string;');
    lines.push('  createdAt: string;');
  } else {
    lines.push('  // Add entity fields');
    lines.push('  createdAt: string;');
    lines.push('  updatedAt: string;');
  }
  lines.push('}');
  lines.push('');

  // Generate request/response types for each endpoint
  for (const ep of endpoints) {
    const typeName = ep.path
      .replace('/api/', '')
      .replace(/[/:]/g, '_')
      .split('_')
      .map(s => s.charAt(0).toUpperCase() + s.slice(1))
      .join('');

    if (ep.request) {
      lines.push(`export interface ${typeName}${ep.method}Request {`);
      for (const [key, type] of Object.entries(ep.request)) {
        const optional = type.endsWith('?') ? '?' : '';
        const cleanType = type.replace('?', '');
        lines.push(`  ${key}${optional}: ${cleanType};`);
      }
      lines.push('}');
      lines.push('');
    }

    lines.push(`export interface ${typeName}${ep.method}Response {`);
    for (const [key, type] of Object.entries(ep.response)) {
      lines.push(`  ${key}: ${type};`);
    }
    lines.push('}');
    lines.push('');
  }

  // Generate error type
  const allErrors = [...new Set(endpoints.flatMap(ep => ep.errors))];
  if (allErrors.length > 0) {
    lines.push('export type ApiErrorCode =');
    lines.push(`  | '${allErrors.join("'\n  | '")}';`);
    lines.push('');
    lines.push('export interface ApiError {');
    lines.push('  code: ApiErrorCode;');
    lines.push('  message: string;');
    lines.push('}');
  }

  return lines.join('\n');
}
