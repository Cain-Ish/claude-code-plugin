import { describe, it, expect } from 'vitest';
import { slugFromProjectDir, activeProjectDir } from './project-dir.js';
describe('slugFromProjectDir', () => {
    it('returns the basename of a real path', () => {
        expect(slugFromProjectDir('/home/cainish/Projects/claude-code-plugin')).toBe('claude-code-plugin');
    });
    it('rejects degenerate paths', () => {
        expect(slugFromProjectDir(undefined)).toBeUndefined();
        expect(slugFromProjectDir('')).toBeUndefined();
        expect(slugFromProjectDir('/')).toBeUndefined();
        expect(slugFromProjectDir('.')).toBeUndefined();
    });
});
describe('activeProjectDir', () => {
    it('prefers CLAUDE_PROJECT_DIR over cwd', () => {
        const env = { CLAUDE_PROJECT_DIR: '/proj/root' };
        expect(activeProjectDir(env, () => '/some/mcp/launch/dir')).toBe('/proj/root');
    });
    it('falls back to cwd when CLAUDE_PROJECT_DIR is unset (older CLI)', () => {
        const env = {};
        expect(activeProjectDir(env, () => '/the/cwd')).toBe('/the/cwd');
    });
    it('end-to-end: env project dir resolves to its slug', () => {
        const env = { CLAUDE_PROJECT_DIR: '/home/u/my-repo' };
        expect(slugFromProjectDir(activeProjectDir(env, () => '/tmp/x'))).toBe('my-repo');
    });
});
//# sourceMappingURL=project-dir.test.js.map