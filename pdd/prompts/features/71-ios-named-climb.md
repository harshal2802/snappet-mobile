# Prompt: Free-flow climb — give a climbing exercise a custom climb name

**File**: pdd/prompts/features/71-ios-named-climb.md
**Created**: 2026-06-16
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Workout-with-timer initiative — **PR 5 of 6** (the "named free-flow climb session" slice; builds on the freeform climb-attempt logging of PR 4). Ideated + architected 2026-06-15 on this branch.
**Source**: In-repo ideation + architecture plan — Gym Tracker "Workout with timer" (timed sets · repeat-set loop · free-flow climb sessions · tracking-type search), 2026-06-15.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Let a free-flow **climbing** exercise carry a **custom climb name** (e.g. "Cave Project", "Blue V4")
instead of the fixed "Climbing", so per-attempt logging groups under the named climb. In the freeform
player today, the add-exercise menu's "Climbing" button appends a climb exercise with the generic
`displayName` "Climbing", which the section header renders. This PR makes tapping "Climbing" first ask
for a name — a small "Name this climb" alert with a text field — and stores the typed name as the
exercise's `displayName`, which the existing `resolver.name(for:override:)` already surfaces as the
header. A blank/whitespace entry falls back to "Climbing", so naming is optional and the prior behavior
is the default. Every existing climb behavior — attempt logging, the PR-4 per-attempt timer, summaries,
Repeat set — is untouched; this only changes the name the attempts group under.

**Out of scope (deferred, device-pending):** *photo attachment to a free-flow climb* (e.g. a reference
shot of the boulder/route). That needs PHPicker/Photos, which is **device-only and unverifiable in this
CI-only environment** — it can't be honestly type-checked into "works", so it is split out as a separate
follow-up to be done where a device run is available. This PR ships **only** the named-climb part.

## Context the implementer needs

- **The header already reads an override.** `ExerciseResolver.name(for:override:)`
  (`WorkoutProgress.swift`) returns `override` when it's non-empty, else the catalog name, else a
  de-slugged id. The freeform section header already calls
  `resolver.name(for: ex.exerciseId, override: ex.displayName)`. So a custom name only has to land in
  `SessionExercise.displayName` and it renders — **no model change** (`displayName: String?` already
  exists and persists in the `Codable` blob).
- **`addExercise(kind:name:)` already stores the name.** `FreeformPlayerView.addExercise(kind:name:)`
  appends a `SessionExercise(... displayName: name, kindRaw: kind.rawValue)` and persists +
  pushes the Live Activity. The only change is **what name is passed**: the menu's "Climbing" button
  currently passes the literal `"Climbing"`; it should instead open a name prompt and pass the typed
  name (trimmed, fallback "Climbing").
- **Pure trim/fallback in `SetMeasure`.** Keep the "trim, empty → Climbing" rule as one tested
  definition next to the other pure helpers (`summary`/`splitDuration`/`duplicate`) rather than inline
  in the view, so it's unit-tested without a simulator and reused if a rename surface is added later.
