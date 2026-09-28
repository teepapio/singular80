import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:8787',
        changeOrigin: true,
      },
    },
  },
  build: {
    target: 'es2022',
    chunkSizeWarningLimit: 2000,
    rollupOptions: {
      // `index.html` *ist* das Dashboard, `dashboard.html` nur noch der
      // Weiterleiter für alte Links. Beide müssen als Einstieg benannt werden,
      // sonst baut Vite die Weiterleitung nicht mit.
      input: {
        dashboard: 'index.html',
        redirect: 'dashboard.html',
      },
    },
  },
});
