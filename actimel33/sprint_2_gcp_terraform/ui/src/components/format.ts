const money = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  maximumFractionDigits: 0,
});

const moneyPrecise = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  maximumFractionDigits: 2,
});

const moment = new Intl.DateTimeFormat('en-US', {
  month: 'long',
  day: 'numeric',
  hour: 'numeric',
  minute: '2-digit',
});

const clock = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' });
const dayMonth = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' });

export const formatPrice = (value: number): string => money.format(value);
export const formatPricePrecise = (value: number): string => moneyPrecise.format(value);
export const formatMoment = (iso: string): string => moment.format(new Date(iso));
export const formatClock = (iso: string): string => clock.format(new Date(iso));
export const formatDayMonth = (value: number): string => dayMonth.format(new Date(value));