- **UI-test lessons (PR 2/3/4).** Do **not** put `.accessibilityIdentifier` on a composite/custom view —
  on iOS 26 it collapses the a11y subtree and hides children. Give **leaf** controls ids only: the alert
  text field gets `freeform.climbName`. For an alert, query via `app.alerts.textFields` /
  `app.alerts.buttons["Add"]`. Query set rows **type-agnostically**
  (`app.descendants(matching: .any).matching(identifier: "freeform.setRow")`, NOT `app.cells`) and
  assert **distinctive values** (the header "Cave Project"; the attempt's grade "V3").

## Approach

Pick the cleaner of (a) name-prompt-on-tap vs (b) add-then-rename. **Chosen: (a)** — tapping "Climbing"
presents a small `.alert("Name this climb", …)` with a `TextField` + Add/Cancel, then adds with the
typed name. It puts the naming exactly where the intent is, keeps the per-exercise header `Menu` simple
(still just "Remove exercise"), and matches the repo's existing alert-with-TextField pattern
(`StudioEditorView`'s "Add text" / "Rename").

1. **`SetMeasure.swift`** — add a pure `climbName(_ text:) -> String`: trim
   `.whitespacesAndNewlines`; empty → `"Climbing"`, else the trimmed name. One tested definition of the
   trim/fallback rule.
2. **`FreeformPlayerView.swift`**:
   - Add `@State private var namingClimb = false` and `@State private var climbNameDraft = ""`.
   - The add-menu "Climbing" button becomes `{ climbNameDraft = ""; namingClimb = true }` (open the
     prompt) instead of `addExercise(kind: .climbAttempt, name: "Climbing")`.
   - Add `.alert("Name this climb", isPresented: $namingClimb)` with a leaf
     `TextField(...).accessibilityIdentifier("freeform.climbName")`, an "Add" button that calls
     `addExercise(kind: .climbAttempt, name: SetMeasure.climbName(climbNameDraft))`, and a Cancel.
   - `addExercise(kind:name:)`, the header, attempt logging, the PR-4 timer, Repeat set, summaries are
     **unchanged**.
3. **Knowledge graph**: update the `wt-freeform-player` desc to mention naming a free-flow climb (custom
   `displayName` so attempts group under the named climb; blank → "Climbing"). No new node/edge needed —
   the climb-logging surface already exists.

## Output

- Changed: `ios/App/Snappet/Features/WorkoutTracker/SetMeasure.swift` (pure `climbName` trim/fallback),
  `ios/App/Snappet/Features/WorkoutTracker/FreeformPlayerView.swift` (name prompt on "Climbing"; pass the
  typed name to `addExercise`).
- Tests: extend `ios/App/SnappetTests/SetMeasureTests.swift` (`climbName` trims; blank/whitespace →
  "Climbing"); new `ios/App/SnappetUITests/NamedClimbTests.swift` (Quick Start → Climbing → name
  "Cave Project" → Add → assert the header → Add attempt grade "V3" → Add → assert a `freeform.setRow`
  with the distinctive grade under the named climb).
- `docs/knowledge-graph/data.js`: `wt-freeform-player` desc gains the named-climb sentence.
- `pdd/context/decisions.md`: a 2026-06-16 entry — named free-flow climb via the existing `displayName`
  (no model change), prompt-on-tap, pure `SetMeasure.climbName` fallback; **photo attachment deferred,
  device-pending**.

## Acceptance criteria

- [ ] In the freeform player, tapping "Climbing" presents a "Name this climb" prompt; entering
      "Cave Project" + Add creates a climb exercise whose section header reads "Cave Project" and groups
      its attempts.
- [ ] A blank/whitespace name (or Cancel-then-rename equivalent) falls back to the generic "Climbing" —
      naming is optional and the prior behavior is the default.
- [ ] The custom name persists (stored on `SessionExercise.displayName`, rendered via
      `resolver.name(for:override:)`); no `SessionExercise`/`SetLog`/`WorkoutModels` change.
- [ ] Attempt logging, the PR-4 per-attempt timer, summaries, and Repeat set are all unchanged.
- [ ] The trim/fallback rule is covered in `SetMeasureTests` without a simulator (trims; blank → Climbing).
- [ ] A UI test names a climb and asserts the header static text plus a `freeform.setRow` logged under it.
- [ ] Photo attachment to a free-flow climb is **explicitly deferred** (device-pending) — not implemented
      here — and noted in this prompt + `decisions.md`.
- [ ] The app type-checks against the iOS SDK (Swift 6, 0 warnings); `HighlightEngine`, the watch, the
      widget, and the guided `WorkoutPlayerView` are untouched.
- [ ] `docs/knowledge-graph/data.js` and `pdd/context/decisions.md` updated in this change.

## Constraints

- On-device only; no backend / network / accounts.
- **Reuse, don't re-implement.** Use the existing `displayName` field + `resolver.name(for:override:)`
  and the existing `addExercise(kind:name:)` path — do **not** add a model field or a second add site.
- **Do not** implement photo attachment in this PR (PHPicker/Photos is device-only and unverifiable in
  CI) — keep it as a deferred follow-up.
- Do not touch the device-verified guided `WorkoutPlayerView`, the watch/widget targets,
  `HighlightEngine`, or release workflows.
- Honest verification: a clean type-check ≠ a device run. The orchestrator runs the simulator suite; this
  change ships `xcodegen generate`-verified plus the pure `SetMeasureTests`.

## Test plan

1. `cd ios/App && xcodegen generate`, then
   `xcodebuild test -scheme Snappet -only-testing:SnappetTests/SetMeasureTests
   -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (orchestrator); plus
   `-only-testing:SnappetUITests/NamedClimbTests` for the named-climb path.
2. By eye on the sim: Quick Start → Add exercise → Climbing → type "Cave Project" → Add → the section
   header reads "Cave Project"; Add attempt grade "V3" → Add → the attempt logs under "Cave Project";
   confirm leaving the name blank falls back to "Climbing".
