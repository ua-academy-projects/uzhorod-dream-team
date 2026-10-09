import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    // Vite rejects requests whose Host it does not know. IP addresses are
    // allowed by default; a tunnel domain is not, so it is listed here.
    // A leading dot covers the random subdomain each tunnel gets.
    allowedHosts: ['.trycloudflare.com'],
    // Only /api is proxied. The internal /internal/ingest route is not covered
    // here and stays unreachable from the browser.
    proxy: {
      '/api': {
        // The History service may live on another machine.
        target: process.env.HISTORY_URL ?? 'http://localhost:3001',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api/, ''),
      },
    },
  },
});
