import type { Theme } from '../api/client.ts';

const OPTIONS: { value: Theme; label: string }[] = [
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
  { value: 'system', label: 'System' },
];

type Props = {
  theme: Theme;
  onChange: (theme: Theme) => void;
};

export function ThemeToggle({ theme, onChange }: Props) {
  return (
    <div className="theme" role="group" aria-label="Colour theme">
      {OPTIONS.map(({ value, label }) => (
        <button
          key={value}
          type="button"
          className="theme__option"
          aria-pressed={theme === value}
          onClick={() => onChange(value)}
        >
          {label}
        </button>
      ))}
    </div>
  );
}
