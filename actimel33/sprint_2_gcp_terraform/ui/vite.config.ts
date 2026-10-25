import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    // Local development only; in the container nginx proxies /api the same way.
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
