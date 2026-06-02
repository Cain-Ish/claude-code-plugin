export interface MocInput { slug: string; type: string; project: string; title: string; description: string; }
export interface MocOpts { minMembers: number; }

export const MOC_BEGIN = '<!-- moc:begin (generated from project: facets — do not hand-edit) -->';
export const MOC_END = '<!-- moc:end -->';

/** Pure, deterministic. Returns project-slug → MOC marked-region markdown, only for
 *  projects with >= minMembers members. Members grouped by type (sorted), sorted by
 *  slug within each group. No timestamps (idempotent). */
export function buildProjectMocs(pages: MocInput[], opts: MocOpts): Map<string, string> {
  const byProject = new Map<string, MocInput[]>();
  for (const p of pages) {
    const proj = (p.project || '').trim();
    if (!proj) continue;
    if (!byProject.has(proj)) byProject.set(proj, []);
    byProject.get(proj)!.push(p);
  }
  const out = new Map<string, string>();
  for (const [proj, members] of [...byProject.entries()].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    if (members.length < opts.minMembers) continue;
    const types = [...new Set(members.map(m => m.type))].sort();
    const lines: string[] = [MOC_BEGIN];
    for (const t of types) {
      lines.push(`## ${t}`);
      for (const m of members.filter(m => m.type === t).sort((a, b) => (a.slug < b.slug ? -1 : 1))) {
        const desc = m.description ? ` — ${m.description}` : '';
        lines.push(`- [[${m.slug}]]${desc}`);
      }
      lines.push('');
    }
    lines.push(MOC_END);
    out.set(proj, lines.join('\n'));
  }
  return out;
}
