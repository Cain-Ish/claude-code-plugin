import { tokens } from '../../theme/tokens';
import type { User } from '../../types/user';
import { Img } from '../Img';

const SIZES = { small: 24, medium: 40, large: 64 } as const;

export interface UserAvatarProps {
  user: User;
  size?: keyof typeof SIZES;
}

// Avatars are served locally, never from the CDN (client decision).
export function UserAvatar({ user, size = 'medium' }: UserAvatarProps) {
  const px = SIZES[size];
  const circle = {
    width: px,
    height: px,
    borderRadius: tokens.radius.round,
    border: `1px solid ${tokens.color.borderSubtle}`,
  };
  const name = `${user.firstName} ${user.lastName}`;
  if (!user.avatarPath) {
    const initials = `${user.firstName[0] ?? ''}${user.lastName[0] ?? ''}`.toUpperCase();
    return (
      <span
        role="img"
        aria-label={name}
        style={{ ...circle, display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
          background: tokens.color.avatarFallback, color: tokens.color.textOnAccent }}
      >
        {initials}
      </span>
    );
  }
  return <Img local path={user.avatarPath} alt={name} width={px} height={px} style={{ ...circle, objectFit: 'cover' }} />;
}
