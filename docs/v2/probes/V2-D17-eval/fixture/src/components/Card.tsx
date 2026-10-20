import type { ReactNode } from 'react';

export interface CardProps {
  title: string;
  children: ReactNode;
}

export function Card({ title, children }: CardProps) {
  return (
    <section style={{ border: '1px solid #ddd', borderRadius: 8, padding: 16 }}>
      <h3 style={{ margin: 0, fontSize: 16 }}>{title}</h3>
      {children}
    </section>
  );
}
