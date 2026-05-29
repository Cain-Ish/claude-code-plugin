export interface ProjectResult {
    pagesUpdated: number;
}
/** Regenerate related: frontmatter + the ## Dependencies block on every page,
 *  from current-valid edges. No edges.jsonl ⇒ no-op (returns pagesUpdated:0). */
export declare function projectGraphToPages(knowledgeDir: string): Promise<ProjectResult>;
//# sourceMappingURL=graph-project.d.ts.map