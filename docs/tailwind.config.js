/** @type {import('tailwindcss').Config} */
module.exports = {
  // Only index.html is scanned, so a utility class that isn't in the file at
  // build time won't exist in css/site.css. Rebuild after editing markup.
  content: ["./index.html"],
  // Follow the OS rather than a toggle: no button, no JS, no localStorage, and
  // it matches what the page did before this template.
  darkMode: "media",
  theme: {
    extend: {
      // Tailwind's emerald, written out rather than require()d from
      // tailwindcss/colors: the CLI is run via bunx/npx from a temp install, so
      // a require from this directory can't resolve it.
      colors: {
        primary: {
          50: "#ecfdf5",
          100: "#d1fae5",
          200: "#a7f3d0",
          300: "#6ee7b7",
          400: "#34d399",
          500: "#10b981",
          600: "#059669",
          700: "#047857",
          800: "#065f46",
          900: "#064e3b",
          950: "#022c22",
        },
      },
    },
  },
};
