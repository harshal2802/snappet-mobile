# Prompt: Add-a-climb — re-log a previous climb, setter, and photos

**File**: pdd/prompts/features/81-ios-add-climb-previous-setter-photos.md
**Created**: 2026-06-18
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: standalone follow-up to the Quick Session climb-first redesign (PR #175 / commit `42dfd73`).
**Source**: user request (2026-06-18); approved wireframe at
`docs/ux-research/quick-session-redesign/wireframes/add-climb-previous-climbs.html`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make the **"Add a climb"** sheet (`AddClimbSheet`) a complete capture surface by adding the three pieces
the redesign left out: (1) a **"Log a previous climb"** picker as the literal first section — above Type —
that surfaces the user's distinct past climbs (searchable + filterable, each row with a photo preview) and,
on selection, **prefills the new-climb form** so re-logging a familiar climb is two taps; (2) an optional
**Setter** field (its own section); and (3) an optional **Photos** attach control (photos only) that reuses
the shipped `MediaPicker`/`SessionMedia` stack. Re-logging creates a **brand-new** climb seeded from the old
one — never an edit of history. The constrained discrete grade picker, per-discipline scale memory, the
"Type drives everything" rule, the exactly-one-climb commit guard, and the leaf-only a11y discipline are all
preserved.

## Context the implementer needs

`AddClimbSheet` (`ios/App/Snappet/Features/WorkoutTracker/AddClimbSheet.swift`) is a SwiftUI `Form` in a
`NavigationStack`, presented from `FreeformPlayerView` two ways — `.sheet(isPresented: $addingClimb)`
(add) and `.sheet(item: $editingClimb)` (edit, `initial != nil`). The sheet **does not persist**: it hands
back an `AddClimbParams` via `onAdd(params, logFirstAttempt)`; `FreeformPlayerView.addClimbFromSheet` /
`updateClimb` own the `SessionExercise` (kind `.climbAttempt`, `exerciseId "adhoc-climbAttempt"`).

Key facts that shape the build:
- **No "previous climbs" history exists today.** Today's recents are attribute-level only (grades per
  scale, gyms, per-gym walls in `UserDefaults`). A real previous-climbs list must be **derived** by
  flattening `kind == .climbAttempt` exercises out of the `history: [WorkoutSession]` already passed into
  `FreeformPlayerView` **plus** the live `session.exercises`. Quick Session climbs have **no content
  identity** (the `SessionExercise.id` is per-instance; the UUIDv5 `KilterClimbIdentity` is a *different*
  feature) — so dedup on a derived normalized key.
- **Photos for a not-yet-created climb.** A new climb's `SessionExercise.id` doesn't exist until
  `addClimbFromSheet` mints it. So the sheet collects picked **localIdentifiers into `@State`** and returns
  them on `AddClimbParams`; `addClimbFromSheet` inserts the `SessionMedia` rows *after* it creates the
  climb (`assignedExerciseID: climb.id, assignedSetIndex: nil, source: .manual`). `SessionMedia` already
  has the fields — **no schema change** for media. Reuse `SessionMediaService.candidates(forIdentifiers:…)`
  for the offset/kind mapping (the `SetMediaStrip` precedent).
- **Privacy posture (must hold):** never copy bytes — store only the PHAsset `localIdentifier`; on-device
  only (`isNetworkAccessAllowed = false`); gate on `.authorized` via `SessionMediaService.requestAccess()`
  (`AppModel` exposes `sessionMedia` + `photoAccess` on the environment). The simulator has no Photos, so
  thumbnails render placeholders and the attach affordance stays reachable for XCUITests.

## Approach

