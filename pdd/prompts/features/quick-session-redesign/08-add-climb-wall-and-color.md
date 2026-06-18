# Prompt: Add-a-climb — wall name (gym→wall suggestions) + climb colour

**File**: pdd/prompts/features/quick-session-redesign/08-add-climb-wall-and-color.md
**Created**: 2026-06-18
**Chain**: follows the Quick Session redesign (Phases 1–7); a user-requested iteration on `AddClimbSheet`.
**Context**: `pdd/context/*`. Source: user request.

## Goal

Two refinements to the **Add a climb** sheet, from on-device use:
1. **Wall name** that behaves like gym/location, but **scoped to the gym**: a gym has many walls, so once a
   gym is selected, the walls previously logged *at that gym* surface as one-tap suggestion chips (and a
   newly-typed wall becomes a future suggestion for that gym). Mirrors the existing recent-gym rail, but
   keyed per gym.
2. **Climb colour** (the gym's hold/tape colour) selectable **next to the Grade** option, shown as a
   swatch on the climb card.

## Context the implementer needs
- `AddClimbSheet.swift` already has: a discrete grade picker, recent-grade chips (per scale), a
  "More · gym" disclosure with a recent-gym rail (`freeform.recentGyms` in `UserDefaults`), and the
  per-type scale-stick. It hands back an `AddClimbParams` via `onAdd`.
- `FreeformPlayerView.addClimbFromSheet(_:logFirstAttempt:)` builds the `.climbAttempt` `SessionExercise`
  from the params; `climbHeader`/`gradePill` render the card (gym is captured but NOT shown today).
- `SessionExercise` carries additive-optional climb fields (`climbTypeRaw/climbGradeLabel/
  climbGradeScaleRaw/gym`). `Color(hex: UInt32)` exists in `SnappetColor.swift`.

## Approach (additive + migration-safe; match the existing recents idiom)
1. **`ClimbColor`** (pure, in `ClimbGrade.swift` — Foundation only, unit-tested): a curated palette
   `enum ClimbColor: String, Codable, CaseIterable, Sendable` (red/orange/yellow/green/blue/purple/pink/
   white/black/teal/gray/brown) with `label` and `hexValue: UInt32` (for `Color(hex:)`), and a
   `needsRing` flag for white (so the swatch reads on a light card).
2. **`SessionExercise`** additive optionals: `var wall: String?`, `var climbColorRaw: String?` +
   computed `var climbColor: ClimbColor?`.
3. **`AddClimbParams`** gains `wall: String?` and `color: ClimbColor?`.
4. **`AddClimbSheet`**:
   - **Colour** row inside the Grade section (right by the grade), a horizontal swatch picker: each
     `ClimbColor` as a tappable circle (selected = ring/check), plus a "None" clear option. ids
     `addClimb.color.<name>` + a queryable `addClimb.colorValue`.
   - **Wall** field in the "More" disclosure (rename it "More · gym · wall"), under Gym: a `TextField`
     (`addClimb.wall`) + a wall chip-rail scoped to the **current gym** (`addClimb.recentWall.<wall>`).
     Reload the wall recents whenever the gym changes (`.onChange(of: gym)` and when a recent-gym chip is
     tapped). Persist a `[gym: [wall]]` map in `UserDefaults` (key `freeform.gymWalls`, JSON), most-recent
     -first, deduped case-insensitively, capped ~6 per gym. No wall suggestions until a gym is set.
   - On commit: remember the gym (existing) AND `rememberWall(wall, forGym: gym)`.
5. **`FreeformPlayerView`**: `addClimbFromSheet` sets `climb.wall` + `climb.climbColorRaw`. `climbHeader`
   shows a small **colour swatch** next to `gradePill` (`freeform.colorSwatch`, hidden when no colour) and
   a **location caption** "📍 gym · wall" (whichever are set). Inherit the wall too: extend the inherited
   default so the next sheet's gym is the last gym (existing) — wall stays suggestion-only.

## Output
- `ClimbGrade.swift` (+`ClimbColor`), `WorkoutModels.swift` (fields), `AddClimbSheet.swift` (colour +
  wall + gym→wall store), `FreeformPlayerView.swift` (build + card render).
- `ClimbGradeTests.swift` (ClimbColor: allCases, hex, label). A UITest step (NamedClimbTests) that picks a
  colour + types a wall and asserts they show on the card / persist as suggestions.
- `decisions.md` entry; `docs/knowledge-graph/data.js` note on AddClimbSheet (wall+colour).

## Acceptance criteria
- [ ] Selecting a gym surfaces that gym's previously-used walls as one-tap chips; a new wall typed for a
      gym becomes a future suggestion for THAT gym (not others).
- [ ] A colour can be picked next to Grade (and cleared); it shows as a swatch on the climb card.
- [ ] All fields are optional + migration-safe (no new @Model, no non-optional stored field).
- [ ] `xcodegen generate` + `build-for-testing` clean (Swift 6, 0 new warnings); full `SnappetTests` green.
- [ ] `NamedClimbTests` passes with the colour/wall additions.

## Test plan
`xcodegen generate`; `simctl shutdown all`; `build-for-testing`; `test-without-building -only-testing:SnappetTests`; `-only-testing:SnappetUITests/NamedClimbTests`. Commit (changed files only) when green; message `feat(quick-session): Add-a-climb wall name (gym→wall suggestions) + climb colour`.
