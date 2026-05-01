export interface PinToUserArgs {
    text: string;
    brainDir?: string;
}
export interface PinToUserResult {
    ok: boolean;
    line_added: string;
    reason?: string;
}
export declare function pinToUser(args: PinToUserArgs): Promise<PinToUserResult>;
//# sourceMappingURL=pin-to-user.d.ts.map