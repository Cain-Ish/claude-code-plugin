import { tokens } from '../theme/tokens';

export interface StatTileProps {
  label: string;
  value: number;
}

export function StatTile({ label, value }: StatTileProps) {
  return (
    <div style={{ padding: tokens.space.md, background: tokens.color.surfaceRaised }}>
      <div style={{ fontSize: tokens.font.xl, color: tokens.color.textPrimary }}>{value}</div>
      <div style={{ fontSize: tokens.font.sm, color: tokens.color.textMuted }}>{label}</div>
    </div>
  );
}
