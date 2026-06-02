import { promises as fs } from 'fs';
import { join, basename, dirname, relative } from 'path';
import { parseDoc } from './knowledge-search.js';
import { parseAiBlock, validateAiBlock, stripAiBlock, AI_BLOCK_SCHEMAS } from './ai-block.js';
// A structured page with this much prose (non-frontmatter, marked regions stripped) but no
// ai-block is a backfill candidate; shorter pages are legitimate stubs, exempt.
const AI_BLOCK_MIN_PROSE = 200;
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
        // AI-block checks (gentle, additive — spec §7). Block present but missing a required field
        // → ai_block_incomplete. A structured, SUBSTANTIVE page with NO block at all →
        // ai_block_missing (predates the feature / never authored). Stubs + non-structured types +
        // generated MOCs (projects/, themes/) are exempt.
        const aiBlock = parseAiBlock(content);
        const ptype = doc.type || basename(dirname(filePath));
        if (aiBlock) {
            const missing = validateAiBlock(ptype, aiBlock);
            if (missing.length)
                issues.push({
                    type: 'ai_block_incomplete', severity: 'warning', path: filePath,
                    message: `ai-block missing required field(s) for type ${ptype}: ${missing.join(', ')}`,
                });
        }
        else if (AI_BLOCK_SCHEMAS[ptype] && !/[/\\](projects|themes)[/\\]/.test(filePath)) {
            const prose = stripAiBlock(content)
                .replace(/<!--\s*graph:begin[\s\S]*?graph:end\s*-->/g, '')
                .replace(/<!--\s*theme:begin[\s\S]*?theme:end\s*-->/g, '')
                .replace(/^---\n[\s\S]*?\n---\n/, '');
            if (prose.trim().length >= AI_BLOCK_MIN_PROSE)
                issues.push({
                    type: 'ai_block_missing', severity: 'warning', path: filePath,
                    message: `${ptype} page has substantive prose but no ai-block: ${slug}`,
                });
        }
        // Generated MOC dirs (projects/, themes/) are derived VIEWS, not source pages — a MOC that
        // shares a slug with a real page (e.g. project "architecture-v1" + page architecture-v1.md)
        // is not a true duplicate, so exclude them from the duplicate_slug check.
        if (!/[/\\](projects|themes)[/\\]/.test(filePath)) {
            if (!slugMap.has(slug))
                slugMap.set(slug, []);
            slugMap.get(slug).push(filePath);
        }
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
        for (const rawRef of doc.related) {
            // [[target|alias]] resolves to its target — split before checking (same alias rule as
            // graph-migrate.sh). Without this, a valid aliased link is a false-positive broken_link.
            const ref = rawRef.split('|')[0].trim();
            if (ref && !allSlugs.has(ref)) {
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
            if (issue.autofix === 'add_frontmatter' && issue.type === 'missing_frontmatter') {
                try {
                    await addFrontmatter(issue.path, wikiDir);
                    fixed++;
                }
                catch { /* skip pages we can't write */ }
            }
        }
    }
    return { issues, fixed, pagesScanned: allPages.length };
}
const KNOWN_CATEGORIES = new Set([
    'concepts', 'decisions', 'entities', 'issues',
    'learnings', 'security', 'state', 'sources', 'themes', 'projects',
]);
export async function addFrontmatter(filePath, wikiDir) {
    const original = await fs.readFile(filePath, 'utf-8');
    // Defensive: if frontmatter snuck in between scan and write, leave it alone.
    if (/^---\n/.test(original))
        return;
    const slug = basename(filePath, '.md');
    // Title: first '# Heading' line, else slug-as-title.
    const headingMatch = original.match(/^#\s+(.+?)\s*$/m);
    const title = headingMatch
        ? headingMatch[1].trim().replace(/"/g, "'")
        : slug.replace(/-/g, ' ');
    // Type: folder segment directly under wiki/.
    const relPath = relative(wikiDir, filePath);
    const firstSeg = relPath.split('/')[0];
    const type = KNOWN_CATEGORIES.has(firstSeg) ? firstSeg : 'state';
    // Created: a `**Date**: YYYY-MM-DD` line in the body wins; else date-prefixed slug;
    // else file mtime. We never invent dates from "today" — that would lie about provenance.
    let created = '';
    const dateLine = original.match(/\*\*Date(?:\s*\w+)?\*\*:\s*(\d{4}-\d{2}-\d{2})/i);
    if (dateLine) {
        created = dateLine[1];
    }
    else {
        const slugDate = slug.match(/^(\d{4}-\d{2}-\d{2})/) || slug.match(/(\d{4}-\d{2}-\d{2})$/);
        if (slugDate) {
            created = slugDate[1];
        }
        else {
            try {
                const stat = await fs.stat(filePath);
                created = stat.mtime.toISOString().slice(0, 10);
            }
            catch {
                created = new Date().toISOString().slice(0, 10);
            }
        }
    }
    const updated = new Date().toISOString().slice(0, 10);
    // Related: any [[wiki-link]] tokens already in the body (deduped).
    const linkMatches = original.match(/\[\[([^\]]+)\]\]/g) || [];
    const related = [...new Set(linkMatches
            .map(l => l.slice(2, -2).trim())
            // Filter out matches that are clearly not wiki slugs (spaces, regex metachars, etc.)
            .filter(r => /^[a-z0-9][a-z0-9-]*$/i.test(r)))];
    const fm = `---\n` +
        `title: "${title}"\n` +
        `description: ""\n` +
        `type: ${type}\n` +
        `created: ${created}\n` +
        `updated: ${updated}\n` +
        `tags: []\n` +
        `related: [${related.join(', ')}]\n` +
        `---\n\n`;
    await fs.writeFile(filePath, fm + original, 'utf-8');
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