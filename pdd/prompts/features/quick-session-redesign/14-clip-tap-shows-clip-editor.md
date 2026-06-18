# Prompt: Studio editor — tapping a clip shows the CLIP editor, not the climb-tag editor

**File**: pdd/prompts/features/quick-session-redesign/14-clip-tap-shows-clip-editor.md
**Created**: 2026-06-18
**Chain**: bug-fix after prompt 12/13. Source: user (on-device).

## Goal
Tapping a video clip in the timeline opens the **clip** editor (trim/speed/filter/split/…). It must NOT
auto-select the clip's climb tag and pop the **overlay** editor — that hides the clip's options. The climb
tag is selected/edited ONLY by tapping the tag itself (its overlay-lane bar or the canvas chip).

## Root cause (verified, file:line)
Prompt 12 STEP 5 added a clip→overlay coupling: `select(_:)` (StudioEditorViewModel.swift:372-383) repoints
`selectedOverlayID = climbOverlayForSelectedClip?.id` when selecting a clip (so the dynamic Attempt# could
"follow the selected clip"). But the bottom panel is `if vm.selectedOverlay != nil { overlayBar } else
{ actionBar }` (StudioEditorView.swift:50) — so selecting a CLIP pops the OVERLAY editor. Now that every
tag is a PER-CLIP property (`clipID`, prompt 12), the clip-coupling is obsolete: a tag's attempt is
intrinsic to its OWN clip, so it never needed to follow "whichever clip is selected."

## Approach (minimal, surgical)
1. **`select(_:)`** (clip selection): set `selectedOverlayID = nil` (deselect any overlay → the clip editor
   shows). Remove the `climbOverlayForSelectedClip` repoint AND the `refreshAttemptLineForSelection()` call.
2. **Attempt# from the overlay's own clip.** Extract `attemptNumber(forClipID:)` (the existing
   `selectedClipAttemptNumber` fetch, generalized). Rewrite `effectiveAttemptNumber` to use the SELECTED
   overlay's `clipID` (a climb tag) → that clip's attempt; fall back to `selectedClip?.id` (the add-a-tag
   moment, before the new overlay is selected) → then the threaded `suggestedAttemptNumber`. Remove the now-
   unused `selectedClipAttemptNumber` + `refreshAttemptLineForSelection`.
3. Selecting the tag (overlay-lane `OverlayBar.onSelect → vm.selectOverlay`, or the canvas chip) is
   UNCHANGED — it sets `selectedOverlayID` → `overlayBar` shows the Attempt#/opacity panel. `hasClimbOverlay`
   / the "Climb ✓" state read `climbOverlayForSelectedClip` (clip HAS a tag), independent of selection — so
   the button state is unaffected.

## Acceptance criteria
- [ ] Tapping a clip in the timeline shows the clip editor (its options), never the climb-tag overlay panel.
- [ ] Tapping the climb-tag bar (overlay lane) or the tag on the canvas shows the overlay (Attempt#/opacity) panel.
- [ ] The "Attempt #" toggle, when the tag is selected, uses that tag's own clip's attempt number (correct in
      "Edit all clips" and single-clip). "Climb ✓" button state unchanged.
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green;
      the studio walkthrough + climb UITests pass.

## Test plan
`xcodegen generate`; `simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; `LiveWorkoutStudioWalkthroughTests` (flaky — retry once) + `NamedClimbTests`/`EditClimbTests`. Device-only: the tap-target feel. Commit `fix(quick-session): tapping a clip shows the clip editor (not the climb-tag overlay editor); attempt# derives from the tag's own clip`.
