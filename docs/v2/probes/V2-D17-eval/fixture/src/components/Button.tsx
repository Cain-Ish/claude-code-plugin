import type { ReactNode } from 'react';

export interface ButtonProps {
  children: ReactNode;
  onClick?: () => void;
}

export function Button({ children, onClick }: ButtonProps) {
  return (
    <button
      onClick={onClick}
      style={{ background: '#0b6e4f', color: '#fff', padding: '8px 12px', border: 'none', borderRadius: 4 }}
    >
      {children}
    </button>
  );
}
