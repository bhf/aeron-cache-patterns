/** @type {import('tailwindcss').Config} */
// Design system copied from aeron-cache-site: dark "forest" palette (ink / base / sage).
export default {
  content: ['./src/**/*.{astro,html,md,mdx,js,ts}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        ink: '#f4f6f4',
        base: { 900: '#0b0f0d', 800: '#0f1512', 700: '#141b17' },
        sage: {
          200: '#d4e6d8',
          300: '#b8d8c0',
          400: '#9db89f',
          500: '#86c7a0',
          600: '#5f9e78',
          700: '#47785c',
        },
      },
      fontFamily: {
        sans: ['ui-sans-serif', 'system-ui', '-apple-system', 'Segoe UI', 'Roboto', 'Helvetica', 'Arial', 'sans-serif'],
        mono: ['ui-monospace', 'SFMono-Regular', 'SF Mono', 'Menlo', 'Consolas', 'Liberation Mono', 'monospace'],
      },
      maxWidth: { content: '72rem' },
    },
  },
};
