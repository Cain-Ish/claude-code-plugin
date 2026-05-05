// src/tools/knowledge-reindex.ts
import { promises as fs2 } from "fs";
import { join as join2 } from "path";

// src/tools/knowledge-search.ts
function parseDoc(content, filePath) {
  const doc = {
    title: "",
    description: "",
    type: "",
    tags: [],
    related: [],
    body: content,
    path: filePath
  };
  const fmMatch = content.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  if (fmMatch) {
    const fm = fmMatch[1];
    doc.body = fmMatch[2];
    doc.title = extractYamlValue(fm, "title");
    doc.description = extractYamlValue(fm, "description");
    doc.type = extractYamlValue(fm, "type");
    doc.tags = extractYamlList(fm, "tags");
    doc.related = extractYamlList(fm, "related");
  }
  if (!doc.title) {
    const headingMatch = doc.body.match(/^#\s+(.+)/m);
    if (headingMatch) doc.title = headingMatch[1].trim();
  }
  if (!doc.type) {
    const rel = filePath.split("/");
    const wikiIdx = rel.lastIndexOf("wiki");
    if (wikiIdx >= 0 && wikiIdx + 1 < rel.length) {
      doc.type = rel[wikiIdx + 1];
    }
  }
  if (doc.related.length === 0) {
    const wikiLinks = doc.body.match(/\[\[([^\]]+)\]\]/g);
    if (wikiLinks) {
      doc.related = [...new Set(wikiLinks.map((l) => l.slice(2, -2)))];
    }
  }
  return doc;
}
function extractYamlValue(yaml, key) {
  const re = new RegExp(`^${key}:\\s*['"]?(.+?)['"]?\\s*$`, "m");
  const m = yaml.match(re);
  return m ? m[1].trim() : "";
}
function extractYamlList(yaml, key) {
  const inline = yaml.match(new RegExp(`^${key}:\\s*\\[(.+?)\\]`, "m"));
  if (inline) {
    return inline[1].split(",").map((s) => s.trim().replace(/^['"]|['"]$/g, "")).filter(Boolean);
  }
  const items = [];
  const lines = yaml.split("\n");
  let collecting = false;
  for (const line of lines) {
    if (line.match(new RegExp(`^${key}:`))) {
      collecting = true;
      continue;
    }
    if (collecting) {
      const itemMatch = line.match(/^\s+-\s+(.+)/);
      if (itemMatch) {
        items.push(itemMatch[1].trim().replace(/^['"]|['"]$/g, ""));
      } else {
        collecting = false;
      }
    }
  }
  return items;
}

// src/tools/knowledge-validate.ts
import { promises as fs } from "fs";
import { join, basename, relative } from "path";
async function knowledgeValidate(knowledgeDir, opts = {}) {
  const wikiDir = join(knowledgeDir, "wiki");
  const issues = [];
  let fixed = 0;
  const allPages = await collectAllPages(wikiDir);
  const slugMap = /* @__PURE__ */ new Map();
  const parsedDocs = [];
  for (const filePath of allPages) {
    const content = await fs.readFile(filePath, "utf-8");
    const slug = basename(filePath, ".md");
    const doc = parseDoc(content, filePath);
    parsedDocs.push(doc);
    if (!slugMap.has(slug)) slugMap.set(slug, []);
    slugMap.get(slug).push(filePath);
    if (!content.trim()) {
      issues.push({
        type: "empty_page",
        severity: "error",
        path: filePath,
        message: `Empty page: ${slug}`,
        autofix: "remove"
      });
    }
    const fmMatch = content.match(/^---\n/);
    if (!fmMatch) {
      issues.push({
        type: "missing_frontmatter",
        severity: "warning",
        path: filePath,
        message: `Missing YAML frontmatter: ${slug}`,
        autofix: "add_frontmatter"
      });
    }
    const datePrefix = slug.match(/^\d{4}-\d{2}-\d{2}-/);
    if (datePrefix) {
      issues.push({
        type: "stale_page",
        severity: "warning",
        path: filePath,
        message: `Date-prefixed filename should be renamed: ${slug}`,
        autofix: "rename_strip_date"
      });
    }
    if (isSessionNarrative(content, slug)) {
      issues.push({
        type: "stale_page",
        severity: "warning",
        path: filePath,
        message: `Session-narrative page "${slug}" \u2014 content should be merged into its parent entity`,
        autofix: "merge_into_entity"
      });
    }
  }
  const allSlugs = new Set(allPages.map((p) => basename(p, ".md")));
  for (const doc of parsedDocs) {
    for (const ref of doc.related) {
      if (!allSlugs.has(ref)) {
        issues.push({
          type: "broken_link",
          severity: "warning",
          path: doc.path,
          message: `Broken wiki-link [[${ref}]] \u2014 no matching page`
        });
      }
    }
  }
  for (const [slug, paths] of slugMap) {
    if (paths.length > 1) {
      issues.push({
        type: "duplicate_slug",
        severity: "error",
        path: paths.join(", "),
        message: `Duplicate slug "${slug}" in: ${paths.map((p) => relative(wikiDir, p)).join(", ")}`,
        autofix: "merge"
      });
    }
  }
  try {
    const rootFiles = await fs.readdir(knowledgeDir, { withFileTypes: true });
    for (const entry of rootFiles) {
      if (entry.isFile() && entry.name.endsWith(".md") && entry.name !== "README.md") {
        const rootPath = join(knowledgeDir, entry.name);
        issues.push({
          type: "root_orphan",
          severity: "error",
          path: rootPath,
          message: `Orphan file at knowledge root \u2014 should be in wiki/ or removed: ${entry.name}`,
          autofix: "move_or_remove"
        });
      }
    }
  } catch {
  }
  if (opts.autofix) {
    for (const issue of issues) {
      if (issue.autofix === "remove" && issue.type === "empty_page") {
        try {
          await fs.unlink(issue.path);
          fixed++;
        } catch {
        }
      }
      if (issue.autofix === "move_or_remove" && issue.type === "root_orphan") {
        try {
          const stat = await fs.stat(issue.path);
          if (stat.size === 0) {
            await fs.unlink(issue.path);
            fixed++;
          }
        } catch {
        }
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
    /\buser\s+turns?:\s*\d+/i
  ];
  const slugSignals = [
    /^mr\d+-/,
    /^mr-\d+/,
    /-mr\d+$/,
    /-session$/,
    /-review$/,
    /-upgrade$/,
    /-build$/,
    /-migration$/
  ];
  let score = 0;
  for (const re of sessionSignals) {
    if (re.test(content)) score++;
  }
  for (const re of slugSignals) {
    if (re.test(slug)) score++;
  }
  return score >= 3;
}
async function collectAllPages(dir, acc = []) {
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) await collectAllPages(p, acc);
      else if (e.isFile() && e.name.endsWith(".md") && e.name !== "index.md") acc.push(p);
    }
  } catch {
  }
  return acc;
}

// src/tools/knowledge-reindex.ts
async function knowledgeReindex(knowledgeDir) {
  const wikiRoot = join2(knowledgeDir, "wiki");
  const indexPath = join2(wikiRoot, "index.md");
  let dirs;
  try {
    const entries = await fs2.readdir(wikiRoot, { withFileTypes: true });
    dirs = entries.filter((d) => d.isDirectory()).map((d) => d.name).sort();
  } catch {
    return { pagesIndexed: 0, categories: [], indexPath };
  }
  const sections = ["# Knowledge Base Index", ""];
  let totalPages = 0;
  for (const dir of dirs) {
    const dirPath = join2(wikiRoot, dir);
    const files = await collectMd(dirPath);
    if (files.length === 0) continue;
    const entries = [];
    for (const filePath of files.sort()) {
      const slug = filePath.split("/").pop().replace(/\.md$/, "");
      try {
        const content = await fs2.readFile(filePath, "utf-8");
        const doc = parseDoc(content, filePath);
        const desc = doc.description || firstSentence(doc.body);
        entries.push({ slug, title: doc.title || slug, description: desc });
      } catch {
        entries.push({ slug, title: slug, description: "" });
      }
    }
    const label = dir.charAt(0).toUpperCase() + dir.slice(1);
    sections.push(`## ${label} (${entries.length} pages)`);
    for (const e of entries) {
      const desc = e.description ? ` \u2014 ${e.description}` : "";
      sections.push(`- [[${e.slug}]]${desc}`);
    }
    sections.push("");
    totalPages += entries.length;
  }
  if (totalPages === 0) {
    sections.push("*(no pages yet)*");
    sections.push("");
  }
  sections.push(`<!-- generated: ${(/* @__PURE__ */ new Date()).toISOString()} -->`);
  await fs2.writeFile(indexPath, sections.join("\n"), "utf-8");
  const validation = await knowledgeValidate(knowledgeDir, { autofix: true });
  return {
    pagesIndexed: totalPages,
    categories: dirs,
    indexPath,
    validation: validation.issues.length > 0 || validation.fixed > 0 ? { issues: validation.issues, fixed: validation.fixed } : void 0
  };
}
function firstSentence(body) {
  const text = body.replace(/^#.*\n/m, "").trim();
  const match = text.match(/^(.+?[.!?])\s/);
  return match ? match[1].slice(0, 120) : text.slice(0, 120);
}
async function collectMd(dir, acc = []) {
  try {
    for (const e of await fs2.readdir(dir, { withFileTypes: true })) {
      const p = join2(dir, e.name);
      if (e.isDirectory()) await collectMd(p, acc);
      else if (e.isFile() && e.name.endsWith(".md") && e.name !== "index.md") acc.push(p);
    }
  } catch {
  }
  return acc;
}
export {
  knowledgeReindex
};
