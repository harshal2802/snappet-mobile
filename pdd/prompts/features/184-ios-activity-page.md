# Prompt: Library redesign L2 — the Activity page

**File**: pdd/prompts/features/184-ios-activity-page.md
**Created**: 2026-10-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Library redesign wireframes (`docs/ux-research/library-redesign/wireframes.html`, screen 4 + screen 3's
"done" badges, §08 L2); builds on prompt 183
**Context**: `pdd/context/decisions.md`

## Goal

One page per activity that ties together its progress, its clips and its how-to — and lets you use it again.

## Approach

- `ActivityDashboardView` becomes the **Activity page**: Progress · Clips · About tabs (only the ones that apply;
  a never-logged catalog move opens on About). Progress = the P2 dashboard (its clips strip's "See all" switches
  tabs). Clips = `ActivityClipsContent` (the past-clips sheet's content, now shared with the sheet). About = a catalog
  move's `ExerciseDetailView` (how-to, guide photos, muscles, custom edit/delete — its old progress section removed),
  else `ActivityAboutView` (latest instance's details: climb type/grade/gym/wall/colour/setter/set date, a hold's
  protocol, run distances, a festival's sets) + first/last done.
- Every catalog-exercise route (`Exercise`, `ProgressRoute`, Library catalog rows) lands on the Activity page.
- Pure `ActivityLauncher`: **Log it now** clones your latest instance (identity + setup, no sets, last set count
  planned; a climb keeps name/grade/gym/wall/colour) or a blank catalog move; **Add to routine** builds a block that
  prescribes last time (sets × top reps @ top weight · the climb · the hold · the distance). Festivals and discipline
  overviews can't be launched.
- Log it now → `SuiteRouter.pendingQuickLog`; the page pops to the module root and the Gym Tracker home adds it to the
  running session (resume) or starts a Quick Session with it. Add to routine → appends + a toast (announced to
  VoiceOver).
- Explore rows get a "Done · N days" badge (lift by id; timed protocol by id or by name).

## Acceptance criteria

- [x] `ActivityLauncherTests` (climb clone, planned sets, blank catalog move, launchability, routine blocks).
- [x] `ActivityPageUITests`: tabs, About how-to, Add to routine confirmation, Log it now opens the player on the
      move, Explore "done" badge. Activity/Library/guide/walkthrough suites green.
- [ ] Device: Log it now mid-workout adds to the running session.
