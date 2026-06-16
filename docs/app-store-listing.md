# SnappetAI — App Store listing copy

Paste these into App Store Connect → your app → the version's **App Information** / **Pricing** /
**version** pages. Character limits noted; counts are approximate — App Store Connect enforces them.
Replace the **[PLACEHOLDER]** items with your real URLs.

> **Status (2026-06-16): decisions locked.** Name **SnappetAI** · reuse existing record
> **com.snappet.app.alpha** (App 6779420682) · **Free**. One App Review **risk accepted** (Kilter download)
> and one fix **applied** (health-records entitlement removed). Remaining before submit: privacy-policy URL
> live on `main`, a support URL, and screenshots.

---

## Compliance status (2026-06-16 audit)

1. **Kilter "Download from Kilter" — ⚠️ ACCEPTED RISK (your decision).** Guideline **5.2.2 (third-party
   IP)**: it downloads Aurora/Kilter-owned catalog data, which the repo's own posture (`decisions.md` line
   775) marks *personal / sideload only*. You chose to keep it in the public build and accept the rejection
   risk. Fallback if Apple rejects on 5.2.2: gate `HostedCatalogProvider` behind a build flag and keep only
   the App-Store-legal **file-import** path.
2. **Unused `health-records` entitlement — ✅ FIXED (2026-06-16).** Removed
   `com.apple.developer.healthkit.access: [health-records]` from `project.yml` and regenerated
   `Snappet.entitlements`. Normal heart-rate / workout reads are unaffected.

*Everything else is clean:* file-import path (OK), ONNX model = data not code (OK, 2.5.2), no accounts
(OK, 5.1.1), `PrivacyInfo.xcprivacy` honest (OK). The Privacy Policy URL below is **mandatory for
HealthKit** (5.1.3) and goes live once `docs/privacy-policy.html` is on `main`.

---

## App name (≤30 chars)
```
SnappetAI
```

## Subtitle (≤30 chars)
```
Heart-rate workout highlights
```

## Promotional text (≤170 chars — editable any time without a new build)
```
Turn your workouts into highlight reels automatically — your heart rate finds the best moments. Plus an on-device fitness + focus toolkit. No account. All private.
```

## Keywords (≤100 chars, comma-separated, no spaces after commas)
```
workout,reels,heart rate,fitness,highlights,gym,climbing,kilter,pomodoro,habits,journal,HIIT,running
```

## Description (≤4000 chars)
```
SnappetAI turns your workouts into share-ready highlight reels — automatically. As you train, your heart rate marks the moments that mattered, and SnappetAI stitches the photos and videos you shot into a reel built around your real effort. No scrubbing through footage. No guesswork.

And it all happens on your device. There's no account, no sign-up, and no server — your workouts, heart rate, photos, and reels never leave your iPhone unless you choose to share them.

WORKOUT REELS (the flagship)
• Auto-generates a highlight reel from a workout's heart-rate peaks and the media you captured.
• On-device intelligence ranks your footage — favoring the sharp, in-action moments over the dull ones — and learns from the edits you make.
• Pin, reorder, remove, or regenerate clips, then export to Photos or share anywhere.

A FULL FITNESS TOOLKIT
• Gym Tracker — log routines, sets, reps, and PRs; review a clean heart-rate summary with zones; and edit clips in a built-in video studio.
• Kilter Board — browse and log climbing-board sessions with per-climb timing and heart rate.
• Live heart rate from your Apple Watch or a paired Bluetooth chest strap.

PLUS EVERYDAY ESSENTIALS
• Pomodoro — a focus timer with Live Activity and streaks.
• Habits — daily check-offs and streaks.
• Journal — quick, searchable entries.
• Tip, Split Expenses, and Budget — fast money tools for everyday life.

PRIVATE BY DESIGN
• No account. No backend. No tracking, no ads, no third-party SDKs.
• HealthKit data is read on-device only — never transmitted, never sold, never used for advertising.
• Delete the app and your data is gone. Revoke any permission any time in Settings.

Snappet was built iPhone-first, with deep iOS integration: home-screen widgets, Lock Screen Live Activities, Siri Shortcuts, and Spotlight.

Make something out of every workout — privately, automatically, on your device.
```

## What's New (version 0.1.0)
```
First release of SnappetAI.
• Auto-highlight Workout Reels from your heart rate, with on-device clip selection that learns from your edits.
• Gym Tracker with a heart-rate summary and a built-in clip studio.
• Kilter Board climbing sessions, live heart rate (Apple Watch or Bluetooth strap).
• Pomodoro, Habits, Journal, Tip, Split Expenses, and Budget.
• Home-screen widgets, Live Activities, Siri Shortcuts, and Spotlight.
• 100% on-device — no account, no tracking.
```

---

## Other App Store Connect fields

- **App name:** SnappetAI  ·  **Bundle ID:** `com.snappet.app.alpha` (reuse the existing SnappetAI record, App 6779420682)
- **Pricing:** Free (no in-app purchases)
- **Primary category:** Health & Fitness
- **Secondary category:** Productivity
- **Age rating:** 4+ (no objectionable content; answer the questionnaire as all "None")
- **Privacy Policy URL:** `https://harshal2802.github.io/snappet-mobile/privacy-policy.html`
  (served via GitHub Pages from `docs/privacy-policy.html` — live once this is merged to `main`)
- **Support URL:** **[PLACEHOLDER — a page or even a mailto/contact page; required]**
- **Marketing URL:** *(optional)*
- **Copyright:** `2026 Harshal Chourasiya`

## App Privacy "nutrition labels" (App Store Connect → App Privacy)
Answer the questionnaire as **"Data Not Collected"** — the app has no backend and transmits nothing.
Specifically: when asked "Do you or your third-party partners collect data from this app?", the honest
answer is **No** (HealthKit/Photos/Camera/Bluetooth are processed on-device and never leave it, which is
*access*, not *collection* in Apple's sense). If you later add any off-device feature, revisit this.

## Screenshots (required uploads)
The app supports iPhone + iPad and embeds an Apple Watch app, so Apple requires screenshots for:
- **iPhone 6.9"** (e.g. 16 Pro Max, 1320×2868) — required; 3–10 shots.
- **iPad 13"** (2064×2752) — required because the app supports iPad (`TARGETED_DEVICE_FAMILY 1,2`).
- **Apple Watch** — required because a watchOS app is embedded.

Suggested set: finished highlight reel · live HR zones during a workout · video studio with overlays ·
gym set logging · Kilter climb detail · Today widget + Live Activity on the Lock Screen.
*(I can set up `fastlane snapshot` for repeatable, auto-sized captures — ask.)*

## Export compliance
Already declared in the build: `ITSAppUsesNonExemptEncryption = false` (the app uses only standard
HTTPS/system encryption), so no per-build prompt and no extra documentation needed.

## Review notes (paste into "Notes for Reviewer")
```
SnappetAI is fully on-device: no account, no backend/server, no analytics or third-party SDKs.
HealthKit (heart rate / workouts) and Photos are used only locally to build heart-rate-driven
highlight reels and workout summaries; nothing is transmitted off the device. The flagship feature
needs a completed workout (Apple Watch) plus photos/videos shot during that workout's time window —
please test on a device with HealthKit workout data and matching media. Bluetooth is for an optional
heart-rate strap; Camera is for on-device receipt text recognition in the expense tools.
```
