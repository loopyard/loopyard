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
          ink: "#0a0a0a",
          slate: "#1e293b",
          flame: "#ea580c",
          iris: {
            DEFAULT: "#7c3aed", // violet-600 — light-mode accent
            bright: "#a78bfa", // violet-400 — dark-mode accent
            wash: "#ede9fe", //  light band wash
            "wash-dark": "#2b2348", // dark band wash
            "wash-active-dark": "#332a54" // dark active-band wash
          },
          moss: "#059669", // emerald-600 — done/healthy
          amber: "#b45309", // amber-700 — needs-you
          rose: "#e11d48" // rose-600 — broken/destructive
        }
      }
    }
  }
};
