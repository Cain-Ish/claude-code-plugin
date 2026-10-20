import type { User } from '../types/user';
import { Img } from './Img';

export interface MemberListProps {
  members: User[];
}

export function MemberList({ members }: MemberListProps) {
  const sorted = [...members].sort((a, b) => a.joinedAt.localeCompare(b.joinedAt));
  return (
    <ul style={{ listStyle: 'none', padding: 0 }}>
      {sorted.map((m) => (
        <li key={m.id} style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {m.avatarCdnUrl ? (
            <img src={m.avatarCdnUrl} alt="" width={32} height={32} style={{ borderRadius: '50%' }} />
          ) : (
            <Img path={m.avatarPath ?? 'avatars/default.png'} width={32} height={32} style={{ borderRadius: '50%' }} />
          )}
          <span>{m.firstName} {m.lastName}</span>
        </li>
      ))}
    </ul>
  );
}
