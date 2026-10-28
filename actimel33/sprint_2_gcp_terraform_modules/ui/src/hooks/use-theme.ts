import { useCallback, useEffect, useRef, useState } from 'react';
import { getTheme, saveTheme } from '../api/client.ts';
import type { Theme } from '../api/client.ts';

/**
 * The choice lives in the session on the server, so it survives a new tab or
 * another device with the same session — unlike localStorage.
 * `system` means "follow the OS", which the stylesheet already handles.
 */
export function useTheme(): { theme: Theme; setTheme: (next: Theme) => void } {
  const [theme, setLocalTheme] = useState<Theme>('system');
  // A click before the stored theme arrives wins over that late answer.
  const chosen = useRef(false);

  useEffect(() => {
    let ignore = false;
    getTheme()
      .then(({ theme: stored }) => {
        if (!ignore && !chosen.current) setLocalTheme(stored);
      })
      .catch(() => {
        /* no session yet — the system theme stays */
      });
    return () => {
      ignore = true;
    };
  }, []);

  useEffect(() => {
    const root = document.documentElement;
    if (theme === 'system') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', theme);
  }, [theme]);

  const setTheme = useCallback((next: Theme) => {
    chosen.current = true;
    setLocalTheme(next); // apply at once, persist in the background
    saveTheme(next).catch(() => {
      /* the visual choice stands even if the session could not be saved */
    });
  }, []);

  return { theme, setTheme };
}
