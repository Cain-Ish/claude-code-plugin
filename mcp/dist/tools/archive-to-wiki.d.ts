export type SourceSection = 'blockers' | 'decisions';
export type TargetCategory = 'issues' | 'decisions';
export interface ArchiveToWikiArgs {
    slug: string;
    sourceSection: SourceSection;
    entryText: string;
    targetCategory: TargetCategory;
    brainDir?: string;
    knowledgeDir?: string;
}
export interface ArchiveToWikiResult {
    ok: boolean;
    archived_path: string;
    reason?: string;
}
export declare function archiveToWiki(args: ArchiveToWikiArgs): Promise<ArchiveToWikiResult>;
//# sourceMappingURL=archive-to-wiki.d.ts.map