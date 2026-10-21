# Prompt: Clips posts, Instagram-style — stats, captions, #tags, set chips, View all

**File**: pdd/prompts/features/196-ios-clips-posts-captions.md
**Created**: 2026-10-20
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData) — code lands in this repo.
**Chain**: Clips redesign — wireframes `docs/ux-research/clips-feed-levels/wireframes.html` (user picks: Activities
default + remembered · a caption per post at each level · free text + suggested #tags · the Exercises album this
phase). Part 1 of 2; 197 = the Sessions · Activities · Exercises switch.
**Context**: `pdd/context/decisions.md`

## Goal

User (2026-10-19): "can we also put more information on clips feed. instead of just saying climbing/session … also
maybe have instagram style post view with description and stuff".

## Approach

- Pure `ClipPostStats` (`ClipPostStats.swift`):
  - `ClipFeedPostStats` per exercise in a session: the stats line (`LibraryCatalog.lastLine`: "4 × 8 @ 75 kg",
    "V4 · 3 attempts", "3 × 1:03", "5 km · 5:33/km"), `isPR` (est. 1RM beats every EARLIER session), each set's
    detail (`SetMeasure.displaySummary`), and its `ActivityKey` + title.
  - Built in the feed snapshot for filmed sessions only, with one chronological pass for prior bests.
  - Threaded through `SessionBundle.exerciseStats` → `ClipFeedPost.stats` (incl. `dedupedByAsset` — the
    known gotcha).
  - `ClipFeedComposer.activityClipCounts` → "View all N".
- Captions: `ClipCaption` (text + showStats / showSets / showHR) stored as a `FeedReaction` (`typeRaw "clipCaption"`,
  `activityContentId "clippost:<post.id>"`, JSON value) — no new model, already in the backup. `ClipCaptionStore`
  caches them; the feed attaches them at render (an edit never re-composes the feed). `#tags` parsed from the text;
  `suggestions` = #PR / #sent / the session / the activity / the festival, minus ones already written.
- `ClipPostCard`:
  - ♡ moves from the header to an action row: ♡ · ✎ caption · ↗ share (with HR when there's HR) · ✂︎ Studio,
    plus "Set 2 of 4".
  - The stats line (green "· ▲ PR"), the caption with blue #tags (or "Add a caption…"), and set chips
    ("★ PR", "Set 2 · 75 kg × 8" — tap to jump the carousel).
  - "View all N Bench Press clips ›" → the Activity page (a `navigationDestination` on the Clips stack).
  - Switching the HR tile off hides that post's overlay.
- `ClipCaptionEditor` (wireframe screen 4); search matches captions (`ClipSearch.matches(_:caption:)`).

## Acceptance criteria

- [x] `ClipPostStatsTests`: line + set details, PR only when beating earlier sessions, caption round-trip + tags +
      default, suggested tags, caption search, stats through the composer + per-activity counts.
- [x] `ClipsPostUITests`: stats line + View all 4 → caption with a suggested tag → shown with the tag → View all →
      the Activity page; a caption is found by search.
- [ ] Device: real posts' stats + PRs; caption survives relaunch + backup.
