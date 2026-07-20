# Prompt: Festival poster scan (festival prompt 06)

**File**: pdd/prompts/features/festival/06-festival-poster-scan.md
**Created**: 2026-07-19
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData + Vision + FoundationModels) —
code lands in this repo only (poster scans aren't hosted; no web-repo companion).
**Chain**: `pdd/prompts/features/festival/README.md` → 06 of 06, the FINAL optional prompt (01 MERGED
#292, 02 MERGED #293, 03 MERGED #294, 04 MERGED #295, 05 MERGED #296 — build on the merged domain; do
NOT touch the `.fpack` wire format, the matcher's confidence semantics, or the existing models)
**Source**: user ideation session 2026-07-16; wireframes `docs/ux-research/festival/wireframes.html`
frame 2's "Scan a lineup poster" affordance + the honesty card (frame 8's data-posture note names
poster-scan structuring as the second on-device-FM use).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Close the last gap in "your festival lives on this device": a user whose festival has NO hosted
`.fpack` — a small local event, a lineup that only exists on a printed poster — can still build a
lineup by **photographing the poster**. The photo goes through **Apple Vision OCR** (on-device), the
noisy text is **structured into a draft** (Apple's on-device **Foundation Models** when available,
a pure heuristic parser always), and the user lands in an **editable review form** that becomes a real
lineup only after it passes the same `FestivalPackValidator` gate every hosted pack does. Why now: 01–05
built the whole domain around *installing* a lineup; poster scan is the one path that *authors* one, for
the festivals no catalog will ever carry — and it's the natural second home for the E7 on-device-FM seam
prompt 04 established.

## Context the implementer needs

- **Reuse the E7 wrapper pattern EXACTLY** (the locked seam): `FestivalPlanIntelligence` (prompt 04) and
  `WorkoutPlanIntelligence` are the shape — `#if canImport(FoundationModels)` + `@available(iOS 26.0, *)`
  + `SystemLanguageModel.default.isAvailable`, a `@Generable` output, a `withTimeout` guard, and silent
  degradation. Here the FM output is a *nested* `@Generable` lineup (days → stages → sets), and the floor
  is a real parser, not a template string — but the contract is identical: **the heuristic is the
  always-on path; the AI pass can never break it and can never install anything.**
- **Reuse the Vision OCR edge — do NOT add a second one.** `Services/ReceiptScanner.swift`
  (`VNRecognizeTextRequest`, pixels → newline-joined text) and `Services/ReceiptDocumentScanner.swift`
  (the `VNDocumentCameraViewController` SwiftUI wrapper, `isSupported` false on the sim) already own the
  on-device OCR edge for the receipt/expense feature. The poster capture presents the same document
  scanner and feeds its text straight into the pure parser.
- **The draft is NOT a `FestivalPack` yet.** A poster is noisy; forcing the parser to emit a valid pack
  would mean silently dropping rows it can't place. Instead a looser `FestivalDraft` (times as `"HH:mm"`
  strings, dates that may be blank, days/stages/sets the user edits) carries everything through to the
  review form; `draft.toPack()` builds the wire `FestivalPack` (which stamps UUIDv5 content ids), and
  only THEN does `FestivalPackValidator` run. A draft that doesn't validate surfaces the validator's
  exact message and installs nothing (the never-a-hallucination gate).
- **Local packs get a generated `poster-<hash>` id.** Hosted packs carry an author slug (`glastonbury-2026`);
  a poster scan has none, so `FestivalDraft.localPackID` is `poster-` + 12 hex of a UUIDv5 over the
  draft's normalized content. Deterministic, so re-scanning the same poster converges on the same id —
  and because set content-ids derive from the pack id (prompt 01), the same set ids.
