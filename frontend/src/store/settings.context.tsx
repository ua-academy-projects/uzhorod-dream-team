import { createContext, useContext, useEffect, useState } from 'react';
import type { Settings, Theme } from '../type/settings.interface';
import { api } from '../services/api';

export interface SettingsContextType {
  settings: Settings;
  setSettings: (settings: Settings) => void;
  isDarkTheme: boolean;
}

export const SettingsContext = createContext<SettingsContextType | undefined>(
  undefined
);

export const useSettingsContext = () => {
  const context = useContext(SettingsContext);

  if (!context) {
    throw new Error('SettingsContextType is undefined');
  }

  return context;
};

interface SettingsProviderProps {
  children: React.ReactNode;
}

function isTheme(value: unknown): value is Theme {
  return value === 'light' || value === 'dark' || value === 'auto';
}

export function SettingsProvider({ children }: SettingsProviderProps) {
  const [settings, setSettingsState] = useState<Settings>({
    theme: 'auto',
  });

  const [isDarkTheme, setIsDarkTheme] = useState(false);

  useEffect(() => {
    const loadSettings = async () => {
      try {
        const hasCookie = document.cookie
          .split('; ')
          .some((cookie) => cookie.startsWith('settings_id='));

        if (!hasCookie) {
          const defaultSettings: Settings = { theme: 'auto' };
          const savedSettings = await api.setSettings(defaultSettings);
          setSettingsState(savedSettings);
          return;
        }

        const loadedSettings = await api.getSettings();

        if (loadedSettings && isTheme(loadedSettings.theme)) {
          setSettingsState(loadedSettings);
        } else {
          const defaultSettings: Settings = { theme: 'auto' };
          const savedSettings = await api.setSettings(defaultSettings);
          setSettingsState(savedSettings);
        }
      } catch (error) {
        console.error('Failed to load settings:', error);
      }
    };

    loadSettings();
  }, []);

  useEffect(() => {
    const colorScheme = window.matchMedia('(prefers-color-scheme: dark)');

    const applyTheme = () => {
      const isDark =
        settings.theme === 'dark' ||
        (settings.theme === 'auto' && colorScheme.matches);

      setIsDarkTheme(isDark);
      document.documentElement.classList.toggle('dark', isDark);
      document.documentElement.style.colorScheme = isDark ? 'dark' : 'light';
    };

    applyTheme();

    colorScheme.addEventListener('change', applyTheme);

    return () => {
      colorScheme.removeEventListener('change', applyTheme);
    };
  }, [settings.theme]);

  const setSettings = async (newSettings: Settings) => {
    try {
      const savedSettings = await api.setSettings(newSettings);
      setSettingsState(savedSettings);
    } catch (error) {
      console.error('Failed to save settings:', error);
    }
  };

  return (
    <SettingsContext.Provider value={{ settings, setSettings, isDarkTheme }}>
      {children}
    </SettingsContext.Provider>
  );
}