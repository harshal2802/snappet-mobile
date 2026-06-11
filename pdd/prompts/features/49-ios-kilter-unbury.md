# Prompt: Un-bury Kilter's headline features — session start, create-a-climb, catalog gate, HR profile link, QR deep links

**File**: pdd/prompts/features/49-ios-kilter-unbury.md
**Created**: 2026-06-11
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Product-review roadmap [#100](https://github.com/harshal2802/snappet-mobile/issues/100) → Wave 2 (iOS)
**Source**: GitHub issue [#75](https://github.com/harshal2802/snappet-mobile/issues/75)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Kilter's differentiating features are built but hidden. Rich sessions (live HR, Live Activity,
per-climb timing, media, summaries, reels) and create-a-climb sit behind an unlabeled ellipsis
menu; a climber who logs without an active session silently forfeits the entire rich-session
layer with no prompt. The first-run catalog gate leads with the developer path (Import prominent,
Download secondary) and tells phone users about "the boardlib tool — see tools/kilter", a git-repo
artifact they cannot act on. The shared HR profile is only findable inside the gym tracker's
settings, so Kilter summaries silently use the 190 bpm default ceiling. And shared climb QR codes
scan to nothing in the iOS Camera — `snappet://` was never registered (a deliberate deferral,
decisions.md 2026-06-05; the #71 SuiteRouter hoist that unblocks it has landed). Surface all five.

## Context the implementer needs

- `KilterRootView` toolbar: six actions under "More" (`kilter.more`); start/end session lives
  there even though the green `sessionBar` already owns the active-session slot above the list.
  `sessions` is `AppModel.kilterSessions` (hoisted, #54/#71); `start(angle:source:in:)` folds
  `recover(in:)` so EVERY start path keeps the single-open/stale-close invariant — new start
  paths must go through it, never insert a `KilterSession` directly.
- `KilterClimbDetailView.log(_:)` inserts `sessionId: sessions.currentId` — `nil` when idle, with
  no prompt. The BLE path auto-starts on board connect (`source: "ble"`); the manual log path is
  the only one that drops data on the floor.
- `KilterCatalogSyncView`: Import is `.borderedProminent` and listed first; Download is
  `.bordered` below it; the caption references boardlib + a stale "your account is optional"
  (the download sheet is accountless — a user-hosted static file). Android already reversed this
  exact emphasis in #94 (prompt 42, decisions.md 2026-06-10): mirror its reasoning — the ToU
  notice + user-controlled host carry the legal posture and stay UNCHANGED; only emphasis + copy move.
- The HR-profile editor is `UserHRProfileView`, today reachable only via
  `Features/WorkoutTracker/WorkoutSettingsView` (do NOT move it — it's app-global; link to the
  same editor from Kilter). `KilterSessionDetailView` falls back to `HeartRateZone.defaultMaxHR`
  (190) at lines ~61/348 with no hint that zones are un-personalized.
- `KilterDeepLink.swift` holds the pure `KilterClimbLink` codec (`snappet://kilter/climb/<uuid>?angle=n`,
  unit-tested); `Info.plist` has no `CFBundleURLTypes`; no `onOpenURL` anywhere. The plist is a
  checked-in file (`INFOPLIST_FILE: Snappet/Resources/Info.plist`, `GENERATE_INFOPLIST_FILE: NO`)
  — the scheme registers there, never in the generated .xcodeproj. `SuiteRouter` (Core/, #71) owns
  tab+path with `open(module:)` and already carries a one-shot `pendingWorkoutResume` intent —
  the QR intent follows that exact pattern (the climb push needs `KilterRootView`'s
  `navigationDestination` + catalog access, so the shell can't push it directly).
- Concurrent work: issue #74 owns `Features/Workout*` and `AppLibraryView` — don't touch them.

## Approach

1. **Visible session + create controls** (`KilterRootView`): a `+` toolbar button for Create climb
   (keeps the `kilter.create` id); when idle, an `idleSessionBar` in the slot the active
   `sessionBar` owns — one prominent **Start session** button + a one-line value pitch. The More
   menu keeps Plan / Surprise me / Scan QR / Settings; start/end leave it (the bars own them).
   The Mine empty state points at `+`, not the menu path.
2. **Auto-start on first log** (`KilterClimbDetailView.log` + `KilterSessionManager`): when no
   session is active, `start(angle: selectedAngle, source: "auto", in:)` before the entry is
   built — the log attaches either way. `start` gains a `@discardableResult Bool` ("created
   fresh") so the view only offers **Undo** for a session this log actually created (recovery
   adopting an open session must NOT be undoable). New `undoStart(in:)` on the manager detaches
   the session's entries (`sessionId = nil`), tears down live metrics/Live Activity it owns, and
   deletes the row — the log survives, exactly as if no session had started. An undoable
   "Session started" capsule appears by the log confirmation.
3. **Catalog gate reversal** (`KilterCatalogSyncView`): Download leads (filled, first), Import
   secondary; the boardlib/account caption is replaced with the Android #94 user-terms copy.
   ToU card + host handling untouched.
4. **HR profile reachability**: `KilterSettingsView` gains a "Heart-rate profile" row pushing the
   same `UserHRProfileView`; `KilterSessionDetailView`'s HR section shows an inline "Set up your
   heart-rate profile" button (sheet → same editor) when the session was scored against the
   default ceiling and no profile exists yet.
5. **URL scheme**: `CFBundleURLTypes` (`snappet`) in `Resources/Info.plist`; `RootShell` gets
   `.onOpenURL` → pure `SnappetDeepLink.route(for:)` (in `KilterDeepLink.swift`) → set
   `router.pendingKilterClimb` + `open(module: "kilter")`. `KilterRootView` consumes the one-shot
   intent (`.onChange(initial: true)` — covers cold start AND warm), recovers the session manager,
   and routes via the pure `KilterDeepLinkRouting.destination(for:climbInstalled:availableAngles:)`:
   installed → adopt the shared angle when this board offers it + push `KilterClimbRoute`;
   missing → a graceful "climb not in your catalog" alert (also shown over the catalog gate when
   nothing is installed). The in-app scanner reroutes through the same decision, fixing its silent
   dead-end on un-installed climbs.

## Output

- `ios/App/Snappet/Features/Kilter/KilterRootView.swift` — toolbar/menu reshape, idle session bar,
  deep-link consumption + missing-climb alert, scanner unification.
- `ios/App/Snappet/Features/Kilter/KilterBoardController.swift` — `KilterSessionManager.start`
  returns "created fresh"; `undoStart(in:)`.
- `ios/App/Snappet/Features/Kilter/KilterClimbDetailView.swift` — auto-start + undoable capsule.
- `ios/App/Snappet/Features/Kilter/KilterCatalogSyncView.swift` — emphasis + copy reversal.
- `ios/App/Snappet/Features/Kilter/KilterSettingsView.swift` — HR-profile row.
- `ios/App/Snappet/Features/Kilter/KilterSessionDetailView.swift` — default-ceiling setup affordance.
- `ios/App/Snappet/Features/Kilter/KilterDeepLink.swift` — `SnappetDeepLink` + `KilterDeepLinkRouting`.
- `ios/App/Snappet/Core/SuiteRouter.swift` — `pendingKilterClimb` one-shot intent.
- `ios/App/Snappet/Features/Shell/RootShell.swift` — `.onOpenURL`.
- `ios/App/Snappet/Resources/Info.plist` — `CFBundleURLTypes`.
- Tests: `KilterDeepLinkTests` (route parsing + routing decisions), new auto-start/undo coverage
  beside `KilterSessionStartRecoveryTests`; `KilterSessionLifecycleTests` (UI) drives the visible
  Start control.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md` in the same change.

## Acceptance criteria

- [ ] Start session + Create climb are visible on browse without opening the overflow menu.
- [ ] Logging with no active session starts one (recovery folds in), attaches the log, and shows
      an undoable confirmation; Undo keeps the log and removes the session.
- [ ] The catalog gate leads with Download (filled, first); no repo/CLI copy anywhere on it.
- [ ] HR profile reachable from Kilter Settings; default-ceiling HR summaries show a setup affordance.
- [ ] `xcrun simctl openurl booted "snappet://kilter/climb/<uuid>?angle=40"` opens Snappet on the
      climb (cold and warm); an unknown uuid lands gracefully. Camera-app scan = the same URL open.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] No platform imports added to `HighlightEngine`.
- [ ] `decisions.md` updated (emphasis reversal mirrored from Android #94; un-deferral of the URL scheme).

## Constraints

- On-device only; no backend/network/accounts. Aurora legal posture (ToU notice, user-controlled
  host, no Aurora API) unchanged — this prompt moves emphasis and copy only.
- `KilterSessionManager.start` stays the single entry for every start path (recover folds in).
- Route parsing/decisions stay pure in `KilterDeepLink.swift` (unit-testable, no UIKit/SwiftUI).
- State verification honestly: BLE/live-HR/Live-Activity/camera paths stay device-pending.

## Test plan

1. `cd ios/App && xcodegen generate` clean; all changed files `swiftc -parse` clean.
2. Unit (simulator, orchestrator): extended `KilterDeepLinkTests`, new `KilterSessionAutoStartTests`
   (in-memory store, unbound manager — the `KilterSessionStartRecoveryTests` pattern).
3. UI (simulator, orchestrator): updated `KilterSessionLifecycleTests` via the visible Start control.
4. Deep link (simulator, orchestrator): launch app once, then
   `xcrun simctl openurl booted "snappet://kilter/climb/<fixture-uuid>?angle=40"` (warm) and after
   `xcrun simctl terminate booted com.snappet.app` (cold); unknown uuid → graceful alert.
5. Device-pending: real Camera-app QR scan, BLE auto-start parity, live HR in the auto-started session.
