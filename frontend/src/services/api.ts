import type { Bar } from "../type/bar.interface";
import type { Settings } from "../type/settings.interface";

async function fetchJSON<T>(path: string, init: RequestInit = {}): Promise<T> {
    const result = await fetch(`/api${path}`, {
        ...init,
        credentials: "include",
        headers: {
            'Content-Type': 'application/json',
            ...init.headers
        },
        cache: 'no-store',
    })

    if (!result.ok) {
        const error = await result.json();
        if (error.message) {
            throw new Error(error.message);
        } else {
            throw new Error(result.statusText)
        }
        
    }

    return result.json() as Promise<T>
}

export const api = {
    getHistory: (symbol: string, date: string) => fetchJSON<Bar[]>(`/history/${symbol}/?from=${date}`),
    getCurrent: (symbol: string) => fetchJSON<Bar[]>(`/history/${symbol}/last`),

    getSettings: () => fetchJSON<Settings>(`/settings`),
    setSettings: (settings: Settings) => fetchJSON<Settings>(`/settings`, {
        method: 'PUT',
        body: JSON.stringify(settings),
    }),
}