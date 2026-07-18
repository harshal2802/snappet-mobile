# Prompt: Festival QR lineup sharing (festival prompt 05)

**File**: pdd/prompts/features/festival/05-festival-qr-sharing.md
**Created**: 2026-07-18
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData) — code lands in this repo only
(no web-repo companion this time; the install-link points at the `music-festivals/` host prompt 02
already publishes).
**Chain**: `pdd/prompts/features/festival/README.md` → 05 of 06 (01 MERGED #292, 02 MERGED #293,
03 MERGED #294, 04 implemented — build on the merged domain; do NOT touch the `.fpack` wire format,
the matcher's confidence semantics, or the existing models)
**Source**: user ideation session 2026-07-16; wireframes `docs/ux-research/festival/wireframes.html`
frames 12 (share sheet) · 13 (scanner). Frame 14 (poster scan) is prompt 06 — do NOT build it here.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Let two phones swap a lineup — or a night's plan — with a QR code, offline, in a field with no
signal. A friend who's built their Saturday plan holds up a code; you point your camera and their
starred sets land in your plan. This is the last payoff of "your festival lives on this device": no
account, no server, the same `SnappetShareable` stack the routine/climb shares already ride. Why now:
prompt 04 gave the ★ plan reminders and a recommender, but a plan you can't share is a plan stuck on
one phone — and a festival with no signal is exactly where AirDrop-a-QR beats any cloud.

## Context the implementer needs

- **Reuse the `SharedRoutine` stack end-to-end — do not reinvent.** `Core/SnappetShareable.swift`
  (protocol + `QRCodeImage`), `Core/SnappetScannerView.swift` (the camera scanner), and
  `Features/WorkoutTracker/SharedRoutine.swift` (the `snappet://…/v1/<blob>` codec, the shared
  `ZlibCodec` raw-DEFLATE + `Base64URL`, `fitsInScannableQR`, `init?(decoding:)`, the deep-link →
  router one-shot → import-confirm path) are the template. The `.fpack` codec already funnels through
  the **same** `ZlibCodec` (decisions.md 2026-07-16), so the QR blob reuses that compression story,
  not a new one.
- **A plan IS a `FestivalPack`.** The keystone move: a "share my plan" is the same pack with its set
  list filtered to the stars, re-stamped under the SAME pack id. Because set ids are UUIDv5 content
  identity (prompt 01), the receiver's set ids line up byte-for-byte — so applying a shared plan stars
  exactly the sets the sharer starred, with zero new identity scheme. Do NOT change `FestivalPack` /
  the wire format; the subset builder lives in the new file.
- **The payload-vs-link cliff is `SharedRoutine`'s, tuned up.** Small subject (a day plan, a
  hand-built lineup) → the whole thing deflates into the code (`snappet://festival/v1/<blob>`),
  offline-scannable. Too big (a whole multi-day festival is tens of KB) → fall back to an
  **install-link QR** (`snappet://festival/install/<packID>?h=<host>`) that the receiver fetches once
  through the existing `FestivalLineupInstaller`. The cap is higher than routine's 900 (the wireframe
  wants a ~dozen-set plan, ~1.1 KB, in the code).
- **Never silent, never overwrite.** A scan/open lands an import-confirm preview (the
  `RoutineImportSheet` analog), then installs a new lineup / applies a plan on confirm. Reuse the
  existing installer's replace-by-`packID` for a whole lineup (that's how revisions arrive; stars
  survive); a plan onto a lineup you already have just inserts `FestivalStar` rows.
- **Keep the decisions pure.** The codec, the payload-vs-link boundary, the route parse, and the
  never-silent receive decision are all pure value logic — unit-test them without a camera (drive the
  route directly, `RoutineImportRouteTests` posture). The camera scan + the share sheet stay thin.

## Approach

All in `ios/App/Snappet/Features/Festival/`, pure logic split from thin edges:

- **`SharedLineup.swift`** (pure, `SnappetShareable`) — two wire forms in one type: `.payload(pack)`
  (`snappet://festival/v1/<blob>`, `base64url(deflate(terse JSON))` via the shared codec) and
  `.installLink(packID:host:)` (`snappet://festival/install/<packID>?h=&t=&k=`). `plan(from:starred:)`
  (subset pack), `lineup(from:)`, `scannableForm()` (the pure size cliff), `receiveAction(installedPackIDs:)`
  (the pure `installLineup` / `applyPlan` / `installPlan` / `fetchInstall` decision), `subsetPack`,
  `init?(decoding:)`. `scannableURLByteCap = 1400`.
