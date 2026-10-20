import type { ImgHTMLAttributes } from 'react';

const CDN_BASE = 'https://cdn.kf-media.example';
const LOCAL_BASE = '/static';

export interface ImgProps extends Omit<ImgHTMLAttributes<HTMLImageElement>, 'src'> {
  /** Path of the image, for example "products/p_311.jpg". */
  path: string;
  /** Serve the file from our own servers instead of the CDN. */
  local?: boolean;
}

/** Every image in the app goes through Img. */
export function Img({ path, local = false, alt = '', ...rest }: ImgProps) {
  const base = local ? LOCAL_BASE : CDN_BASE;
  return <img src={`${base}/${path}`} alt={alt} loading="lazy" {...rest} />;
}