- **Pure helper first** (no SwiftUI/SwiftData; unit-tested — the repo's pure-logic-at-a-thin-edge rule):
  a new `PreviousClimb.swift` with a `PreviousClimb` value (`id` = normalized identity key, `params:
  AddClimbParams`, `lastLoggedAt`, `attemptCount`, `bestStatus: KilterAscentStatus?`,
  `photoLocalIdentifier: String?`, `photoCount: Int`) and two pure statics:
  - `catalog(from entries: [(exercise: SessionExercise, loggedAt: Date)], photoLookup:, cap:)` — filter to
    `.climbAttempt`, sort most-recent-first with a deterministic index tiebreak, dedup by identity key
    (most-recent wins), cap (default 12).
  - `filtered(_:query:scope:gym:sentOnly:)` — `scope` ∈ all/boulder/routes, optional `gym` (case-insensitive),
    `sentOnly` (best status `.isSend`), and a `query` matching name/grade/gym/wall/setter.
- **Model:** add additive optional `setter: String?` to `SessionExercise` (next to `gym`/`wall`/`climbColorRaw`
  — SwiftData lightweight migration, the established climb-metadata convention). Add `setter: String?` and
  `photoLocalIdentifiers: [String]` to `AddClimbParams` (+ `init(from:)`); make `AddClimbParams` `Equatable`.
- **`MediaPicker`:** add a `filter: PHPickerFilter` parameter (default unchanged `.any(of: [.videos,
  .images])`) so the climb attach control can request `.images` only — every existing caller is untouched.
- **`AddClimbSheet` UI** (all new interactive leaves carry their own `accessibilityIdentifier`; the leaf-only
  rule):
  - **Previous-climb section (ADD mode only, omitted when empty):** the literal first `Section`, a
    `DisclosureGroup` "Log a previous climb" that expands to a search field + a filter chip rail
    (`All · Boulder · Routes · This gym · Sent` — "This gym" only when a gym is in scope) + the filtered
    rows (photo-preview thumb or type glyph, colour dot, name, gym·wall·when, grade pill) + an "Add a new
    climb instead" row. Selecting a row calls the existing `seed(from:)` to prefill every field, collapses,
    and mirrors the choice on `addClimb.previousValue`. "Add a new climb instead" resets to blank defaults.
  - **Setter section:** its own `Section("Setter (optional)")` after Name, a `TextField` (id `addClimb.setter`).
  - **Photos section (ADD mode only):** `Section("Photos (optional)")` after More — a thumbnail strip of the
    picked photos (each removable) + a "paperclip" attach button presenting `MediaPicker(filter: .images)`;
    gate access like `SetMediaStrip.ensureAccessThenPick`.
- **`FreeformPlayerView` wiring:** build a cached `previousClimbs: [PreviousClimb]` (flatten live + history,
  resolve a photo map from a `FetchDescriptor<SessionMedia>` over photos grouped by `assignedExerciseID`),
  recomputed on appear / `session.exercises` change / sheet-open (the `climbStats`/`prefills` cache
  precedent — never on the ~1 Hz body re-render); pass it into the add-mode `AddClimbSheet`. Copy `setter`
  in `addClimbFromSheet` + `updateClimb`; insert climb-level `SessionMedia` from
  `params.photoLocalIdentifiers` via `app.sessionMedia.candidates(forIdentifiers:…)` in `addClimbFromSheet`.

## Output

- `ios/App/Snappet/Features/WorkoutTracker/PreviousClimb.swift` — new pure value + `catalog`/`filtered`.
- `ios/App/Snappet/Features/WorkoutTracker/AddClimbSheet.swift` — previous-climb section, Setter, Photos;
  `setter`/`photoLocalIdentifiers` on `AddClimbParams`; a `localIdentifier`→thumbnail helper view.
- `ios/App/Snappet/Features/WorkoutTracker/WorkoutModels.swift` — `setter: String?` on `SessionExercise`.
- `ios/App/Snappet/Services/MediaPicker.swift` — additive `filter` parameter.
- `ios/App/Snappet/Features/WorkoutTracker/FreeformPlayerView.swift` — `previousClimbs` cache + pass-in;
  `setter` copy + `SessionMedia` insert.
- `ios/App/SnappetTests/PreviousClimbTests.swift` — catalog dedup/order/cap + filter cases.
- `ios/App/SnappetUITests/…` — extend the climb add flow (previous-climb disclosure reachable, Setter +
  Photos affordances present, re-log prefills the form).
- `docs/knowledge-graph/data.js` — update the `AddClimbSheet` node + a `history → previous-climb` edge.
- `pdd/context/decisions.md` — the derived-history dedup choice + the "re-log = new climb" rule + photos-only.

## Acceptance criteria

- [ ] In add mode with prior climbs, "Log a previous climb" is the first section, above Type; expanding it
      shows search + the `All/Boulder/Routes/This gym/Sent` filters + rows with photo previews.
- [ ] Selecting a previous climb prefills Type · Grade · Colour · Name · Setter · gym · wall and creates a
      **new** `SessionExercise` (fresh `id`) on commit — history is never mutated.
- [ ] The previous-climb section + Photos section are **absent in edit mode**; Setter shows in both.
- [ ] Setter persists on the climb (`SessionExercise.setter`) and round-trips through add → edit.
- [ ] Attaching photos (device) files climb-level `SessionMedia` (`assignedExerciseID == climb.id`,
      `assignedSetIndex == nil`, `source == .manual`, `kind == .photo`); none are byte-copied.
- [ ] Grade entry stays the constrained discrete rung picker; per-discipline scale memory unchanged.
- [ ] `PreviousClimb` is pure and ships with passing `XCTest` (dedup, most-recent-wins, cap, filters).
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings); no platform imports added to
      `HighlightEngine`.
- [ ] `decisions.md` + `docs/knowledge-graph/data.js` updated in the same change.

## Constraints

- On-device only; no backend/network/accounts. Additive SwiftData migration only (`setter` optional; no
  `SnappetSchema.models` change; `SessionMedia` unchanged).
- The sheet stays a pure capture surface — it does not query SwiftData or persist; `FreeformPlayerView` owns
  persistence and the photo map.
- Re-logging copies the climb's **identity only**, never its old photos/attempts.
- State verification honestly: type-check ≠ device run for the Photos attach/preview path.

## Test plan

1. `xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` — the new
   `PreviousClimbTests` + the extended freeform UITests (build-for-testing must stay green).
2. On device (MrRobot): attach 2 photos to a new climb, finish, confirm they appear on the climb in the
   session detail; re-log a previous climb and confirm a second distinct card (not a mutated original).
