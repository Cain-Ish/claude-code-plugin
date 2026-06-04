/** A repo-relative markdown path is high-signal iff it matches an include rule and no denylist.
 *  Normalizes separators first: `path.relative` emits OS-native separators, so a Windows path
 *  `docs\adr\x.md` must be split on `\` too or rule 2 / the secret anchor silently misfire. */
export declare function isHighSignal(relRaw: string): boolean;
/** Max items captured per scan (SB_SCAN_MAX, default 50). */
export declare function scanCap(): number;
/** Walk the repo for high-signal markdown docs (junk + git-ignored dropped). Sorted, uncapped. */
export declare function scanCandidates(projectRoot: string): Promise<string[]>;
export interface ScanResult {
    candidates: string[];
    overflow: string[];
    captured: number;
    skipped: number;
    errored: number;
    truncated: number;
}
/** Scan + (unless dryRun) capture each candidate into the raw inbox as `setup-scan` material.
 *  Dedup is unprocessed-scoped (captureItem): re-running re-captures only new/changed docs. Once
 *  SP-4 marks an item `processed`, re-capture policy for that doc is SP-4's concern (it owns the
 *  processed lifecycle), so this scan intentionally does not dedup against processed items. */
export declare function runScan(projectRoot: string, brainDir: string, slug: string, opts: {
    dryRun?: boolean;
}): Promise<ScanResult>;
//# sourceMappingURL=raw-scan.d.ts.map