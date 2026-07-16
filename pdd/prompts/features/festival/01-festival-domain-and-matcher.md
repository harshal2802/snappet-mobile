# Prompt: Festival domain + set matcher — pure keystone (festival prompt 01)

**File**: pdd/prompts/features/festival/01-festival-domain-and-matcher.md
**Created**: 2026-07-16
**Project type**: Native iOS feature (Swift, pure Foundation) — code lands in this repo.
**Chain**: `pdd/prompts/features/festival/README.md` → 01 of 06 (wireframes approved first —
`docs/ux-research/festival/wireframes.html`, frames 3 · 4 · 7)
**Source**: user ideation session 2026-07-16 (dance + video tagging for music-festival lineups)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

The pure keystone of the Festival mini-app: the **lineup domain model**, the **`.fpack` wire codec +
validator**, and the **`FestivalSetMatcher`** that auto-tags clips to artists' sets by
timestamp-overlap with stated confidence. Everything in this prompt is Foundation-only and fully
unit-tested without a simulator — the repo's pure-logic-at-a-thin-edge rule — so prompts 02–05 wire
UI and platform edges onto logic that already works. Why this matters: time-window tagging is the
insight that makes the whole feature cheap (a set is an interval; every clip has a timestamp), and
its edge cases (adjacent sets, two stages live, clips between sets) are exactly what unit tests are
for.

## Context the implementer needs

- **The shape is decided** (README + decisions.md 2026-07-16): Festival mini-app owns the domain;
  capture rides dance-discipline `WorkoutSession`s. This prompt adds NO UI, NO SwiftData, NO module
  registration — those are prompt 02.
- **`.fpack`** = gzipped JSON, hosted at `https://harshal2802.github.io/Snappet/music-festivals/`
  (web-app repo PR comes with prompt 02). Wire form: festival (id, name, location, dates) → days →
  stages → sets (artist, start, end). Content identity should follow the Kilter create-a-climb
  precedent: UUIDv5 over normalized content, so the same set in a re-downloaded or friend-shared
  pack has the same id.
- **Deflate + base64url and the QR size cap** already exist in
  `Features/WorkoutTracker/SharedRoutine.swift` — do not duplicate them; if small shared helpers
  need extracting, extract, don't copy. (Full QR share is prompt 05; this prompt only keeps the
  types friendly to that codec: compact, Codable, no reference cycles.)
- **Matcher inputs stay abstract.** The matcher must not know about `PHAsset`/`FeedMedia` — it takes
  value inputs (clip id + capture date, optionally a duration) and the day's sets, and returns
  assignments. Prompt 03 adapts real media into those inputs (the #283 session-media-window
  pattern).
- Precedents to read before writing: `Features/Kilter/KilterCatalogValidator.swift` (validator
  posture), `KilterClimbIdentity.swift` (UUIDv5 content identity), `SharedRoutine.swift` (wire
  codec + versioning + tests), `Features/Feed/ClipFeedFilter.swift` (pure-struct style + doc-comment
  voice).

## Approach

New folder `ios/App/Snappet/Features/Festival/`, all pure Foundation:

- **`FestivalPack.swift`** — Codable wire types: `FestivalPack` (formatVersion, festival meta,
  `days: [FestivalDay]`), `FestivalDay` (date, `stages: [FestivalStage]`), `FestivalStage` (name,
  `sets: [FestivalSet]`), `FestivalSet` (id, artist, start, end). Gzip ⇄ JSON codec
  (`compression_stream`, ZLIB, as `SharedRoutine` does) with a version segment in the wire form from
  day one. Dates encode as ISO-8601 **with the festival's UTC offset** captured in the pack, so a
  pack built in Europe tags clips shot in Europe regardless of the phone's later time zone.
- **`FestivalPackValidator.swift`** — structural validation on install (Kilter posture): version
  supported, non-empty days/stages, every set has non-empty artist and `start < end`, sets within a
  stage don't overlap *each other* (different stages may), dates inside the festival window. Returns
  typed errors the install UI (prompt 02) can show verbatim.
