# Recap Feed — Remediation Plan (stacked PRs to full plan conformance)

**Created**: 2026-06-21
**Owner**: driven via PDD (one prompt = one job = one PR), each PR: **plan → implement → build+unit → adversarial review → device-verify (if device) → commit/push/PR**.
**Source of truth**: the committed phase prompts in this folder (F3/F3b/F4/F5/F7). This plan does **not** restate them — it sequences the *missing/stubbed* work the conformance audit found into reviewable, stacked PRs.

## Why this exists

The conformance audit (2026-06-21) found F0/F0b/F1/F6 conformant, but the **media / share / masonry / milestone** layer short of plan — and importantly, **pure sim-testable logic was dropped, not just device-burn**. Root cause: the "honest device-burn placeholder" pattern was over-applied (it swallowed pure predicates/models), reviews audited written code instead of diffing each prompt's Output list against the filesystem, and a green suite was read as "complete" when the dropped pieces simply had no tests.

## Standing rules for every PR in this stack

- **Keystone rule**: never edit the F0 ordering core (`salience × recencyDecay`). New behavior = a `FeedComposer` registry entry / payload enrichment, never a hand-inserted card.
- **Reuse the editor's HR overlay system — do NOT reinvent**: export burn-in → `StudioOverlays.makeAnimationTool` / `hrTileLayer`; WYSIWYG preview → `HRTileView(tile:values:fraction:)`; model/resolve → `HRTile` / `HROverlayValues` / `HRTileLayout`. The feed currently hand-rolls HR text in `MediaBrowserView` — that is the divergence to remove.
- **Pure-first**: every PR's decision/mapping/eligibility logic lands as Foundation-only files with `SnappetTests` coverage; the device edge (AVPlayer attach, AVFoundation export, Photos, ImageRenderer pixels) is a thin layer over it and flagged as device-burn.
- **Output-manifest gate** (the process fix): before marking a PR done, diff its prompt's Output list against the filesystem — present / absent / renamed. No silent omissions.
- **Verify honestly**: type-check ≠ device run. Each device-burn item is verified on MrRobot (`id=00008110-001928301A87601E`) before the PR is called done.
- **Stacking**: base = `recap-ios` (existing feed PR #228 + the in-viewer playback precursor). Each PR branches off the previous (`recap-ios → recap-r1 → recap-r2 → …`).

## The stack (ordered by dependency; pure keystone debt first)

| PR | Title | Kind | Depends on | Maps to audit |
|----|-------|------|-----------|----------------|
| **R1** | F3 pure core: `clipReady` eligibility + hero resolver + active-player index | PURE | recap-ios | items 1,3,4 |
| **R2** | F3 device hero: `FeedClipPlayer` + resolver-driven card hero (single active, muted/loop) | DEVICE | R1 | item 9 — **(a)** |
| **R3** | F4 pure model: `ShareTemplateModel` (gating, aspect math, channels) + `ShareImageRenderer` | PURE | recap-ios | item 2,10-pure |
| **R4** | F4 Animate: real render→Save with editor HR-overlay burn-in + cancellable progress | DEVICE | R3 | item 8 — **(b)** |
| **R5** | F4 template library: Grade PR Ticket · Board Polaroid · Pyramid Card + metric toggles | views | R3 | item 10-views |
| **R6** | F3b: in-card `FeedMediaCarousel` + paged viewer + WYSIWYG `HRTileView` overlay + Share/Animate | DEVICE | R2,R4 | items 7,11 |
| **R7** | F5 milestone fixes: b5 record-variant + liftPR running/timed gate + payload fields | PURE | recap-ios | item 5 |
| **R8** | F7 wall: consume composed+lens corpus + keyset pagination + inline grid toggle + PulsePro tile | PURE+render | R1 | items 6,12 |
| **R9** | Coverage + docs: missing UITests + KG nodes/edges + decisions.md + F1 scroll/pill/skeleton | sim/device+docs | all | items 13,14,15 |

### Per-PR detail

**R1 — F3 pure core** [PURE]
- `Feed/FeedClipEligibility.swift`: pure `clipReady(hasVideo:hasHR:planSegments:) -> Bool` + the `ReelPlan`-from-`SessionHighlightInput` wiring (HighlightEngine/ReelPlanner, no AVFoundation).
- `Feed/FeedHeroResolver.swift`: pure `clip → photo → generated` tier decision (eligibility + centrality + reduceMotion → tier).
- `Feed/FeedActivePlayerCoordinator.swift`: pure nearest-viewport-center index + hysteresis (synthetic geometry → active index).
- `FeedComposer`/`FeedCard`: additive a1-payload enrichment with the top clip ref + `clipReady` flag (registry predicate; **no** ordering-core edit).
- Tests: `FeedClipEligibilityTests`, `FeedHeroResolverTests`, `FeedActivePlayerCoordinatorTests`.
- Review: keystone untouched; truth tables complete. Verify: unit suite green (no device).

**R2 — F3 device hero** [DEVICE = (a)]
- `Services/FeedClipPlayer.swift`: muted/looping single `AVPlayer`/`AVQueuePlayer`+`AVPlayerLooper` attach/teardown for the top segment; Low Power / reduceMotion aware. (Reuse the `ClipPlayerLayer` precursor.)
- `FeedCardView` a1 hero slot: resolver-driven — clip when central (per R1 coordinator fed by scroll geometry in `FeedView`), still otherwise. No F1 shell change beyond the hero slot.
- KG: `feed-clip-player` node + edges → session-media / highlight-engine / reel-planner.
- Verify on device: one player at a time; central animates, off-screen freezes; reduceMotion/Low Power → still; no audio leak.

**R3 — F4 pure model** [PURE]
- `Feed/ShareTemplateModel.swift`: `eligibleTemplates(for:)` payload gating, `ShareAspect` → exact pixel size/scale, default `visibleMetrics`, `ShareEvent` channel derivation from chosen activity.
- `Feed/ShareImageRenderer.swift`: exact-dimension `ImageRenderer` wrapper (off-main where heavy).
- Refactor `FeedShareComposer` to gate templates (no dead thumbnails) + use the renderer.
- Tests: `ShareTemplateModelTests` (dimension math, gating across rich/sparse payloads, channel derivation, visible-metric defaults).

**R4 — F4 Animate** [DEVICE = (b)]
- `Services/ReelExporter.swift`: additive `export(_:hrOverlay:)` overload that attaches `StudioOverlays.makeAnimationTool` (built from `HROverlayValues.resolveTile(HRTile.make(template:))`) — **the editor's burn-in**; default `nil` keeps existing callers unchanged.
- `Feed/ClipExportCoordinator.swift`: replace the stub with the real `SessionHighlightInput → app.engine.selector → app.reelPlan → export(hrOverlay:) → MediaLibraryService.saveVideoToPhotos` pipeline; cancellable; name-tag (`audienceTo`) refs; append `ShareEvent` (channel reflects outcome) on success.
- `FeedShareComposer`/`CardDetailView`: drive it with progress + result; pass `AppModel` + the session's clips/HR/duration.
- Verify on device: a real reel lands in Photos; the burned overlay matches the WYSIWYG; music omitted; `ShareEvent` appended.

**R5 — F4 template library + toggles** [views]
- `Feed/ShareTemplates.swift`: `GradePRTicketTemplate`, `BoardPolaroidTemplate`, `PyramidCardTemplate` over `PulsePro`/`.snappetCard()`/`SnappetColor` (no new tokens). Wire `visibleMetrics` toggles (preview == export). Gated by R3's `eligibleTemplates`.

**R6 — F3b carousel + paged viewer** [DEVICE]
- `Feed/FeedMediaCarousel.swift`: in-card carousel (dots / count badge / peek / View-all) on the a1 card.
- Paged `TabView(.page)` fullscreen viewer (replaces the single-clip `ZStack`); reuse the playback precursor.
- **Reuse `HRTileView`** for the per-clip overlay (WYSIWYG, editor parity) — remove the hardcoded HR text.
- Share/Animate button in the viewer → routes into R3/R4.
- Tests: General-bucket + cross-session grouping; clip-HR window boundaries (before/after/partial/zero-dur photo/sparse HR).
- Verify on device: swipe between clips, overlay matches editor, Share/Animate reachable.

**R7 — F5 milestone fixes** [PURE]
- Extend `StreakPayload` (`isRecord`/`previousBest`) + compute prior-best → b5 record-variant; add `LiftPRPayload.unit`; gate `liftPRCards` to skip running/timed exercises.
- Tests: b1 all-time-max validation, b5 record-variant. Fix `decisions.md` b2 statement.

**R8 — F7 wall** [PURE+render]
- `WallView` consumes `FeedView`'s composed + lens-filtered corpus (not a re-derive) and reuses `FeedPagination` keyset cursor.
- Inline grid toggle (`@State` layout flip + scroll preservation) instead of the `.sheet`.
- `FeedWallTile` over `PulsePro.DisciplineHero` + `StatRibbon` + `.snappetCard()`.
- KG: `feed→feed-wall`, `feed-wall→card-detail`, `feed-composer→feed-wall` edges.

**R9 — coverage + docs debt** [sim/device + docs]
- UITests: `FeedHRCardUITests`, `FeedAutoClipUITests`, `FeedMediaCarouselUITests`, `ShareComposerUITests`, `RecapStoryUITests`, `FeedWallUITests`.
- F1: scroll-offset restore + non-yanking pill + skeleton/optimistic-insert.
- KG nodes/edges + `decisions.md` cleanup across F2/F3/F4/F5/F7; record F3 architecture decisions.

## Definition of done (whole feature)

Every Output line of F3/F3b/F4/F5/F7 is present (or renamed-with-justification); the dropped pure logic has tests; every device-burn path is wired (not stubbed) and verified on MrRobot; the editor HR overlay is reused on both feed surfaces; the full `SnappetTests` suite is green; knowledge-graph + `decisions.md` reflect reality.
