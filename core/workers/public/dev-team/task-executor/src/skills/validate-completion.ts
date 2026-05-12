import { execSync } from 'child_process';
import * as path from 'path';

interface ValidateOptions {
  repo: string;
  checks?: string;
  strict?: boolean;
}

interface CheckResult {
  name: string;
  passed: boolean;
  output: string;
  errors: string[];
  warnings: string[];
}

export async function validateCompletion(options: ValidateOptions): Promise<boolean> {
  const { repo, checks, strict } = options;

  const checksToRun = checks ? checks.split(',') : ['typecheck', 'lint', 'test'];
  const results: CheckResult[] = [];

  console.log('\nRunning validation checks...\n');

  // Type check
  if (checksToRun.includes('typecheck')) {
    const result = runCheck('typecheck', 'npm run typecheck', repo);
    results.push(result);
    printCheckResult(result, 1, checksToRun.length);
  }

  // Lint
  if (checksToRun.includes('lint')) {
    const result = runCheck('lint', 'npm run lint', repo);
    results.push(result);
    printCheckResult(result, 2, checksToRun.length);
  }

  // Test
  if (checksToRun.includes('test')) {
    const result = runCheck('test', 'npm test', repo);
    results.push(result);
    printCheckResult(result, 3, checksToRun.length);
  }

  // Build (optional)
  if (checksToRun.includes('build')) {
    const result = runCheck('build', 'npm run build', repo);
    results.push(result);
    printCheckResult(result, checksToRun.indexOf('build') + 1, checksToRun.length);
  }

  // Summary
  const failed = results.filter(r => !r.passed);
  const hasWarnings = results.some(r => r.warnings.length > 0);

  console.log('\n' + '='.repeat(40));

  if (failed.length === 0) {
    if (hasWarnings && strict) {
      console.log('Overall: FAIL (strict mode, warnings present)');
      return false;
    }
    console.log('Overall: PASS');
    console.log('Ready to commit.');
    return true;
  } else {
    console.log(`Overall: FAIL (${failed.length} check(s) failed)`);
    console.log('\nFailed checks:');
    for (const f of failed) {
      console.log(`  - ${f.name}`);
      for (const err of f.errors.slice(0, 5)) {
        console.log(`    ${err}`);
      }
    }
    console.log('\nFix errors and re-run validation.');
    return false;
  }
}

function runCheck(name: string, command: string, cwd: string): CheckResult {
  const result: CheckResult = {
    name,
    passed: false,
    output: '',
    errors: [],
    warnings: [],
  };

  try {
    const output = execSync(command, {
      cwd: path.resolve(cwd),
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    result.passed = true;
    result.output = output;

    // Extract warnings from output
    const warningLines = output.split('\n').filter(line =>
      line.toLowerCase().includes('warning') ||
      line.includes('⚠')
    );
    result.warnings = warningLines.slice(0, 10);

  } catch (error: any) {
    result.passed = false;
    result.output = error.stdout || error.stderr || error.message;

    // Extract errors from output
    const errorLines = result.output.split('\n').filter(line =>
      line.toLowerCase().includes('error') ||
      line.includes('✖') ||
      line.includes('❌')
    );
    result.errors = errorLines.slice(0, 10);
  }

  return result;
}

function printCheckResult(result: CheckResult, index: number, total: number): void {
  const status = result.passed ? '✅' : '❌';
  console.log(`[${index}/${total}] ${result.name}...`);
  console.log(`  ${status} ${result.passed ? 'passed' : 'failed'}`);

  if (result.errors.length > 0) {
    console.log('  Errors:');
    for (const err of result.errors.slice(0, 3)) {
      console.log(`    ${err}`);
    }
  }

  if (result.warnings.length > 0 && result.passed) {
    console.log('  Warnings:');
    for (const warn of result.warnings.slice(0, 3)) {
      console.log(`    ${warn}`);
    }
  }
}
