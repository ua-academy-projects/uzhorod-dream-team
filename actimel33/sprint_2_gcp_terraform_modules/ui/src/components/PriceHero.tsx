import { formatMoment, formatPrice } from './format.ts';

type Props = {
  price: number;
  observedAt: string;
};

/**
 * The price and the moment it was observed read as one sentence rather than a
 * number with a small caption: for this service, "how much" is meaningless
 * without "when".
 */
export function PriceHero({ price, observedAt }: Props) {
  return (
    <section className="hero">
      <p className="hero__price">{formatPrice(price)}</p>
      <p className="hero__observed">
        observed <time dateTime={observedAt}>{formatMoment(observedAt)}</time>
      </p>
    </section>
  );
}
