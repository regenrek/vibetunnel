/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./src/**/*.{html,js,ts}",
    "./public/**/*.html"
  ],
  theme: {
    extend: {
      fontFamily: {
        'mono': ['Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'source-code-pro', 'monospace'],
      },
      colors: {
        'terminal': {
          'bg': '#1a1a1a',
          'fg': '#f0f0f0',
          'green': '#00ff00',
          'blue': '#0080ff',
          'yellow': '#ffff00',
          'red': '#ff0000',
          'cyan': '#00ffff',
          'magenta': '#ff00ff',
        }
      }
    },
    fontFamily: {
      'sans': ['Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'source-code-pro', 'monospace'],
      'mono': ['Monaco', 'Menlo', 'Ubuntu Mono', 'Consolas', 'source-code-pro', 'monospace'],
    }
  },
  plugins: [],
}