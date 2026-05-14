export interface PersonaDismissArgs {
    prompt_snippet?: string;
    reason?: string;
    brainDir?: string;
}
export interface PersonaDismissResult {
    ok: boolean;
    count_7d: number;
}
export declare function personaDismiss(args?: PersonaDismissArgs): Promise<PersonaDismissResult>;
//# sourceMappingURL=persona-dismiss.d.ts.map