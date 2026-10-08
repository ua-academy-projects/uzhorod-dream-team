/** Switches between the light and dark theme; the label shows the theme the button switches to. */
export default function ThemeToggle({ theme, onToggle }) {
  const isDark = theme === 'dark';
  return (
    <button type="button" onClick={onToggle} aria-pressed={isDark} title="Toggle light/dark theme">
      {isDark ? '☀️ Light' : '🌙 Dark'}
    </button>
  );
}
