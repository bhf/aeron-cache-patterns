// @ts-check
import { defineConfig } from 'astro/config';

// Static site. Tailwind runs at build time via PostCSS (see tailwind.config.mjs + postcss.config.cjs).
// No deploy target wired yet — run locally with `npm run dev`; Cloudflare Pages will come later.
export default defineConfig({
  markdown: {
    shikiConfig: {
      theme: 'github-dark',
      wrap: false,
    },
  },
});
