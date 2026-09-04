// The Loopyard palette as Tailwind tokens — the ONE place brand color lives.
// Both the app and the marketing site consume this via `presets:` so a color
// change here lands everywhere. Names come from loopyard.ai/branding.
//
// Core (the published brand):
//   paper  — light surface        ink    — dark surface
//   slate  — editorial accent     flame  — warm accent, sparingly
// Extended (app semantics, promoted into brand so app + site agree):
//   iris   — the interactive accent (the app's violet: links, "you", live)
//   moss   — done / healthy       amber  — needs-you / attention
//   rose   — broken / destructive
module.exports = {
  theme: {
    extend: {
      colors: {
        brand: {
          paper: "#fafaf9",
          "paper-shade": "#f2f1ef", // secondary light surface (rails, panels)
          ink: "#0a0a0a",
          "ink-raised": "#161616", // secondary dark surface (rails, panels)
          slate: "#1e293b",
          // flame === Tailwind orange-600, so needs-you surfaces use the native
          // orange-* scale (orange-600 IS brand flame) for shades/washes.
          flame: "#ea580c",
          // iris — the ORIGINAL loopyard violet, expanded into a full working
          // family (tried cooling it to indigo; the violet is the identity).
          iris: {
            DEFAULT: "#7c3aed", // violet-600 — links, actions, "you" on paper
            deep: "#6d28d9", //   violet-700 — hover/pressed on paper
            bright: "#a78bfa", // violet-400 — links/accent on ink
            soft: "#c4b5fd", //   violet-300 — secondary accents on ink
            wash: "#ede9fe", //   violet-100 — prompt-band ground on paper
            "wash-active": "#ddd6fe", // violet-200 — the ACTIVE band on paper
            "wash-faint-dark": "#241f3a", // the QUIETEST prompt ground on ink
            "wash-dark": "#2b2348", // prompt-band ground on ink
            "wash-active-dark": "#332a54" // active band on ink
          },
          // Every accent is a PAIR: DEFAULT reads on paper, bright reads on ink.
          // (Single-value accents kept forcing ad-hoc dark: picks in the app.)
          moss: { DEFAULT: "#059669", bright: "#34d399" }, // done/healthy
          amber: { DEFAULT: "#b45309", bright: "#fbbf24" }, // transitional caution
          rose: { DEFAULT: "#e11d48", bright: "#fb7185" }, // broken/destructive
          "flame-bright": "#fb923c" // flame on ink (orange-400)
        }
      }
    }
  }
};
