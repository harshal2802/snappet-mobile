# Prompt: Studio editor — scope overlays to the visible clips (fix single-clip tag bleed)

**File**: pdd/prompts/features/quick-session-redesign/13-scope-overlays-to-visible-clips.md
**Created**: 2026-06-18
**Chain**: bug-fix after prompt 12. Source: user bug report + 11-agent code review (`13-review-findings.json`).

## Goal
Open one clip → see ONLY that clip's climb tag. Today the single-clip editor (and the overlay-timeline
lane and export) shows the **next** attempt's tag too, because `visibleClipMediaIDs` scopes the CLIPS but
never the OVERLAYS.

## Verified root cause (file:line)
`visibleClipMediaIDs` filters clips via `StudioGeometry.filterByMedia` (StudioGeometry.swift:22-25, keyed
on `TimelineClip.sessionMediaID`), but every overlay accessor returns the WHOLE project set:
`canvasOverlays` (StudioEditorViewModel.swift:162 `renderedOverlays(snapshot.overlays)`),
`timelineOverlays` (:668 `overlays`), and `scopedSnapshot.overlays` (:150 `renderedOverlays(s.overlays)`).
A foreign overlay's clip isn't in `placedClips`, so `outputWindow(for:)` (:195-201) falls back to its
stored ~`[0,clipDur]` window, which overlaps the visible clip's `[0,2]` and passes the canvas/export
time-gate → it renders on the canvas, the overlay lane (StudioTimelineView.swift:80, no gate at all), AND
the exported file (StudioComposer reads `scopedSnapshot.overlays`).
**Key mismatch:** `OverlayItem.clipID` is a `TimelineClip.id`; `visibleClipMediaIDs` is a Set of
`SessionMedia.id` — scoping needs `clipID → owning TimelineClip → sessionMediaID → membership`.
**Symptom "default tag (Attempt# ON) always shows even though I set it once" is the SAME leak** — it's
the other clip's persisted tag (with its flags) bleeding in. It is NOT a persistence/default bug: nothing
auto-adds a tag and the flags persist (verified). **Do NOT change the toggle defaults or add a reset.**

## Approach (minimal, low-risk)
1. **Pure helper** `StudioGeometry.filterOverlays(_ overlays:[OverlayItem], clips:[TimelineClip], to mediaIDs:Set<UUID>?) -> [OverlayItem]`:
   `nil` mediaIDs → all; an overlay with `clipID == nil` → keep (whole-project overlay shows in every
   scope); else find the clip in `clips` with `id == clipID`, take its `sessionMediaID`, keep iff it's in
   `mediaIDs` (orphan / no media id → drop when scoping). Pure (no SwiftUI) → unit-tested.
2. **VM** `scopedOverlays` = `StudioGeometry.filterOverlays(snapshot.overlays, clips: snapshot.clips, to: visibleClipMediaIDs)`.
3. Swap THREE accessors: `canvasOverlays` → `renderedOverlays(scopedOverlays)`; `timelineOverlays` →
   `scopedOverlays`; `scopedSnapshot.overlays` → `renderedOverlays(scopedOverlays)` (safe outside the
   `if visibleClipMediaIDs != nil` guard — `filterOverlays` returns all when scope is nil).
4. **Leave** `overlays` / `selectedOverlay` / `climbOverlayForSelectedClip` reading the FULL `snapshot.overlays`
   so a scoped edit still persists to the shared project and add-or-select stays idempotent.
5. Test in `StudioGeometryTests.swift`: 2 clips (mediaA/mediaB) each with a `.climbName` overlay
   (clipID = each clip) + one `clipID == nil` overlay; `filterOverlays(..., to: [mediaA])` returns only
   clipA's tag + the nil one; `to: nil` returns all; an orphan clipID is dropped when scoping.

## Acceptance criteria
- [ ] Opening one climb clip shows exactly ONE climb tag (its own); the overlay-timeline lane shows one
      bar; export burns in only that clip's tag.
- [ ] "Edit all clips" (scope = all) still shows each clip's tag (no regression).
- [ ] No change to toggle defaults / persistence (symptom #1 resolved by scoping).
- [ ] `xcodegen generate` + `build-for-testing` clean (0 new warnings); full `SnappetTests` green incl. the
      new `filterOverlays` test.

## Test plan
`xcodegen generate`; `simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; the studio + climb UITests. Commit `fix(quick-session): scope studio overlays to the visible clips (single-clip editor no longer shows the next attempt's tag)`.
