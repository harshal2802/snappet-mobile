# Prompt: Filter Kilter climbs by what you've climbed (prompt 208)

**File**: pdd/prompts/features/kilter-connect/208-ios-kilter-ascent-filters.md
**Created**: 2026-10-28
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframe (approved 2026-10-28)**: `docs/ux-research/kilter-ascent-filters/wireframes.html` / `.png`

## Goal

User: "is there a way to filter the climbs I have already sent and things like that? Similar filter in plan a
session?" Browse offered only All / Saved / Mine (= authored), rows showed no sent marker, and Plan had a single
"Prefer climbs I haven't sent" switch.

## Approach (user's picks: "I like your suggestions")

- Browse: one-tap chips under the board/angle/grade row — All · Not tried · Projects N · Sent N — plus the same
  choice as "My ascents" in the Filters sheet (Q1: both). Projects / Sent are lists of the climber's own climbs
  (most recently logged first, search honoured, like Saved); Not tried narrows the catalog query
  (`KilterFilter.excludeUUIDs` → `c.uuid NOT IN (…)`). Picking one clears Saved / Mine and vice versa.
- Every row: "✓ Sent" / "✓ Sent at 50°" / "◐ N tries" badge and "you: …" in the subtitle.
- Sent = sent at ANY angle (Q2); the badge names the angle when it wasn't this one. Project = tried, never sent.
- Plan a session: the switch becomes "Climbs to pick" — New climbs only / Include sent / Projects first.
  "Projects first" puts open projects near the working grade (−1…+3 buckets), most recently tried first, into the
  project slots, then fills with new climbs. Defaults (Q3): Balanced / Flash / Power → New only; Project →
  Projects first; Volume / Recovery → Include sent. The old switch's saved value carries over.
- Pure core `KilterAscentIndex` / `KilterAscentFilter` / `KilterPlanClimbChoice` (`KilterAscents.swift`); no
  SwiftData change (the stored plan keeps its `optionsPreferUnsent` bool, fed from the choice).

## Acceptance

- [x] `KilterAscentsTests` + the "Not tried" exclusion in `KilterCatalogStoreTests` green; full unit suite green;
      Kilter UI slice green.
- [ ] Device: browse chips with the real log (8 sent, 4 projects on 2026-10-26); Plan "Projects first" picks
      the V8 projects at ~V6 working grade.
