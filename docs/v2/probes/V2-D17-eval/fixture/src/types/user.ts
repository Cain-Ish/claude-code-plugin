export interface User {
  id: string;
  firstName: string;
  lastName: string;
  role: 'customer' | 'staff';
  joinedAt: string;
  /** Path of the avatar image, for example "avatars/u_1042.jpg". */
  avatarPath?: string;
  /** Full CDN address of the avatar, when the CDN holds a copy. */
  avatarCdnUrl?: string;
}
