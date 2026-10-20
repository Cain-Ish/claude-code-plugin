import type { Product } from '../../types/product';
import { Img } from '../Img';

export interface ProductImageProps {
  product: Product;
  width?: number;
}

export function ProductImage({ product, width = 240 }: ProductImageProps) {
  return <Img path={product.imagePath} alt={product.name} width={width} height={width} style={{ objectFit: 'cover' }} />;
}
