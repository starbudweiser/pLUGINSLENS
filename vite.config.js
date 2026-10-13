import { defineConfig } from 'vite';

// Preview live de dist/index.html : rechargement auto à chaque sauvegarde.
export default defineConfig({
  root: 'dist',
  server: { port: 5173, strictPort: true, open: false },
});
