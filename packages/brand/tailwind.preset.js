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
          iris: {
            DEFAULT: "#4f46e5", // indigo-600 — light-mode accent (cooled toward
            // the site's slate; bluer than violet, still pops off the neutrals)
            bright: "#818cf8", // indigo-400 — dark-mode accent
            wash: "#e0e7ff", //  light band wash
            "wash-dark": "#262a4d", // dark band wash
            "wash-active-dark": "#2e335c" // dark active-band wash
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
