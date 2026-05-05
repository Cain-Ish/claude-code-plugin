import { promises as fs } from 'fs';
import { join, basename, relative } from 'path';
import { parseDoc } from './knowledge-search.js';
export async function knowledgeValidate(knowledgeDir, opts = {}) {
    const wikiDir = join(knowledgeDir, 'wiki');
    const issues = [];
    let fixed = 0;
    const allPages = await collectAllPages(wikiDir);
    const slugMap = new Map();
    const parsedDocs = [];
    for (const filePath of allPages) {
        const content = await fs.readFile(filePath, 'utf-8');
        const slug = basename(filePath, '.md');
        const doc = parseDoc(content, filePath);
        parsedDocs.push(doc);
        if (!slugMap.has(slug))
            slugMap.set(slug, []);
        slugMap.get(slug).push(filePath);
        if (!content.trim()) {
            issues.push({
                type: 'empty_page',
                severity: 'error',
                path: filePath,
                message: `Empty page: ${slug}`,
                autofix: 'remove',
            });
        }
        const fmMatch = content.match(/^---\n/);
        if (!fmMatch) {
            issues.push({
                type: 'missing_frontmatter',
                severity: 'warning',
                path: filePath,
                message: `Missing YAML frontmatter: ${slug}`,
                autofix: 'add_frontmatter',
            });
        }
        const datePrefix = slug.match(/^\d{4}-\d{2}-\d{2}-/);
        if (datePrefix) {
            issues.push({
                type: 'stale_page',
                severity: 'warning',
                path: filePath,
                message: `Date-prefixed filename should be renamed: ${slug}`,
                autofix: 'rename_strip_date',
            });
        }
        if (isSessionNarrative(content, slug)) {
            issues.push({
                type: 'stale_page',
                severity: 'warning',
                path: filePath,
                message: `Session-narrative page "${slug}" — content should be merged into its parent entity`,
                autofix: 'merge_into_entity',
            });
        }
    }
    const allSlugs = new Set(allPages.map(p => basename(p, '.md')));
    for (const doc of parsedDocs) {
        for (const ref of doc.related) {
            if (!allSlugs.has(ref)) {
                issues.push({
                    type: 'broken_link',
                    severity: 'warning',
                    path: doc.path,
                    message: `Broken wiki-link [[${ref}]] — no matching page`,
                });
            }
        }
    }
    for (const [slug, paths] of slugMap) {
        if (paths.length > 1) {
            issues.push({
                type: 'duplicate_slug',
                severity: 'error',
                path: paths.join(', '),
                message: `Duplicate slug "${slug}" in: ${paths.map(p => relative(wikiDir, p)).join(', ')}`,
                autofix: 'merge',
            });
        }
    }
    try {
        const rootFiles = await fs.readdir(knowledgeDir, { withFileTypes: true });
        for (const entry of rootFiles) {
            if (entry.isFile() && entry.name.endsWith('.md') && entry.name !== 'README.md') {
                const rootPath = join(knowledgeDir, entry.name);
                issues.push({
                    type: 'root_orphan',
                    severity: 'error',
                    path: rootPath,
                    message: `Orphan file at knowledge root — should be in wiki/ or removed: ${entry.name}`,
                    autofix: 'move_or_remove',
                });
            }
        }
    }
    catch { /* knowledgeDir may not exist */ }
    if (opts.autofix) {
        for (const issue of issues) {
            if (issue.autofix === 'remove' && issue.type === 'empty_page') {
                try {
                    await fs.unlink(issue.path);
                    fixed++;
                }
                catch { /* already gone */ }
            }
            if (issue.autofix === 'move_or_remove' && issue.type === 'root_orphan') {
                try {
                    const stat = await fs.stat(issue.path);
                    if (stat.size === 0) {
                        await fs.unlink(issue.path);
                        fixed++;
                    }
                }
                catch { /* already gone */ }
            }
        }
    }
    return { issues, fixed, pagesScanned: allPages.length };
}
function isSessionNarrative(content, slug) {
    const sessionSignals = [
        /^##\s+(key\s+)?findings?\b/im,
        /^##\s+files\s+(changed|touched)\b/im,
        /^##\s+review\s+approach\b/im,
        /^##\s+open\s+items?\b/im,
        /\bMR\s+!\d+\b/i,
        /\bsession\b.*\bsummary\b/i,
        /\bin\s+this\s+session\b/i,
        /\bfriction\s+signals?:\s*\d+/i,
        /\buser\s+turns?:\s*\d+/i,
    ];
    const slugSignals = [
        /^mr\d+-/,
        /^mr-\d+/,
        /-mr\d+$/,
        /-session$/,
        /-review$/,
        /-upgrade$/,
        /-build$/,
        /-migration$/,
    ];
    let score = 0;
    for (const re of sessionSignals) {
        if (re.test(content))
            score++;
    }
    for (const re of slugSignals) {
        if (re.test(slug))
            score++;
    }
    return score >= 3;
}
async function collectAllPages(dir, acc = []) {
    try {
        const entries = await fs.readdir(dir, { withFileTypes: true });
        for (const e of entries) {
            const p = join(dir, e.name);
            if (e.isDirectory())
                await collectAllPages(p, acc);
            else if (e.isFile() && e.name.endsWith('.md') && e.name !== 'index.md')
                acc.push(p);
        }
    }
    catch { /* dir doesn't exist */ }
    return acc;
}
//# sourceMappingURL=knowledge-validate.js.map