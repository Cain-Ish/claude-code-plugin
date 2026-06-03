/** Max items captured per scan (SB_SCAN_MAX, default 50). */
export declare function scanCap(): number;
/** Walk the repo for high-signal markdown docs (junk + git-ignored dropped). Sorted, uncapped. */
export declare function scanCandidates(projectRoot: string): Promise<string[]>;
export interface ScanResult {
    candidates: string[];
    captured: number;
    skipped: number;
    truncated: number;
}
/** Scan + (unless dryRun) capture each candidate into the raw inbox as `setup-scan` material. */
export declare function runScan(projectRoot: string, brainDir: string, slug: string, opts: {
    dryRun?: boolean;
}): Promise<ScanResult>;
//# sourceMappingURL=raw-scan.d.ts.map