- **Install through the existing funnel.** `FestivalLineupInstaller.install(pack:sourceLabel:into:)`
  (prompt 05's decoded-pack path) already validates → re-emits `.fpack` bytes → inserts (replace-by-packID).
  The review form calls it with `sourceLabel: "Poster scan"`; no installer change.
- **Entry point is the empty-state affordance** (wireframe frame 2's "Scan a lineup poster"), plus the
  non-empty root list. The camera is a device edge; the sim/UI test drives the flow through a pasted-text
  path (a genuinely useful secondary — paste a lineup off a webpage), never a real photo.

## Approach

All in `ios/App/Snappet/Features/Festival/`, pure logic split from thin edges:

- **`FestivalPosterParser.swift`** (pure floor + the `FestivalDraft` domain) — `parse(ocrText:
  defaultOffsetSeconds:) -> FestivalDraft`: first line = festival-title guess; `yyyy-MM-dd` lines start
  days; `HH:MM Artist` / `HH:MM - HH:MM Artist` rows are sets (single-time rows fabricate a +60-min end
  the user reviews); no-time stage-keyword / short-all-caps lines start stages; a plain pre-set line is
  the location guess. Garbage → a name guess + no days (an empty-but-valid draft the user fills, never a
  dead end). `FestivalDraft.toPack()` (combine day date + `"HH:mm"` at the offset, late-night sets cross
  midnight) + `localPackID` (the `poster-<hash>` scheme).
- **`FestivalPosterIntelligence.swift`** (thin FM edge, the E7 seam) — `draft(fromOCR:defaultOffsetSeconds:)
  async -> FestivalDraft`: parses the floor, and WHEN on-device FM is available restructures the same
  text into a nested `@Generable` lineup, taking it only if it's at least as complete as the floor;
  else returns the floor. `isIntelligenceAvailable` drives the "structured on device" badge.
- **`FestivalPosterScanView.swift`** (capture + review, two views) — the capture sheet (camera button
  when `ReceiptDocumentScanner.isSupported`, always a paste-text editor with a "Use a sample" affordance)
  builds a draft and hands it up; the draft-review editor is an editable `Form` (name/location/dates,
  days → stages → sets with add/delete) whose "Add to my festivals" runs `toPack()` → the installer's
  validate-before-install, surfacing the validator's exact error inline on failure.
- **Wiring** — `FestivalEmptyStateView` gains an `onScanPoster` affordance; `FestivalRootView` presents
  the capture sheet then the draft-review sheet (`.sheet(item:)`), installs via the shared installer,
  and logs `installPoster`. No schema/backup change (a poster lineup is just another `FestivalLineup`).

## Output

- `ios/App/Snappet/Features/Festival/` — `FestivalPosterParser` (+ `FestivalDraft`),
  `FestivalPosterIntelligence`, `FestivalPosterScanView` (capture + draft editor); edits to
  `FestivalCatalogViews` (empty-state affordance) and `FestivalRootView` (sheets + list entry)
- Tests: `FestivalPosterParserTests` (the parse table, draft→pack validation, the typed-error gate, the
  cross-midnight case, `localPackID` determinism + content-id convergence),
  `FestivalPosterIntelligenceTests` (the degrade-to-floor path)
- `ios/App/SnappetUITests/FestivalUITests.swift` — the poster walkthrough (empty state → sample → build →
  review editor pre-filled → install → the lineup lists)
- `docs/knowledge-graph/data.js` — poster-parser (floor) / poster-intelligence (FM) / capture / draft-editor
  nodes + edges (empty state → capture → Vision OCR → floor|FM → draft editor → validator → installer)
- `pdd/context/decisions.md` — same-day entry (the draft-not-a-pack call, the `poster-<hash>` scheme,
  the validate-before-install gate, the pasted-text sim path)

## Acceptance criteria

- [ ] A realistic multi-line poster string parses into the right days → stages → sets (title/location/
      date guesses, single-time vs ranged sets, late-night sets crossing midnight); garbage yields a
      name guess + no days, never a crash.
- [ ] The draft builds a `FestivalPack` that stamps content ids; two scans of the same poster converge on
      the same `poster-<hash>` id AND the same set ids.
- [ ] A draft that doesn't validate surfaces the validator's EXACT typed error and installs nothing; a
      clean one installs as a local lineup through the shared installer.
- [ ] With FM available the draft is FM-structured (source `.appleIntelligence`); with no entitlement it's
      the pure floor (source `.heuristic`) — the degrade path is tested and identical to the parser.
- [ ] Unit suite green; full XCUITest suite green (this PR has real UI); 0 Swift 6 warnings;
      `HighlightEngine` untouched; no `.fpack` / matcher / model change.
- [ ] Knowledge graph + `decisions.md` updated in the same change.

## Constraints

- On-device only: OCR is Apple's Vision, structuring is Apple's on-device Foundation Models — no network
  LLM, no cloud OCR, no Anthropic SDK. All FM gated + degrading to the pure parser when unavailable.
- Do not touch the `.fpack` wire format, the matcher's confidence semantics, the existing models, or
  `HighlightEngine`. Reuse the receipt Vision edge and the installer — no duplicated OCR or install path.
- Verification honesty: real-poster OCR accuracy and FM structuring quality on a device are device legs —
  state them owed, not verified; the sim UI test drives the pasted-text path, not the camera.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — the parse table, draft→pack + validation gate, the
   typed-error case, cross-midnight, `localPackID` determinism / content-id convergence, the FM degrade path.
2. `make ios-test SIMULATOR='iPhone 17 Pro'` — full suite incl. the seeded poster walkthrough.
3. Device (owed): photograph a real printed poster, confirm Vision reads it and (on an Apple-Intelligence
   device) the FM structures a cleaner draft than the floor; edit + install; confirm the local lineup
   tags clips like a hosted one.
