export interface SbDeps {
    brainDir: string;
    knowledgeDir: string;
}
export interface SbResult {
    stdout: string;
    stderr: string;
    exitCode: number;
}
export declare function runSb(args: string[], deps: SbDeps): Promise<SbResult>;
//# sourceMappingURL=sb.d.ts.map