- **`FestivalSetMatcher.swift`** — the keystone. Input: `[ClipStamp]` (id, captureDate, optional
  duration) + the pack (or one day). Output: per clip an `Assignment` — `set` + `confidence` +
  machine-readable `reason` (an enum: `.withinSet`, `.betweenSets(before:after:)`,
  `.multipleStagesLive([FestivalSet])`, `.outsideSchedule`). Confidence semantics (test these
  exactly): 1 candidate whose window contains the timestamp → high; timestamp in a gap → nearest
  set decays with distance from the window edge; ≥2 stages live → split by proximity to set
  midpoints, capped below the "needs you" threshold so the review UI floats it. Expose the
  threshold as a constant the UI reads — one source of truth for "auto vs ask". A session hint
  (the user pressed "I'm here" on a set — prompt 02's data) is an *optional* input that boosts,
  never overrides, the time evidence.
- **`FestivalPlan.swift`** — starred-set value logic needed by everything downstream: a `Set<UUID>`
  of starred ids + pure helpers: `clashes(in:)` (starred sets that overlap, with the overlap
  interval — wireframe frame 4's "⚠︎ clash"), `reminderDates(lead:)` (what prompt 04 hands to
  `UNUserNotificationCenter`), `gaps(in:)` (empty stretches the recommender fills). Kept here
  because clash/gap math is interval math the matcher already owns the vocabulary for.

Tests in `SnappetTests/Festival…Tests.swift` (XCTest, no simulator): pack codec round-trip +
tampered/oversized/unversioned rejection; validator accept/reject table; matcher confidence table
(mid-set, straddling sets, gap, two stages, outside day, DST/timezone cases); plan clash/gap/
reminder math including midnight-crossing sets (a 01:00 set belongs to the previous festival day —
model day boundaries explicitly, e.g. a day runs until ~06:00, and test it).

## Output

- `ios/App/Snappet/Features/Festival/FestivalPack.swift`
- `ios/App/Snappet/Features/Festival/FestivalPackValidator.swift`
- `ios/App/Snappet/Features/Festival/FestivalSetMatcher.swift`
- `ios/App/Snappet/Features/Festival/FestivalPlan.swift`
- `ios/App/SnappetTests/` — the four matching test files, with a small fixture pack builder
  (Glastonbury-shaped: 2 days × 3 stages, sets that exercise every reason case)
- `pdd/context/decisions.md` — entry for any non-obvious call made while implementing (day-boundary
  rule, confidence thresholds, id normalization)
- `docs/knowledge-graph/data.js` — NOT this prompt (no user-visible surface yet; prompt 02 adds the
  module node and wires it)

## Acceptance criteria

- [ ] All four source files import Foundation only — no SwiftUI/SwiftData/UIKit/Photos/HealthKit.
- [ ] `xcodebuild test` unit suite passes; new tests cover every `Assignment.reason` case and the
      midnight/DST/timezone table.
- [ ] A pack that round-trips codec → validator → matcher produces identical set ids across two
      decodes (UUIDv5 content identity).
- [ ] Matcher never returns an assignment above the auto threshold when ≥2 stages are live at the
      clip's timestamp.
- [ ] App target type-checks against the iOS 18 SDK (Swift 6, 0 warnings); no Xcode project changes
      beyond the source glob picking up the new folder.
- [ ] `decisions.md` updated if a non-obvious choice was made.

## Constraints

- On-device only; no backend/network/accounts (the hosted GET is prompt 02's edge, not this one's).
- Do not extend `WorkoutDiscipline`, `SetKind`, or any Clips/Feed type in this prompt — integration
  points come later; this prompt must merge with zero behavior change to shipped surfaces.
- UI-suite policy: pure-logic PR → skip the ~14-min XCUITest sweep; unit suite only.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild test -scheme Snappet -destination 'platform=iOS
   Simulator,name=iPhone 17 Pro' -only-testing:SnappetTests` (unit bundle only — pure logic).
2. Read the confidence table test as documentation: it should read like the wireframe frame 7
   captions ("between stages → 62%, two sets live → 58%").
