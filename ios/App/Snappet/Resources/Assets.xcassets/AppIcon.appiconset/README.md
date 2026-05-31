# AppIcon

This slot is **intentionally empty** for now.

`Contents.json` references `AppIcon.png` (the modern single-size iOS format).
Before App Store submission, drop a **1024×1024** PNG named `AppIcon.png` into
this directory:

- Exactly 1024×1024 px.
- **No alpha channel** (App Store rejects icons with transparency).
- sRGB, flattened (no layers).

Xcode/`actool` will generate every required size from this single source.
Until the PNG is added the catalog builds, but the app will show the default
placeholder icon — which is fine for development/TestFlight internal builds but
must be replaced before public release.
