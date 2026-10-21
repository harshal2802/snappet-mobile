# Prompt: Clips by Sessions · Activities · Exercises

**File**: pdd/prompts/features/197-ios-clips-feed-levels.md
**Created**: 2026-10-20
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips redesign part 2 of 2 — wireframes `docs/ux-research/clips-feed-levels/wireframes.html` (screens
1–3); stacked on 196 (#388)
**Context**: `pdd/context/decisions.md`

## Goal

User (2026-10-19): "give options to show feed on exercise or individual activity level or session level with each
activity tagged properly". Picks: Activities by default, the last pick remembered; the Exercises album this phase.

## Approach

- A segmented **Sessions · Activities · Exercises** under the title (`@AppStorage("clips.level")`, reset under UI
  tests). Filters and search run on the activity posts FIRST, then the level transforms them, so the three always
  agree.
- Pure `ClipFeedLevels`:
  - `sessions(_:)` — a session's activity posts → ONE post (`session@<id>`, so it keeps its own caption):
    - every clip in filming order, labelled "Bench Press · Set 2";
    - `activityChips` ("Bench Press · 3", tap → its first clip);
    - the stats line "5 sets · 2 exercises · ▲ 2 PRs" (`prCount`) and the subtitle "Thu 16 Oct · 52 min";
    - reels keep their own posts.
  - `albums(_:)` — one `ClipFeedAlbum` per activity with an identity (a logged exercise's `ActivityKey`, a board
    climb's `kilter/<uuid>`), sessions oldest → newest, newest activity first.
  - `gain` — "est. 1RM +19 kg in 9 weeks" (`ClipFeedPostStats.bestKg`) or "Project → Sent".
- `ClipAlbumCard`: Then vs Now stills (date + what you did), the gain, a timeline of sessions, **Open** (the
  Activity page) and **Progress reel** (each session's first video, captioned — `ClipsReelScope.progress`).
- Activities is unchanged (prompt 196's posts under the pinned session headers).

## Acceptance criteria

- [x] `ClipFeedLevelsTests`: session merge (order, labels, chips, stats + PR, own id, subtitle), feed order + reels
      kept, albums (identity only, order, counts, strength gain), climb album gain, PR counts.
- [x] `ClipsPostUITests.testTheLevelsAndTheyAreRemembered`: Activities default → Sessions labels → Exercises album
      → Open → the Activity page → relaunch remembers Exercises.
- [ ] Device: real sessions + albums; the progress reel from an album.
