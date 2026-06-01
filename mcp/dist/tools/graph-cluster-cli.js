/**
 * CLI: cluster a wiki's link graph and print theme-cluster candidates as JSON.
 * Reads each page's `related:` frontmatter + body [[links]] (no live edges.jsonl —
 * staging-local), runs deterministic label propagation, and emits clusters >= minSize
 * with a content-aware member_hash. No external deps (offline, fast). Invoked via the
 * scripts/graph-cluster.sh shim from the dream-runner. Spec: 2026-06-01-dream-consolidation-v2.
 *
 * Usage: graph-cluster-cli <wiki-dir>
 *        graph-cluster-cli --knowledge-dir <kd>   (uses <kd>/wiki)
 * Env:   SB_SUMMARIZE_MIN_CLUSTER (default 4)
 */
import { promises as fs } from 'fs';
import { join } from 'path';
import { buildAdjacency, labelPropagate, clusters, memberHash, djb2 } from './graph-cluster.js';
function resolveWikiDir(argv) {
    if (argv[0] === '--knowledge-dir' && argv[1])
        return join(argv[1], 'wiki');
    if (argv[0])
        return argv[0];
    const kd = process.env.CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR || process.env.KNOWLEDGE_DIR || join(process.env.HOME ?? '', 'knowledge');
    return join(kd, 'wiki');
}
async function collect(dir, acc = []) {
    let entries;
    try {
        entries = await fs.readdir(dir, { withFileTypes: true });
    }
    catch {
        return acc;
    }
    for (const e of entries) {
        const p = join(dir, e.name);
        if (e.isDirectory()) {
            if (!e.name.startsWith('.'))
                await collect(p, acc);
        }
        else if (e.name.endsWith('.md') && e.name !== 'index.md')
            acc.push(p);
    }
    return acc;
}
function frontmatter(content) {
    const m = content.match(/^---\n([\s\S]*?)\n---/);
    return m ? m[1] : '';
}
function links(text) {
    return [...text.matchAll(/\[\[([^\]]+)\]\]/g)].map(m => m[1].split('|')[0].trim()).filter(Boolean);
}
function relatedFrom(fm) {
    const line = fm.split('\n').find(l => /^related:/.test(l));
    return line ? links(line) : [];
}
async function main() {
    const wikiDir = resolveWikiDir(process.argv.slice(2));
    const minSize = parseInt(process.env.SB_SUMMARIZE_MIN_CLUSTER ?? '4', 10) || 4;
    const files = await collect(wikiDir);
    const pages = [];
    const contentHash = {};
    for (const f of files) {
        let content = '';
        try {
            content = await fs.readFile(f, 'utf-8');
        }
        catch {
            continue;
        }
        if (!content.trim())
            continue;
        const slug = (f.split('/').pop() ?? '').replace(/\.md$/, '');
        const fm = frontmatter(content);
        const body = content.replace(/^---\n[\s\S]*?\n---/, '');
        pages.push({ slug, related: relatedFrom(fm), bodyLinks: [...new Set(links(body))] });
        contentHash[slug] = djb2(content);
    }
    const maxPages = parseInt(process.env.SB_SUMMARIZE_MAX_PAGES ?? '8', 10) || 8;
    const labels = labelPropagate(buildAdjacency(pages));
    // Enforce the cap deterministically in code (the agent prose states it too, but bound the
    // output regardless): keep the LARGEST clusters (most thematic), tie-break by id, then
    // restore id order for stable output.
    const capped = [...clusters(labels, { minSize })]
        .sort((a, b) => b.members.length - a.members.length || (a.id < b.id ? -1 : 1))
        .slice(0, maxPages)
        .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    const out = capped.map(c => ({
        id: c.id, members: c.members, member_hash: memberHash(c.members, contentHash),
    }));
    process.stdout.write(JSON.stringify(out) + '\n');
}
main().catch(e => { process.stderr.write(String(e) + '\n'); process.exit(1); });
//# sourceMappingURL=graph-cluster-cli.js.map