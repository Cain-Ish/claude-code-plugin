export type PinSection = 'blockers' | 'decisions';
export interface PinToProjectArgs {
    text: string;
    slug: string;
    section: PinSection;
    brainDir?: string;
}
export interface PinToProjectResult {
    ok: boolean;
    line_added: string;
    project_slug: string;
    reason?: string;
}
export declare function pinToProject(args: PinToProjectArgs): Promise<PinToProjectResult>;
//# sourceMappingURL=pin-to-project.d.ts.map