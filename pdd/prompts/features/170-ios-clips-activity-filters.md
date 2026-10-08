# Prompt: Clips — filter by what the workout actually was

**File**: pdd/prompts/features/170-ios-clips-activity-filters.md
**Created**: 2026-10-07
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: phone check after #351–#359 — user: "climbs filter is not working correctly … review all the filters and make
sure they all are appropriately mapped to different types of workout and activities and apps"
**Context**: `pdd/context/decisions.md`

## Audit (before)

| Chip | Matched | Problem |
|---|---|---|
| Climbs | `post.kind == .kilter` | missed Quick Session climbs, every climbing workout imported from Apple/Google Health, hangboard |
| Gym | every workout-tracker session not festival-tagged | a catch-all: runs, yoga, dance, imported climbs, hangboard, a festival night's untagged clips |
| Festival | festival-tagged sets | a festival night's untagged clips fell under Gym |
| Sends · Reels · Videos · Photos · Favorites · Hidden | — | correct |

Posts also took the dumbbell glyph/accent for any non-board climb.

## Approach

- Pure `ClipActivity` resolves each post's ACTIVITY (`ClipFeedPost.Discipline`: climbing · strength · cardio · dance ·
  mobility · festival · other): festival set / festival night → festival; Kilter → climbing; a tagged exercise → its
  discipline (climb → climbing, strength/timed → strength — **hangboard is Strength, user's call**, run → cardio,
  dance → dance); untagged clips + reels → the session: a Health import by its workout-type label (closed set from
  `HealthKitService.label`, drift-tested), a tracked session by its most common exercise activity.
- `SessionBundle` carries `exerciseActivity` + `sessionActivity` (threaded through dedup + partition); posts carry
  `sessionActivity` for the session header.
- Filter: one `activity` (replaces Climbs/Gym/Festival). Chips: **only activities you have posts for** (user's call),
  in a fixed order, Sends right after Climbing.
- Glyph + accent per activity on posts and session headers; header names the activity ("Sat 27 Sep · Climbing ·
  Apple Watch"; Kilter keeps "Kilter · 40°"). Search matches activity names.

## Acceptance criteria

- [x] Climbing = board + Quick Session climbs + imported climbing; Strength excludes them; festival nights are Festival.
- [x] Chips only for present activities; every import label maps to an activity (drift guard).
- [x] `SnappetTests` 2380 green; `ClipsFeedUITests` (festival test rewritten to the real semantics).
- [ ] Device: the Climbing chip shows your Google Health climbs; icons/headers read right.
