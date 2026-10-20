import type { ReactNode } from 'react';
import { tokens } from '../../theme/tokens';

export interface BadgeProps {
  children: ReactNode;
}

export function Badge({ children }: BadgeProps) {
  return (
    <span
      style={{
        background: tokens.color.surfaceRaised,
        color: tokens.color.textPrimary,
        border: `1px solid ${tokens.color.borderSubtle}`,
        borderRadius: tokens.radius.sm,
        padding: `0 ${tokens.space.xs}px`,
        fontSize: tokens.font.sm,
      }}
    >
      {children}
    </span>
  );
}
