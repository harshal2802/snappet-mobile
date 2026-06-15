# AppIcon — Snappet "Pulse"

The app icon is the `waveform.path.ecg` brand mark (the same glyph the in-app loading view shows),
in the three iOS 18 appearance slots:

- `AppIcon.png` — light: white pulse on a coral→ember gradient (opaque, App-Store-compliant).
- `AppIcon-Dark.png` — dark: coral pulse on near-black.
- `AppIcon-Tinted.png` — tinted: grayscale pulse; iOS composites the user's home-screen tint.

Regenerate all three with `swift generate-pulse-icon.swift .` (macOS; renders the SF Symbol).
`generate-icon.swift` is the retired "S monogram" generator, kept for reference (#77 replaced it).
