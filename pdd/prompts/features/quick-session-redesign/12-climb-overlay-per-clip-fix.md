# Prompt: Fix climb-name overlay — make it a per-clip property (scoped, idempotent, correct)

**File**: pdd/prompts/features/quick-session-redesign/12-climb-overlay-per-clip-fix.md
**Created**: 2026-06-18
**Chain**: bug-fix after a deep review of the climb-name overlay (prompts 09–11). Source: user bug report + 13-agent code review.

## Goal
A freeform climb-name tag in the Studio editor must be a **property of its clip**: visible ONLY during
that clip's segment, **one tag per clip** (tapping "Climb" adds-or-selects, never duplicates), with the
"Attempt #" following the selected clip, and the editor preview matching the export. Fix the 12 issues the
review confirmed.

## Verified root cause (file:line)
`OverlayItem` (StudioProject.swift:175-261) has only `startSec/endSec` and **no clip link**.
`addClimbNameOverlay()` (StudioEditorViewModel.swift:426-440) hardcodes `startSec:0,
endSec:max(3,totalDuration)` and unconditionally appends (StudioProjectEditor.addOverlay:199-201, pure
append). The "Climb" button (StudioEditorView.swift:270) is a stateless fire-every-tap with no ✓ state.
The canvas (StudioOverlayCanvas.swift:54) renders `ForEach(overlays)` with NO playhead gate. `placedClips`
/ `StudioGeometry.timeline` (StudioEditorViewModel.swift:173-176, StudioGeometry.swift:51-80) ALREADY
expose each clip's output `[startSec,endSec]` (order/trim/speed/transition-correct). Export gates opacity
by window (StudioOverlays.applyVisibility:788-826).

## Fix plan (ordered; land STEP 1–5 together — they're interdependent)
1. **Model — `clipID` on `OverlayItem`.** Add `var clipID: UUID? = nil` (additive-optional, Codable
   migration-safe — follow the `highlightHex/fontRaw/boldRaw` precedent at :193-209). Make the climb tag a
   true per-clip property. (Also add explicit per-tag fields for STEP 6: `var showsAttempt: Bool = false`,
   `var attemptNumber: Int? = nil`, `var showsSetter: Bool = false` — all additive.)
2. **BUG #1 — confine to the clip.** In `addClimbNameOverlay()` set `clipID = selectedClip?.id` and the
   initial window from the selected clip's placed slot (`placedClips.first { $0.clip.id == selectedClip?.id }`
   → `startSec/endSec`); whole-project fallback when no clip is selected. **Resolve the window at RENDER
   time from `clipID`** → the clip's CURRENT placed slot (so trim/reorder/split never desync): add a helper
   `outputWindow(for overlay) -> (start,end)` used by BOTH the canvas gate and export (the export composer
   already maps clip→slot via `PlacedClipHR`, StudioOverlays.swift:38/63-69 — resolve there too). Export
   already time-gates, so just feed it the resolved window.
3. **BUG #2 — idempotent add-or-select.** In `addClimbNameOverlay()`, first
   `overlays.first { $0.kind == .climbName && $0.clipID == selectedClip?.id }`: if found, set
   `selectedOverlayID = existing.id` and return (re-seed base caption if changed); else add. Reflect a
   selected/✓ state on the "Climb" button (StudioEditorView.swift:270) like Music/HR (:264/:272).
4. **Canvas time-gate.** Thread `currentTime: vm.currentTime` into `StudioOverlayCanvas`
   (StudioEditorView.swift:165) + a stored member; gate the `ForEach` so an overlay renders only when
   `selected || outputWindow contains currentTime` (ALWAYS render the selected overlay so a just-added /
   off-segment tag stays draggable). Apply to `.text/.sticker` too. Also sample `opacityKeyframes` at the
   playhead and drop the 0.15 floor to match export (or apply the same floor both sides).
