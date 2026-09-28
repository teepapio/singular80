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
      // `index.html` *is* the dashboard; `dashboard.html` is only the redirect
      // for old links. Both must be named as entries, or Vite leaves the
      // redirect out of the build.
      input: {
        dashboard: 'index.html',
        redirect: 'dashboard.html',
      },
    },
  },
});
