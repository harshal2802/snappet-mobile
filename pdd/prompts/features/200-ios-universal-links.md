# Prompt: QR codes and shared links you can tap — universal links

**File**: pdd/prompts/features/200-ios-universal-links.md
**Created**: 2026-10-21
**Project type**: Native iOS feature (Swift) + the two GitHub Pages sites — code lands in this repo, the web pieces in
`harshal2802/harshal2802.github.io` (AASA) and `harshal2802/Snappet` #77 (fallback page).
**Context**: `pdd/context/decisions.md`

## Ask

User (2026-10-20): "is it possible to make sure QR code in phone is click linkable?" Second of three (A: intents +
links #391 → B: this → C: QR photo import).

## Build

- Every `snappet://<rest>` has an https twin `https://harshal2802.github.io/Snappet/open/<rest>`. Pure
  `SnappetWebLink.appForm / webForm`.
- **Shared QR codes + share links carry the https form**: Kilter climb, routine, festival lineup. Camera shows
  "Open in Snappet"; Messages / Notes make it tappable. The QR size checks count the https bytes.
- **Every parser accepts both forms**: `SnappetDeepLink.route`, `RootShell.handle`, the `init?(decoding:)`s,
  `HouseholdInvite(url:)`, `WorkoutLinkAction`. Old `snappet://` QR codes and links keep working. Android's Kilter
  parser reads the https form too.
- Household invites stay `snappet://`: their token would otherwise reach GitHub's logs when the app isn't installed.
- Spotlight ids stay `snappet://`, so existing index entries still resolve.
- Entitlement `applinks:harshal2802.github.io` (project.yml). The AASA at
  `harshal2802.github.io/.well-known/apple-app-site-association` claims `/Snappet/open/*` for `com.snappet.app` and
  `.alpha`. It needs a Jekyll `include` because dot-folders are skipped.
- Without the app, the Snappet site's `404.html` shows "Open in Snappet" (the snappet:// twin) + "Get Snappet"
  (TestFlight). The service worker's navigate fallback skips `/Snappet/open/`.

## Acceptance criteria

- [x] `SnappetWebLinkTests`: both directions, pass-through, the https form routes like the app form, routine / invite
      decode, QR byte count. Android `KilterDeepLinkTest` reads the https form.
- [x] AASA served 200 at the domain root; fallback page renders.
- [ ] Device: scan a climb / routine QR with the Camera → "Open in Snappet" → lands; tap a shared link in Messages /
      Notes → opens the app; an old snappet:// QR still scans in-app.
