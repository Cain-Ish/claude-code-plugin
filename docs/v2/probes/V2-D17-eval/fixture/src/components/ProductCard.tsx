import { tokens } from '../theme/tokens';
import type { Product } from '../types/product';
import { Card } from './Card';
import { Img } from './Img';

export interface ProductCardProps {
  product: Product;
}

export function ProductCard({ product }: ProductCardProps) {
  return (
    <Card title={product.name}>
      <Img path={product.imagePath} alt={product.name} width={240} height={240} />
      <p style={{ color: tokens.color.textMuted, fontSize: tokens.font.md }}>{product.price.toFixed(2)}</p>
    </Card>
  );
}
