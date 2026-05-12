import * as fs from 'fs';
import * as path from 'path';

interface ImplementServiceOptions {
  name: string;
  repo?: string;
  methods?: string;
}

export async function implementService(options: ImplementServiceOptions): Promise<void> {
  const { name, repo, methods } = options;

  const methodList = methods ? methods.split(',').map(m => m.trim()) : ['create', 'findById', 'update', 'delete'];

  console.log(`\n=== Implementing: ${name} ===\n`);

  // Analyze dependencies
  const domain = name.replace('Service', '').toLowerCase();
  const Domain = domain.charAt(0).toUpperCase() + domain.slice(1);

  console.log('Methods:');
  for (const method of methodList) {
    const signature = getMethodSignature(method, Domain);
    console.log(`  - ${method}${signature}`);
  }

  // Detect database
  let db = 'unknown';
  if (repo) {
    if (fs.existsSync(path.join(repo, 'prisma/schema.prisma'))) {
      db = 'prisma';
    } else if (fs.existsSync(path.join(repo, 'drizzle.config.ts'))) {
      db = 'drizzle';
    }
    console.log(`\nDatabase: ${db}`);
  }

  console.log('\nDependencies:');
  console.log(`  - Database (${db})`);
  console.log('  - Logger');

  // Generate code
  const code = generateServiceCode(name, Domain, methodList, db);

  console.log('\n' + '-'.repeat(40));
  console.log('\nGenerated code:\n');
  console.log(code);

  console.log('\n[Human approval required]');
  console.log('Approve implementation? [y/n/modify]');
}

function getMethodSignature(method: string, domain: string): string {
  switch (method) {
    case 'create':
      return `(data: Create${domain}Input): Promise<${domain}>`;
    case 'findById':
      return `(id: string): Promise<${domain} | null>`;
    case 'findAll':
      return `(options?: FindOptions): Promise<${domain}[]>`;
    case 'update':
      return `(id: string, data: Update${domain}Input): Promise<${domain}>`;
    case 'delete':
      return `(id: string): Promise<void>`;
    default:
      return `(...args: unknown[]): Promise<unknown>`;
  }
}

function generateServiceCode(name: string, domain: string, methods: string[], db: string): string {
  const prismaClient = db === 'prisma' ? `import { prisma } from '@/lib/prisma';` : '';

  const methodImplementations = methods.map(method => {
    switch (method) {
      case 'create':
        return `  async create(data: Create${domain}Input): Promise<${domain}> {
    ${db === 'prisma' ? `return prisma.${domain.toLowerCase()}.create({ data });` : `// TODO: implement create`}
  }`;
      case 'findById':
        return `  async findById(id: string): Promise<${domain} | null> {
    ${db === 'prisma' ? `return prisma.${domain.toLowerCase()}.findUnique({ where: { id } });` : `// TODO: implement findById`}
  }`;
      case 'findAll':
        return `  async findAll(options?: { skip?: number; take?: number }): Promise<${domain}[]> {
    ${db === 'prisma' ? `return prisma.${domain.toLowerCase()}.findMany(options);` : `// TODO: implement findAll`}
  }`;
      case 'update':
        return `  async update(id: string, data: Update${domain}Input): Promise<${domain}> {
    ${db === 'prisma' ? `return prisma.${domain.toLowerCase()}.update({ where: { id }, data });` : `// TODO: implement update`}
  }`;
      case 'delete':
        return `  async delete(id: string): Promise<void> {
    ${db === 'prisma' ? `await prisma.${domain.toLowerCase()}.delete({ where: { id } });` : `// TODO: implement delete`}
  }`;
      default:
        return `  async ${method}(...args: unknown[]): Promise<unknown> {
    // TODO: implement ${method}
    throw new Error('Not implemented');
  }`;
    }
  }).join('\n\n');

  return `${prismaClient}

export interface ${domain} {
  id: string;
  createdAt: Date;
  updatedAt: Date;
  // Add entity fields
}

export interface Create${domain}Input {
  // Add create fields
}

export interface Update${domain}Input {
  // Add update fields
}

class ${name} {
${methodImplementations}
}

export const ${domain.toLowerCase()}Service = new ${name}();
`;
}
