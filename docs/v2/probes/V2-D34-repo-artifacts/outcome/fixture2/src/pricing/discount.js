// Loyalty discount: a share of the order total, in whole cents.
export const LOYALTY_RATE = 0.05;

export function discountCents(totalCents, loyal) {
  if (!loyal) return 0;
  return Math.trunc(totalCents * LOYALTY_RATE);
}
