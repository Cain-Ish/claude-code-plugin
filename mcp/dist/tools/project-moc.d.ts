export interface MocInput {
    slug: string;
    type: string;
    project: string;
    title: string;
    description: string;
}
export interface MocOpts {
    minMembers: number;
}
export declare const MOC_BEGIN = "<!-- moc:begin (generated from project: facets \u2014 do not hand-edit) -->";
export declare const MOC_END = "<!-- moc:end -->";
/** Pure, deterministic. Returns project-slug → MOC marked-region markdown, only for
 *  projects with >= minMembers members. Members grouped by type (sorted), sorted by
 *  slug within each group. No timestamps (idempotent). */
export declare function buildProjectMocs(pages: MocInput[], opts: MocOpts): Map<string, string>;
//# sourceMappingURL=project-moc.d.ts.map