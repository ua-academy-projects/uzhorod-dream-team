import { LucideEclipse, LucideMoon, LucideSun } from "lucide-react";
import { useSettingsContext } from "../store/settings.context";
import { Button } from "./ui/button";

export function ThemeToggle() {
  const { settings, setSettings } = useSettingsContext();

  const toggleTheme = () => {
    const nextTheme =
      settings.theme === 'auto'
        ? 'light'
        : settings.theme === 'light'
          ? 'dark'
          : 'auto';

    setSettings({
      ...settings,
      theme: nextTheme,
    });
  };

  const getThemeIcon = () => {
    switch (settings.theme) {
        case 'auto':
        return <LucideEclipse />;

        case 'light':
        return <LucideSun />;

        case 'dark':
        return <LucideMoon />;

        default:
        return <LucideEclipse />;
    }
    };

  return (
    <Button
      variant="outline"
      size="icon"
      onClick={toggleTheme}
      aria-label={`Theme: ${settings.theme}`}
      title={`Theme: ${settings.theme}`}
    >
        {getThemeIcon()}
    </Button>
  );
}