5. **Multi-clip attempt# correctness.** In `select(_:)` (StudioEditorViewModel.swift:303-308) repoint
   `selectedOverlayID` to the `.climbName` overlay whose `clipID == newly-selected clip.id` (or nil if
   none) BEFORE `refreshAttemptLineForSelection()`, so the Attempt N is re-derived onto the RIGHT per-clip
   tag. The attempt number = that clip's `SessionMedia.assignedSetIndex + 1` (`selectedClipAttemptNumber`).
6. **Caption/toggle robustness — kill the transient Sets + the regex.** Replace
   `climbAttemptEnabled`/`climbSetterEnabled` Sets with the explicit `OverlayItem.showsAttempt/attemptNumber/
   showsSetter` fields (STEP 1). The overlay's `content` stays the BASE caption (user-editable via the
   pencil); the RENDERED string is composed = base (+ " · by {setter}" if showsSetter) (+ "\nAttempt N" if
   showsAttempt) — compose in the canvas chip AND export so user text and system lines never share an
   encoding (kills the `\nAttempt \d+$` regex that corrupts user captions, and the setter toggle that wiped
   edits). Read toggle state from the model (fixes reopen/undo desync). Put the compose in a PURE helper
   (extend `KilterClimbCaption`) and UNIT-TEST it.
7. **Lifecycle + polish.** (a) `removeClip` (StudioProjectEditor.swift:62-68): `s.overlays.removeAll { $0.clipID == id }`. (b) Gate the "Show setter" Toggle behind `canShowClimbSetter` (`resolvedClimbUUID != nil`) so it's HIDDEN for freeform (StudioEditorView.swift:319-323). (c) `addClimbNameOverlay()` no-ops / uses a "Climb" placeholder when the resolved caption is empty; filter empty-content chips from the canvas to match export. (d) a11y label/value/identifier on `TextOverlayChip`.

## Constraints
Additive/migration-safe (all new `OverlayItem` fields optional/defaulted; `StudioProjectSnapshot`/undo must
carry them — they're Codable). Swift 6, 0 new warnings. The Kilter board climb-name path (resolvedClimbUUID)
must stay correct. Don't regress prompts 09–11 (per-attempt strips, edit-all-clips, deep-tap menu, the
single-clip editor). Keep changes surgical and well-commented.

## Output
- `StudioProject.swift` (OverlayItem fields), `StudioEditorViewModel.swift` (idempotent+scoped add,
  outputWindow, select repoint, explicit-field toggles), `StudioEditorView.swift` (Climb ✓ state, gated
  Show-setter, threaded currentTime), `StudioOverlayCanvas.swift` (time-gate + compose + opacity),
  `StudioOverlays.swift` (resolve window per clipID + compose), `StudioProjectEditor.swift` (removeClip
  prune), `KilterClimbCaption.swift` (pure compose helper). Unit tests in `SnappetTests` for the pure
  compose + window-resolution + idempotency-key logic.
- `decisions.md` entry; `docs/knowledge-graph/data.js` update.

## Acceptance criteria
- [ ] A climb tag shows ONLY during its clip's segment (editor preview AND export); in "Edit all clips"
      each clip has at most ONE tag and they don't all show at once.
- [ ] Tapping "Climb" repeatedly does NOT duplicate — it adds once then selects the existing tag (button
      shows a selected/✓ state).
- [ ] Selecting a different clip updates the Attempt # to THAT clip's attempt on THAT clip's tag.
- [ ] Editing the caption then toggling Attempt # on/off never corrupts the user's text; toggle state
      survives reopen/undo. "Show setter" is hidden for freeform climbs.
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green
      (incl. new compose/window/idempotency tests); existing studio + climb UITests still pass.

## Test plan
`xcodegen generate`; `xcrun simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; the studio UITest (`LiveWorkoutStudioWalkthroughTests` — flaky, retry once) + `NamedClimbTests`/`EditClimbTests`. Sim wedge: `simctl shutdown all` retry, else `erase "iPhone 17"` + run on `name=iPhone 17`. Device-only: the actual export burn-in + drag feel. Commit (changed files only) when green; message `fix(quick-session): climb-name overlay is now a per-clip property (scoped to clip · idempotent · correct attempt#)`.
