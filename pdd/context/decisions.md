# Decisions: Snappet Mobile (iOS)

Reverse-chronological. Each entry: the decision, why, and what it rules out. These are the
non-obvious choices already baked into the v0.1 code — written down so future prompts don't re-litigate
or accidentally reverse them.

## [2026-06-15] iOS — reel exporter: mixed-orientation normalization closes -11800 / -12902 regression (#139)

**Decision** (prompt 58): `ReelExporter.makeComposition` now returns `(AVMutableComposition, AVVideoComposition?)` instead of just `AVMutableComposition`. A **normalizing `AVVideoComposition`** is built alongside the composition: render canvas = first segment's oriented size (natural size × `preferredTransform`, rounded to even dims); one `AVMutableVideoCompositionInstruction` covering the full timeline; one `AVMutableVideoCompositionLayerInstruction` with piecewise `setTransform` calls per segment (`preferredTransform` concatenated with a uniform scale-to-fit + centering translate) so each clip orients correctly and aspect-fits (letterboxes) into the canvas without distortion. The `AVVideoComposition` is applied to `session.videoComposition` (export) and `AVPlayerItem.videoComposition` (preview) so preview and saved file match.
**Why**: without an `AVVideoComposition`, `AVAssetExportSession` cannot resolve one output format when segments have differing `naturalSize`/`preferredTransform` (e.g. portrait + landscape footage from different shooting orientations) → VideoToolbox returns `-12902` under `AVFoundationErrorDomain -11800`. The `VideoStudio` single-clip editor already did this; the flagship reel exporter never got the equivalent. The failure only surfaces on real device (P1 validation 2026-06-15) because the simulator has no real Photos footage to mix.
**Rules out**: a `renderSize` hardcoded at a standard resolution — using the first segment's oriented size preserves native resolution for same-orientation reels. Clips of differing aspect ratios letterbox (uniform fit-scale + center) rather than stretch.
**Also added**: `os_log` on export failure captures `AVFoundationErrorDomain code + NSUnderlyingError domain/code` to Console for field diagnosis; user-facing message stays the clean `localizedDescription`. `orientedSize` and `fitTransform` are `internal` (not `private`) so their pure geometry is unit-tested in `ReelExporterGeometryTests`.
**Supersedes (return type)**: the 2026-05-31 "In-app reel preview reuses the composition (P3)" decision recorded `makeComposition` returning `sending AVMutableComposition`; it now returns `sending (AVMutableComposition, AVVideoComposition?)`. All three callers — `ReelViewModel.buildPreview`, `SessionHighlightViewModel.generate`, `ReelExporter.export` — updated to unpack the tuple and set `videoComposition`.
**Verified on device**: Dance reel (mixed portrait/landscape clips) + MrRobot session, 2026-06-15.

## [2026-06-10] Android CRUD sweep: one confirm component, long-press as the secondary-action idiom (issue #88)

**Decision** (prompt 41): every destructive flow goes through **one** `ConfirmDeleteDialog`
(static title, consequence in the message, destructive confirm — the iOS `confirmationDialog`
idiom), and **long-press is the suite's secondary-action gesture** (the Budget category row had
already established it; swipe-to-dismiss was rejected — it fights LazyColumn scrolling and has no
established precedent in this codebase). Kilter ascents get **status correction** (not just
delete) — a fat-fingered Flash is fixed in place, preserving timing fields. Expense group deletion
**cascades records** via `deleteExpensesFor` (flat `groupId`, mirroring the iOS sweep). Group
EDITING reuses the dormant `NewGroupSheet(existing)` mode + pure cross-group name suggestions;
the iOS "remembered me" framing is deliberately deferred (beyond this issue's ACs). The recompute
guarantee is locked at the **pure layer** (`CrudRecomputeTest`) — the stats/balance functions are
pure over input lists, so delete-then-recompute equals never-existed.