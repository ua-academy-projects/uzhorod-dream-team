import path from "path"
import react from "@vitejs/plugin-react"
import { defineConfig, loadEnv } from "vite"

export default defineConfig(({ command, mode }) => {
  const env = loadEnv(mode, process.cwd(), "VITE_")
  const apiURL = new URL(env.VITE_API_URL || "/api/v1", "http://localhost:8081")

  return {
    define: command === "serve" ? {
      "import.meta.env.VITE_API_URL": JSON.stringify("/api/v1"),
    } : undefined,
    server: {
      proxy: {
        "/api/v1": {
          target: apiURL.origin,
          changeOrigin: false,
          rewrite: (requestPath: string) => requestPath.replace(/^\/api\/v1/, apiURL.pathname.replace(/\/$/, "")),
        },
      },
    },
    plugins: [react()],
    resolve: {
      alias: {
        "@": path.resolve(import.meta.dirname, "./src"),
      },
      dedupe: ["react", "react-dom"],
    },
    optimizeDeps: {
      include: ["@base-ui/react", "react", "react-dom"],
    },
  }
})
