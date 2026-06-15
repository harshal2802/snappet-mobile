# Prompt: App Store / TestFlight release config + bundle-validity fixes

**File**: pdd/prompts/features/61-ios-appstore-release-config.md
**Created**: 2026-06-15
**Project type**: Native iOS release tooling — code/config lands in this repo.
**Chain**: PLAN-ios-to-shippable.md → ship (TestFlight, then App Store)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Get a distribution build to **TestFlight** under the paid team `NFUS5W8QC6`, and add the repeatable
tooling + fix the bundle-validity errors Apple flagged on the first upload — so future builds (TestFlight
and eventually App Store) are one command.

## Context the implementer needs

- The paid Developer Program team is **`NFUS5W8QC6`** (Apple Distribution cert present). The old
  `8TRC99V9PN` free team is dead — committed `DEVELOPMENT_TEAM` moves to `NFUS5W8QC6`.
- App Store validation rejected the first upload for three real bundle issues (all fixed here):
  iPad multitasking needs all **four** orientations; the **watch app had no app icon**
  (`CFBundleIconName` + no AppIcon asset); → both block *any* App Store build, production included.
- **Alpha identity is NOT committed.** The TestFlight record "SnappetAI" is registered under
  `com.snappet.app.alpha`, but the repo's canonical identity stays `com.snappet.app`. The `.alpha`
  retarget is applied as a **local overlay** (`scripts/alpha-build-overlay.sh`), never committed — the
  watch's `WKCompanionAppBundleIdentifier` is a static literal (the `INFOPLIST_KEY_` setting is inert
  under `GENERATE_INFOPLIST_FILE: NO`), so the overlay edits it directly.

## Approach / Output

- **Bundle-validity fixes (committed, production-correct):** `UISupportedInterfaceOrientations~ipad`
  (4 orientations) in the app Info.plist; a watchOS `AppIcon.appiconset` (reusing the app mark) +
  `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` on the watch target + `CFBundleIconName` in the watch
  Info.plist. (`ITSAppUsesNonExemptEncryption=false` was already present.)
- **Release tooling (committed):** `ExportOptions.plist` (app-store-connect, team `NFUS5W8QC6`, automatic
  signing); fastlane `Fastfile` (`beta` lane: archive Release → upload to TestFlight via an ASC API key
  read from env) + an `APP_BUNDLE_ID`-driven `Appfile`; `DEVELOPMENT_TEAM → NFUS5W8QC6`.
- **Alpha overlay (committed script, NOT committed state):** `scripts/alpha-build-overlay.sh <build>`
  retargets bundle ids + watch companion to `com.snappet.app.alpha` and sets the build number, then
  `xcodegen generate`. Run it before an alpha archive; never commit its working-tree edits.

## Acceptance criteria

- [x] A distribution archive uploads to TestFlight under `com.snappet.app.alpha` (SnappetAI, App 6779420682) — done 2026-06-15.
- [x] Apple's bundle validation passes (iPad orientations + watch icon resolved).
- [x] Committed repo identity stays `com.snappet.app`; `.alpha` is a local overlay only.
- [x] Engine/app tests unaffected (release config only; no source-logic change).

## Constraints

- The ASC API key (`.p8` + key id + issuer id) is a credential — supplied via env at runtime, never committed.
- No source-logic changes; this is signing/packaging/tooling only.

## Test plan

1. `scripts/alpha-build-overlay.sh <n>` → `cd ios/App && APP_BUNDLE_ID=com.snappet.app.alpha ASC_… fastlane beta` → TestFlight.
2. Confirm the committed (no-overlay) project still generates + builds for the simulator under `com.snappet.app`.
