# Prompt: F4 — iOS ShareComposerCover + named template library + auto-clip export

**File**: pdd/prompts/features/feed/F4-ios-sharecomposer.md
**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: PLAN.md → F4 (depends on F2 and F3; closes the iOS share loop)
**Source**: GitHub epic "Recap Feed" → issue "F4 iOS ShareComposer + auto-clip export"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`
**Design**: `/tmp/feed-dossier/_locked-design.md` §3 (sub-surface 5 + flow), §5 (`clipReady`), §6.1+§6.3 (Pillars 1 & 3), §7 (degradation), §11 wireframes 16–18, 19

## Goal

Close the share loop on iOS: build the **`ShareComposerCover`** sheet that turns any `FeedCard` into a shareable artifact. It offers a **named template library** — *Send Card · Session Receipt · Grade PR Ticket · Board Polaroid · Pyramid Card* — rendered **on-device at exact 9:16 / 4:5 / 1:1** via `ImageRenderer` (no Apple cropping bug, `_locked-design.md:46`, `194`, `290`), with a live WYSIWYG preview and aspect/metric toggles, handed off to the OS via `ShareSheet` (`UIActivityViewController`). For sessions that are `clipReady` (`SessionMedia` video + HR, non-empty `ReelPlan` — F3 already surfaces this card), the **Animate** path drives `ReelExporter` to burn the HR overlay into a clip with structured name-tag refs. Every successful export appends a `ShareEvent(channel: "export:*")` to the F0b log (`_locked-design.md:69`, `109`). This is the artifact-creation surface the entire "one tap from shareable" north star (`_locked-design.md:11`) rests on — and the highest device-burn risk in the iOS wave.

## Context the implementer needs

- **Two callers, one cover (`_locked-design.md:64-66`):** `ShareComposerCover` is reached from `CardDetailView`'s **Share** button (F2) and from per-scene **Share** in the Story Player (F6, later). It takes a `FeedCard` (the pure value type from F0) plus optional `SessionMedia`/`ReelPlan` context. It must render from the card's already-computed `payload` — **never re-derive stats** (the `TodayDigest` derive-on-read discipline, same as F1/F2). The composer is purely a *renderer* of card numbers onto templates.
- **Template library = named object templates over `PulsePro` + `SnappetColor`.** Each template is a SwiftUI view bound to a `ShareTemplate` enum case (`Send Card`, `Session Receipt`, `Grade PR Ticket`, `Board Polaroid`, `Pyramid Card`). Build them from `PulsePro.DisciplineHero`/`StatRibbon`/`pulseGlassChrome` (`DesignSystem/PulsePro.swift:11`) on `.snappetCard()` surfaces (`DesignSystem/SnappetCard.swift:28`) with discipline edge accents (`SnappetColor.kilter`/`.workout`) — **no new brand tokens**. The card's `shareHint: ShareTemplate?` (F0, `_locked-design.md:125`) pre-selects the suggested template; user can switch. Not every template fits every card (a Pyramid Card needs pyramid data) — gate the offered set by the card's `payload`, exactly the eligibility discipline (no dead template thumbnails).
- **Exact-dimension image render (the cropping-bug mitigation, `_locked-design.md:290`):** use `ImageRenderer` over the template view sized to the *exact* pixel dimensions of the chosen aspect (9:16 / 4:5 / 1:1) at a fixed scale, producing a `UIImage`/`Data` at the literal target size so Instagram/iMessage perform **zero re-crop**. Set `proposedSize` explicitly; do not rely on intrinsic sizing. Render off the main thread where the work is non-trivial.
- **Aspect + metric toggles (wireframe 17):** 9:16 / 4:5 / 1:1 selector and per-metric show/hide chips drive the live preview, which is the same view that gets rendered (WYSIWYG = export, the Glass-HUD WYSIWYG principle, reuse `Services/StudioOverlays.swift` + `HRTile.swift:13` styling for any HR overlay so preview matches the burned clip).
- **OS handoff:** present results through the existing `ShareSheet` (`Features/Shell/ShareSheet.swift`, `UIActivityViewController`). Music is **omitted** for a clean IG/iMessage/Photos handoff (`_locked-design.md:67`, `194`, `283`). IG Stories sticker handoff is a share-sheet activity, not a custom integration.
- **Animate path (Pillar 3, `_locked-design.md:198`):** only when the source card is `clipReady`. Feed `SessionMedia` (`Features/WorkoutTracker/SessionMedia.swift:23`) + HR into `SessionHighlightInput` (`Features/WorkoutTracker/SessionHighlightInput.swift`) → `HighlightEngine`/`ReelPlanner` rank/plan segments → `ReelExporter.export(_ plan:)` (`Services/ReelExporter.swift:24,164`) + `AVVideoCompositionCoreAnimationTool` burn the HR overlay (reuse `StudioOverlays`/`HRTile` styling). **Heed the dossier export gotchas (`_locked-design.md:198`):** drive only **built-in** CALayer animatable props (custom CALayer props do NOT export), layer-instruction background = `.clear`, export off-main-thread with **cancellable progress**, music omitted. **Name tags are structured `audienceTo` refs** (`_locked-design.md:198`, model §4.1) — the display name is burned into the visual, the ref is retained for future account resolution (do not invent a tagging UI beyond display-name capture).
- **Append `ShareEvent` on success (`_locked-design.md:69`, `109`):** on a completed export (image or clip), append a `ShareEvent { activityContentId, channel, createdAt }` row via the F0b append-only writer. `channel` is `"export:instagram"` / `"export:imessage"` / `"export:photos"` etc. — derive it from the activity completion / chosen activity type where available, else a generic `"export:share"`. The seam matters: `export:*` today, `user:*` tomorrow, table shape unchanged (`_locked-design.md:112`, `145`).
- **Device-burn truth (`_locked-design.md:290`, conventions):** `ImageRenderer` output, `UIActivityViewController` handoff, `AVFoundation` clip export, and Photos write are **device/runtime paths that the simulator cannot honestly prove**. Keep the template *layout* and *dimension math* pure and unit-testable; flag the render/export/share/Photos steps as device-burn in `decisions.md` and the test plan.
- **Keystone rule (`_locked-design.md:236`):** F4 adds **no new `FeedCardKind` and does not touch the F0 ordering core.** `clipReady` already exists (F3). F4 consumes cards; if a new card were ever needed it would be a `FeedComposer` registry entry, never an edit to the ordering core.
- New files live under `ios/App/Snappet/Features/Feed/` (F0 created it).

## Approach

- `Feed/ShareComposerCover.swift`: the cover/sheet — takes a `FeedCard` (+ optional media/plan context); top = template thumbnail picker (gated by card payload, `shareHint` pre-selected), middle = live WYSIWYG preview at the chosen aspect, bottom = aspect selector (9:16/4:5/1:1) + metric toggles + **Share** (image) and, when `clipReady`, **Animate** (clip) actions.
- `Feed/ShareTemplates.swift`: the named template views (`SendCardTemplate`, `SessionReceiptTemplate`, `GradePRTicketTemplate`, `BoardPolaroidTemplate`, `PyramidCardTemplate`) over `PulsePro`/`.snappetCard()`/`SnappetColor`, each a single view parameterized by the card payload + visible-metric set.
- `Feed/ShareTemplateModel.swift` (pure): `ShareAspect` (`.r9x16/.r4x5/.r1x1`) → exact pixel size + scale; the `eligibleTemplates(for:)` payload-gating function; the `visibleMetrics` defaults per template; the `ShareEvent` channel derivation from an activity completion. All Foundation-only, no SwiftUI/AVFoundation — unit-testable.
- `Feed/ShareImageRenderer.swift`: wraps `ImageRenderer` to produce exact-dimension `UIImage`/`Data` for a given template view + `ShareAspect` at the literal target size (no re-crop), off-main where needed. Thin device edge.
- `Feed/ClipExportCoordinator.swift`: the Animate path — assembles `SessionHighlightInput` → `ReelPlanner` → `ReelExporter` with HR-overlay burn-in (built-in CALayer props, clear background), cancellable progress, name-tag (`audienceTo`) burn-in. Thin device edge over existing engines/services.
- `CardDetailView` (F2) Share button → presents `ShareComposerCover`. On export success → append `ShareEvent` via the F0b writer.
- Pure helpers (aspect→dimension math, template gating, channel derivation) in testable files; XCUITest covers detail → Share → template/aspect pick → present share sheet (image path). Animate/export/Photos = device-burn.

## Output

- `Feed/ShareComposerCover.swift` — the sheet: template picker + live WYSIWYG preview + aspect/metric toggles + Share/Animate actions.
- `Feed/ShareTemplates.swift` — the five named template views (Send Card / Session Receipt / Grade PR Ticket / Board Polaroid / Pyramid Card) over Pulse-Pro/SnappetColor.
- `Feed/ShareTemplateModel.swift` — pure `ShareAspect` dimension math, `eligibleTemplates(for:)` payload gating, default visible-metric sets, `ShareEvent` channel derivation.
- `Feed/ShareImageRenderer.swift` — exact-dimension `ImageRenderer` wrapper (no re-crop).
- `Feed/ClipExportCoordinator.swift` — Animate path: `SessionHighlightInput`→`ReelPlanner`→`ReelExporter` HR-overlay burn-in + cancellable progress + name-tag refs.
- `CardDetailView.swift` (F2) — Share button presents `ShareComposerCover`; success appends `ShareEvent`.
- `SnappetTests/ShareTemplateModelTests.swift` — pure tests: aspect→exact-dimension math, template gating by payload, channel derivation, visible-metric defaults.
- `SnappetUITests/ShareComposerUITests.swift` — detail → Share → pick template + aspect → share sheet presents (image path).
- `docs/knowledge-graph/data.js` — add `feed-export` node (ShareComposerCover); `navigate` edge feed-detail→feed-export; `uses` edges feed-export→ShareSheet, feed-export→ReelExporter, feed-export→PulsePro; `feeds` edge feed-export→feed-activity (ShareEvent append).

## Acceptance criteria

- [ ] Tapping **Share** on a `CardDetailView` presents `ShareComposerCover` for that `FeedCard`, pre-selecting the card's `shareHint` template and offering only templates the card's payload supports (no dead thumbnails).
- [ ] The library renders all five named templates (Send Card · Session Receipt · Grade PR Ticket · Board Polaroid · Pyramid Card) over `PulsePro`/`.snappetCard()`/`SnappetColor` with discipline edge accents; preview is WYSIWYG with the export.
- [ ] Aspect selector produces images at **exact** 9:16 / 4:5 / 1:1 pixel dimensions via `ImageRenderer` (no Apple re-crop); the aspect→dimension math is pure and unit-tested. Metric toggles change both preview and exported image.
- [ ] Image export hands off via `ShareSheet` (`UIActivityViewController`) with music omitted; IG Stories / iMessage / Photos are reachable as share-sheet activities.
- [ ] For a `clipReady` card the **Animate** path is offered and drives `ReelExporter` with the HR overlay burned via built-in CALayer props (clear layer-instruction background), cancellable progress, structured name-tag (`audienceTo`) refs burned in; non-`clipReady` cards never show Animate (degrade by absence).
- [ ] On a successful export (image or clip), a `ShareEvent(channel: "export:*")` row is appended to the F0b log via the append-only writer; the channel reflects the chosen destination where available.
- [ ] F4 adds no new `FeedCardKind` and does not edit the F0 ordering core. App type-checks (Swift 6, 0 warnings); device-only paths flagged; `decisions.md` updated.

## Constraints

- On-device only; derive-on-read (no card persistence). Reuse `PulsePro`/`SnappetCard`/`SnappetColor`, `ShareSheet`, `ReelExporter`/`PhotoClipRenderer`/`SessionHighlightInput`/`HighlightEngine`, `StudioOverlays`/`HRTile` — no new brand tokens, no reinvented export.
- Render templates at exact target dimensions (no reliance on intrinsic sizing / no post-crop). Music omitted. Clip export and Photos write must be off-main-thread with cancellable progress; custom CALayer props must not be relied on for export.
- Append-only `ShareEvent` is the single side-effect into persistence; the composer reads `FeedCard` payloads and never re-derives stats. Verify honestly: type-check ≠ device run for `ImageRenderer`/`UIActivityViewController`/`AVFoundation`/Photos.

## Test plan

1. Unit: `ShareTemplateModelTests` — aspect→exact-pixel-dimension math (9:16/4:5/1:1), `eligibleTemplates(for:)` gating across rich/sparse payloads, `ShareEvent` channel derivation, default visible-metric sets — green; build-for-testing.
2. XCUITest: launch → Recap → tap a session card → detail → **Share** → assert `ShareComposerCover` presents with the pre-selected template → switch template + aspect → tap Share → assert the share sheet presents (image path). Sim wedge → `xcrun simctl shutdown all`, re-run.
3. **Device-burn (cannot prove in sim, flag in `decisions.md`):** on MrRobot — verify an exported image lands in IG Stories / iMessage / Photos at exact dimensions with **no re-crop**; verify the **Animate** path on a `clipReady` session burns the HR overlay correctly, progress is cancellable, music is absent, and a `ShareEvent` row is appended after each successful export.
