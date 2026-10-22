#!/usr/bin/env node
// hq-core: public
// Add freshness metadata without changing a document's semantic status.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const DAY = 86400000;
const sameFile = (a, b) => a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs;
/** Operates on one explicitly selected regular Markdown file in a plain root.
 * Unsupported metadata and changed files are preserved, never repaired by guess.
 */
export function annotateStaleFile(rootInput, fileInput, asOf = new Date().toISOString().slice(0, 10)) {
    const root = path.resolve(rootInput), file = path.resolve(fileInput);
    const result = state => ({ state, path: path.relative(root, file) });
    let rootStat, stat, bytes;
    try {
        rootStat = fs.lstatSync(root);
        if (!rootStat.isDirectory() || rootStat.isSymbolicLink() || fs.realpathSync.native(root) !== root)
            return result('refused');
        const relative = path.relative(root, file);
        if (!relative || relative.startsWith(`..${path.sep}`) || relative === '..' || path.isAbsolute(relative))
            return result('refused');
        let current = root;
        for (const component of relative.split(path.sep)) {
            current = path.join(current, component);
            if (fs.lstatSync(current).isSymbolicLink())
                return result('refused');
        }
        stat = fs.lstatSync(file);
        if (!stat.isFile() || path.extname(file).toLowerCase() !== '.md')
            return result('refused');
        if (path.basename(file).toLowerCase() === 'index.md')
            return result('excluded');
        bytes = fs.readFileSync(file);
    }
    catch {
        return result('refused');
    }
    const content = bytes.toString('utf8');
    if (!Buffer.from(content, 'utf8').equals(bytes))
        return result('unsupported_encoding');
    const open = content.match(/^---\r?\n/);
    if (!open)
        return result('no_frontmatter');
    const close = /^---(?:\r?\n|$)/m.exec(content.slice(open[0].length));
    if (!close)
        return result('no_frontmatter');
    const position = open[0].length + close.index;
    const frontmatter = content.slice(open[0].length, position);
    const first = frontmatter.split(/\r?\n/).find(line => line.trim() && !line.trimStart().startsWith('#'));
    // Do not splice into YAML lists, flow documents, directives or indented roots.
    if (first && !/^(?:[A-Za-z_][\w-]*|"[^"\r\n]+"|'[^'\r\n]+')\s*:/.test(first))
        return result('unsupported_frontmatter');
    if (/^(?:stale_since|"stale_since"|'stale_since')\s*:/m.test(frontmatter))
        return result('already_flagged');
    const now = Date.parse(`${asOf}T00:00:00Z`);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(asOf) || !Number.isFinite(now) || new Date(now).toISOString().slice(0, 10) !== asOf)
        throw new Error('as-of must be a valid YYYY-MM-DD date');
    const age = now - stat.mtimeMs;
    if (age <= 60 * DAY)
        return result('fresh');
    const newline = open[0].endsWith('\r\n') ? '\r\n' : '\n';
    const output = Buffer.from(`${content.slice(0, position)}stale_since: ${asOf}${newline}${content.slice(position)}`, 'utf8');
    const temporary = path.join(path.dirname(file), `.${path.basename(file)}.${randomUUID()}.tmp`);
    try {
        const fd = fs.openSync(temporary, 'wx', stat.mode & 0o777);
        try {
            fs.writeFileSync(fd, output);
            fs.fchmodSync(fd, stat.mode & 0o777);
            fs.fsyncSync(fd);
        }
        finally {
            fs.closeSync(fd);
        }
        const currentRoot = fs.lstatSync(root), current = fs.lstatSync(file);
        if (currentRoot.isSymbolicLink() || currentRoot.dev !== rootStat.dev || currentRoot.ino !== rootStat.ino || current.isSymbolicLink() || !sameFile(stat, current) || !fs.readFileSync(file).equals(bytes))
            return result('changed');
        fs.renameSync(temporary, file);
        return { ...result('flagged'), age_days: Math.floor(age / DAY), over_90_days: age > 90 * DAY };
    }
    finally {
        fs.rmSync(temporary, { force: true });
    }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    try {
        const args = process.argv.slice(2), options = {};
        for (let i = 0; i < args.length; i += 2) {
            const name = args[i];
            if (!['--knowledge-root', '--file', '--as-of'].includes(name) || !args[i + 1] || name in options)
                throw new Error('Usage: node core/scripts/knowledge-pulse-stale.mjs --knowledge-root <directory> --file <markdown-file> [--as-of YYYY-MM-DD]');
            options[name] = args[i + 1];
        }
        if (!options['--knowledge-root'] || !options['--file'])
            throw new Error('knowledge-root and file are required');
        console.log(JSON.stringify(annotateStaleFile(options['--knowledge-root'], options['--file'], options['--as-of'])));
    }
    catch (error) {
        console.error(`knowledge-pulse-stale: ${error.message}`);
        process.exitCode = 2;
    }
}