- **`FestivalShareView.swift`** (sheet, frame 12) — the `RoutineShareView` shape: segmented My Code /
  Scan; My Code carries a plan/lineup toggle and renders `scannableForm()` as a black-on-white
  `QRCodeImage` + an honest in-the-code/install-link note + a `ShareLink`; Scan is the shared
  `SnappetScannerView(decode: SharedLineup.init(decoding:))`, routing the decode to the host.
- **`FestivalImportSheet.swift`** (sheet, frame 13) — the import-confirm preview: title, set count,
  what the (pure) `receiveAction` will do, one CTA that runs it. The `RoutineImportSheet` analog.
- **Routing** — extend `SnappetDeepLink` with `.festivalLineup(SharedLineup)`; add
  `SuiteRouter.pendingFestivalImport`; `RootShell.handle` stages the one-shot + `open(module: festival)`.
  `FestivalRootView` consumes it (the `pendingKilterClimb`/`initial: true` pattern) into the
  import-confirm and executes the action against the installer/store; adds a "Scan a friend's QR"
  entry (root list + empty state) via a bare `FestivalScanView`. The schedule ⋯ menu and the recap
  Share present `FestivalShareView` (an in-app scan routes through the same router one-shot).
- **`FestivalLineupInstaller`** grows `install(pack:sourceLabel:into:)` — install an already-decoded
  pack (the QR-payload path, no fetch) reusing the same validate → row → replace-by-packID logic.

## Output

- `ios/App/Snappet/Features/Festival/` — `SharedLineup`, `FestivalShareView`, `FestivalImportSheet`;
  edits to `FestivalRootView`, `FestivalScheduleView`, `FestivalRecapView`, `FestivalCatalogViews`
  (empty-state scan), `FestivalCatalogProvider` (decoded-pack install)
- Central wiring: `Features/Kilter/KilterDeepLink.swift` (`SnappetDeepLink.festivalLineup`),
  `Core/SuiteRouter.swift` (`pendingFestivalImport`), `Features/Shell/RootShell.swift` (route case)
  — no schema/backup change (stars/lineups already modeled)
- Tests: `SharedLineupTests` (round-trip plan/lineup, matching content ids, tampered/oversized/
  wrong-version rejection, the size-cliff fallback boundary, the receive-decision table),
  `FestivalImportRouteTests` (the `snappet://festival/…` parse accept/reject + the router one-shot);
  `FestivalFixtures.bigFestival` for the oversized case
- `ios/App/SnappetUITests/FestivalUITests.swift` — the share-sheet walkthrough (⋯ → Share my plan →
  QR renders; the Scan tab shows the scanner)
- `docs/knowledge-graph/data.js` — `SharedLineup` / share sheet / import sheet nodes + edges
  (schedule/recap/root → share; scan/open → router one-shot → import-confirm → installer/stars)
- `pdd/context/decisions.md` — same-day entry for the non-obvious calls

## Acceptance criteria

- [ ] A day plan / small lineup shares as an offline payload QR; decoding it yields the same set
      content ids, so a shared plan stars exactly the sharer's sets.
- [ ] A whole multi-day festival exceeds the scannable cap and falls back to an install-link QR that
      the receiver fetches through the existing installer.
- [ ] Scanning / opening a `snappet://festival/…` code lands a never-silent import-confirm; confirming
      installs a new lineup or applies the plan; nothing is silently overwritten.
- [ ] The codec, the payload-vs-link boundary, the route parse (accept/reject, wrong version), and the
      receive decision are unit-tested without a camera; tampered/oversized blobs are rejected.
- [ ] Unit suite green; full XCUITest suite green (this PR has real UI); 0 Swift 6 warnings;
      `HighlightEngine` untouched; no `.fpack` / matcher / model change.
- [ ] Knowledge graph + `decisions.md` updated in the same change.

## Constraints

- On-device only: no backend/accounts; the ONLY network is the install-link fallback's one GET to the
  already-configured host. Reuse the shared codec/renderer/scanner — no duplicated compression or QR
  code.
- Do not touch the `.fpack` wire format, the matcher's confidence semantics, or the existing
  `FestivalPack`/`FestivalLineup`/`FestivalStar`/`FestivalAttendance` models. No poster scan (prompt 06).
- Verification honesty: a real phone-to-phone camera scan is a device leg — state it owed, not
  verified; the sim UI test drives the route/share chrome, not the camera.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — the round-trip / rejection / size-cliff / receive
   tables + the route parse.
2. `make ios-test SIMULATOR='iPhone 17 Pro'` — full suite incl. the seeded share-sheet walkthrough.
3. Device (owed): show a plan QR on one phone, scan it with a second, confirm the friend's sets land
   in the plan; confirm an install-link QR fetches a hosted lineup.
