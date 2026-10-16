# Prompt: Library redesign L4a — create an activity before you've logged it

**File**: pdd/prompts/features/186-ios-library-create.md
**Created**: 2026-10-15
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData) — code lands in this repo.
**Chain**: Library redesign wireframes (`docs/ux-research/library-redesign/wireframes.html`, screen 6, §08 L4 — split into
L4a create · L4b pickers · L4c Kilter); builds on prompts 183–185
**Context**: `pdd/context/decisions.md`

## Goal

Plan before you do: save a climb you want to project, a run route, a timed protocol or a dance / other activity to
your Library, then "Log it now" when you start it.

## Approach

- `LibraryEntry` gains optional `templateData` (`LibraryTemplate`: the `SessionExercise` to log + a run's target
  distance) and `createdAt` — additive optionals (lightweight migration), in the backup row (older backups decode).
- `LibraryCreate`: entity builders (climb from `AddClimbParams`, timed from `AddTimedParams`, named run / dance /
  other) and `save` (keyed by `ActivityIdentity` at creation time). New small sheets: `NewRunRouteSheet`,
  `NewNamedActivitySheet`; reused: `AddClimbSheet`, `CreateTimedExerciseForm` (CTA "Add to Library"),
  `ExerciseEditorView` (a new lift).
- Library ＋ is a menu (Exercise · Timed protocol · Climb · Run route · Dance/other); the new activity's page is
  pushed after the sheet dismisses (stash + `onDismiss` promote).
- `LibraryCatalog.yours(created:)` adds "Not done yet" rows (New badge, distance for routes); a logged row with the
  same key — or, for a climb, the same base logged on/after the creation day — replaces it. Shown right after pinned.
- Activity page: Log it now / Add to routine / About fall back to the template; ⋯ → Delete for a never-logged one.
  Unpin / unhide never delete an entry that holds a template.

## Acceptance criteria

- [x] `LibraryCreateTests` (not-done-yet row, replaced when logged, an older log doesn't hide a new project, route
      distance, launcher + routine block from template, template round-trip) + backup round-trip with a template.
- [x] `LibraryCreateUITests`: run route → its page (not done yet) → Yours "New"; climb → its page.
- [ ] Device: create a project climb, Log it now at the gym.
