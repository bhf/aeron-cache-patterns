// @ts-check
import { defineConfig } from 'astro/config';

// Static site. Tailwind runs at build time via PostCSS (see tailwind.config.mjs + postcss.config.cjs).
// No deploy target wired yet — run locally with `npm run dev`; Cloudflare Pages will come later.
export default defineConfig({
  markdown: {
    // Let Shiki highlight code, but leave ```mermaid blocks as raw <code class="language-mermaid">
    // so the client-side renderer in BaseLayout can turn them into themed diagrams.
    syntaxHighlight: {
      type: 'shiki',
      excludeLangs: ['mermaid'],
    },
    shikiConfig: {
      theme: 'github-dark',
      wrap: false,
    },
  },
});
