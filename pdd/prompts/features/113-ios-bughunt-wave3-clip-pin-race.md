# Prompt: Bug-hunt Wave 3 — page-recorded clip pins to the page it was recorded on

**File**: pdd/prompts/features/113-ios-bughunt-wave3-clip-pin-race.md
**Created**: 2026-07-08
**Project type**: Native iOS fix (Swift) — code lands in this repo.
**Chain**: Wave 3 of the 2026-07-07 whole-repo bug hunt (issues #271–#274); Wave 1 was
prompt 111 (#271, merged as #275), Wave 2 was prompt 112 (#272, merged as #276).
**Source**: proactive bug hunt (GitHub issue #273)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make the Quick Session pager's page-level "Record a clip" attach the recording to the exercise
whose page it was **recorded on**, not whatever page is current when the async Photos save
completes (F4).

## Context the implementer needs

- Every exercise page in `FreeformPlayerView` renders a `RecordClipButton` bound to ONE shared
  `@State pageClips: [RecordedClip]`; the attach fires from
  `.onChange(of: pageClips.count)` and reads the **current** `page`. The append is asynchronous
  (`MediaLibraryService.saveRecording` must return the saved asset id first), so the user can
  swipe during the save window (sub-second to seconds for long clips):
  - swipe to exercise B → the clip pins `.manual` to **B** — sticky, the auto-reconciler never
    fixes a `.manual` row (wrong pin);
  - swipe to the overview/add page → the `else` branch `pageClips.removeAll()` **discards** the
    queued clip entirely — saved to Photos but never filed to the session (dropped pin).
- The FOCUS covers (`TimedSetCover` / `TimedAttemptCover`) are NOT affected: they own their
  clips per-cover and attach at commit with an explicit target.

## Approach

- Capture the owner at **present time, structurally**: key the queue by exercise —
  `pageClips: [UUID: [RecordedClip]]` — and give each page's `RecordClipButton` a binding
  scoped to its own exercise id. `RecordedClip` / `RecordClipButton` stay unchanged.
- Route through a pure seam, `QuickSessionPager.pageClipAttachPlan(queued:liveExerciseIDs:)`
  (the pager's existing pure home): each queued group pins to its record-time owner; an owner
  deleted during the save routes to `exerciseID: nil`; groups/clips order by capture time. The
  current page is **not an input** — the race is gone by construction.
- `attachRecordedClips` accepts `UUID?`: `nil` files the clip to the session's sticky General
  bucket (`.general`, the reassign-to-nil convention) and is insert-only — an existing row's
  placement stands; a recorded clip is never dropped.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/QuickSessionPager.swift` — `PageClipGroup` +
  `pageClipAttachPlan`
- `ios/App/Snappet/Features/WorkoutTracker/FreeformPlayerView.swift` — keyed `pageClips`,
  per-page binding, plan-driven `.onChange(of: pageClips)`, `attachRecordedClips(… UUID? …)`
- `ios/App/SnappetTests/QuickSessionPagerTests.swift` — routing contract
- `pdd/context/decisions.md` + `docs/knowledge-graph/data.js` node notes

## Acceptance criteria

- [ ] Routing contract pinned: a clip attaches to the exercise it was queued under regardless of
      any current page; a deleted owner routes to session-unassigned (never dropped); multi-owner
      batches attach in recording order; clearing the queue re-fires an empty no-op plan.
- [ ] The overview/add-page discard branch is gone (the handler no longer consults `page`).
- [ ] App type-checks (Swift 6, 0 new warnings); full `SnappetTests` unit suite green.
- [ ] `decisions.md` + knowledge-graph node descriptions updated.

## Constraints

- No model change (`SessionMedia` untouched); `RecordedClip` wire shape unchanged so the FOCUS
  covers are untouched. `HighlightEngine` untouched.
- UI-suite policy: logic/wiring-only change, no visual behavior change → gate on the unit suite
  + build; no new XCUITests.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — full unit suite incl. the new
   `pageClipAttachPlan` contract in `QuickSessionPagerTests`.
2. Device check (owed — the Simulator has no camera): record on exercise A's page, swipe to B
   (and to the overview) during the save; the clip must appear on A's media shelf.
