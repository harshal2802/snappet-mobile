# Prompt: Festival tagging + the Clips payoff (festival prompt 03)

**File**: pdd/prompts/features/festival/03-festival-tagging-and-clips.md
**Created**: 2026-07-16
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData) — code lands in this repo only
(the pack host already exists; no web-repo companion this time).
**Chain**: `pdd/prompts/features/festival/README.md` → 03 of 06 (01 MERGED #292, 02 MERGED #293 —
build on both; do NOT touch the `.fpack` wire format or the matcher's confidence semantics)
**Source**: user ideation session 2026-07-16; wireframes `docs/ux-research/festival/wireframes.html`
frames 6 (set detail) · 9 (tag review) · 10 (Clips payoff) · 11 (recap). Frames 7–8 (notifications /
For-You) are prompt 04, frames 12–13 (QR) prompt 05 — do NOT build them here.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Close the loop the first two prompts opened: everything you filmed at the festival — live-sheet
recordings AND straight-from-the-Camera-app footage — gets **tagged to the artist's set** by the
pure `FestivalSetMatcher`, auditable in a **tag-review timeline sheet** that is never homework, and
then **pays off in the shared surfaces**: artist·stage-titled posts behind one new 🎪 chip in Clips,
a per-set detail with the set's HR curve and peak-at-the-drop callout, set/festival reels through
the ONE shared `ReelView`, and a festival recap ranking artists by *your* heart rate. Why now:
prompt 01 shipped the matcher with no clips to chew and prompt 02 ships clips with no tags — this
prompt is where "dance + video tagging" stops being a promise and becomes the product.

## Context the implementer needs

- **Prompts 01–02 are law.** `FestivalSetMatcher.autoTagThreshold` is THE line between silent
  auto-tag and "Needs you" (read it, never redefine it); `Assignment.Reason` cases are the review
  captions as data; `FestivalAttendance.hint()` already returns the matcher's
  `FestivalSessionHint` — recorded at prompt 02 exactly so tagging works retroactively.
- **Adapting media is the #283 pattern**: a dance `WorkoutSession`'s `SessionMedia` rows carry
  `offsetSec` from `session.startedAt` — `captureDate = startedAt + offsetSec` and the matcher's
  `ClipStamp` falls out. Camera-app footage is discovered into `SessionMedia` by the padded
  session window (`SessionMediaService.discover`, the `SessionDetailView.autoDiscover` /
  Apple-Watch-import posture: silent when authorized, never prompting from a background pass).
- **Tags persist as their own rows**, NOT as fields on `SessionMedia` (which is shared by every
  module): a `FestivalClipTag` @Model keyed by `mediaID` + content-derived `setID`, with
  `auto`/`user` provenance mirroring `MediaAssignmentSource` — the auto pass re-places `auto` rows
  and never clobbers a user's decision. New model ⇒ the two central edits + backup Rows
  (conventions §Adding a mini-app; the `SnappetBackupTests` tripwire fails until done).
- **Clips composition is pure** (`ClipFeedComposer`): festival posts are a new partition (like the
  reel partition), grouped by set, titled "Artist · Stage" so the existing title search matches
  artists for free. `ClipFeedPost.Discipline` and `ClipFeedFilter.Discipline` each grow ONE
  `festival` case; the chip strip grows ONE chip. The HR glass HUD, ✦ REEL badge, favorites, and
  fullscreen viewer all ride along unchanged because a festival post is a normal post.
- **Reuse, don't invent**: set-window HR = `HRWindowSlicer.slice` over the session series;
  the set-detail chart is the shared `HeartRateChart`; set/festival reels are `ReelSource`
  extensions (`workoutSession` / `WeeklyHighlights.stitchedWorkout` precedents) into the one
  shared `ReelView`; posters via `AssetPosterLoader`; fullscreen via `MediaBrowserView.clipsViewer`.
- Precedent files to read: `FestivalSetMatcher.swift`, `FestivalLiveSheet.swift` (attach funnel),
  `ClipFeedComposer.swift` + `ClipsFeedView.swift` (snapshot→compose→render),
  `SessionHighlightInput.swift` + `WeeklyHighlights.swift` (reel seeding), `HRWindowSlicer.swift`.

## Approach

All festival code stays in `ios/App/Snappet/Features/Festival/`, pure logic separated from thin
SwiftData/Photos edges:

- **`FestivalTagging.swift`** (pure) — the prompt's keystone: `stamps(...)` adapts plain
  session-media values into `ClipStamp`s; `plan(assignments:existing:)` partitions matcher output
  into silent upserts (≥ `autoTagThreshold`, never overwriting `user` rows) and the review queue
  (below threshold, unresolved); reason→caption mapping ("mid-set" / "between stages" / "two sets
  live" / "off the schedule") + candidate lists for Change ›; `posterWeekday` (rollover-aware day
  label for post subtitles); `FestivalTagTimeline` — the review sheet's timeline geometry (set
  blocks + clip ticks as fractions, fitted to the day's programmed span).
- **`FestivalSetStats.swift`** (pure) — set detail derivations: absolute set window → session-
  relative slice via `HRWindowSlicer`, peak (bpm + festival-local time label), average, danced
  seconds from attendance stretches; `FestivalRecap` — the weekend hero (nights / sets / hours
  danced / clips / peak ♥) and artists ranked by peak HR in *their* windows.
- **`FestivalClipTag`** @Model (in `FestivalModels.swift`): packID + content `setID` + denormalized
  artist/stage + `mediaID`/`sessionID` FKs + confidence + reason + `auto|user|none` provenance
  (`none` = "not from a set" — resolved, excluded everywhere). Schema + backup Row in the same change.
- **`FestivalTagSync.swift`** (thin edge, @MainActor): fetch the pack's attendance → sessions →
  optional silent Photos discovery (authorized only) → snapshot to values → matcher → apply
  `FestivalTagging.plan`. Runs from the schedule's `.task`, the review sheet, set detail, and after
  End-the-night — cheap and idempotent.
- **`FestivalTagReviewView.swift`** (sheet, frame 9): day chips when several days have clips,
  "N clips · N auto-tagged · N need you" summary, the timeline bar, "Needs you" rows (reason as the
  caption, Change › confirmationDialog over the assignment's own candidates + "Not from a set"),
  the auto block with "Looks right · keep all". Later/Done both dismiss — skipping keeps every
  auto tag (review is never homework).
- **`FestivalSetDetailView.swift`** (frame 6, pushed from a schedule row): artist/stage/time hero,
  Danced · Peak ♥ · Avg · Clips stats, the set's `HeartRateChart` slice with the peak callout,
  the clips row (✦ AUTO badges, tap → fullscreen viewer), Review tags ›, and ✦ Make a reel of
  this set → shared `ReelView`.
- **`FestivalRecapView.swift`** (frame 11, pushed from the schedule toolbar): hero + ✦ festival
  reel CTA + By artist rows (♥-ranked).
- **`FestivalReelSources.swift`**: `ReelSource.festivalSet` (one set: session HR, the set's tagged
  clips, the set window as the boost window, posts back titled "Artist · Stage") and
  `ReelSource.festival` (the whole weekend stitched via `WeeklyHighlights.stitchedWorkout`,
  `trimToHighlights` montage style, posts titled "<Festival> — Highlights").
- **Feed wiring**: `ClipFeedComposer.posts(..., festivalMeta:)` partitions tagged clips into
  per-set festival posts (and re-flavors a festival session's posted reels); `ClipsFeedView`
  snapshots tag/lineup rows into that meta; the 🎪 Festival chip joins the strip
  (`clips.filter.festival`); festival accent/glyph on the post header.
- **`FestivalNightSeed.swift`** + `-uiTestSeedFestivalNight` (implies the prompt-02 lineup seed):
  a finished dance session with synthetic HR, attendance stretches, and clips placed to yield one
  auto tag, one between-sets, and one two-stages-live — so the review sheet, set detail, recap,
  and the 🎪 chip all walk hermetically on the simulator.

## Output

- `ios/App/Snappet/Features/Festival/` — `FestivalTagging`, `FestivalSetStats`, `FestivalTagSync`,
  `FestivalTagReviewView`, `FestivalSetDetailView`, `FestivalRecapView`, `FestivalReelSources`,
  `FestivalNightSeed`; `FestivalClipTag` in `FestivalModels.swift`; entry points wired in
  `FestivalScheduleView`
- Central wiring: `SnappetSchema`, `SnappetBackup` (+Row), `SnappetApp` (seed arg)
- Feed: `ClipFeedComposer` (festival partition + `Discipline.festival`), `ClipFeedFilter`
  (`.festival`), `ClipsFeedView` (chip, snapshot, accent/glyph)
- Tests: `FestivalTaggingTests`, `FestivalSetStatsTests` (incl. recap), composer/filter festival
  cases in `ClipFeedComposerTests`/`ClipFeedFilterTests`, `FestivalNightSeedTests`, backup seeding
  grows `FestivalClipTag`
- `ios/App/SnappetUITests/FestivalUITests.swift` — the night walkthrough (review sheet → keep all →
  set detail → recap) + the 🎪 chip in `ClipsFeedUITests`
- `docs/knowledge-graph/data.js` — tag-review sheet, set detail, recap, tagging engine + tag model
  nodes; media→matcher→Clips and attendance→hints edges
- `pdd/context/decisions.md` — same-day entry for the non-obvious calls

## Acceptance criteria

- [ ] A clip whose assignment is ≥ `autoTagThreshold` tags silently; below it, it appears under
      "Needs you" with the machine reason as the caption — and skipping the sheet keeps the autos.
- [ ] The auto pass NEVER overwrites a `user` tag (override or keep-all), and re-running it is
      idempotent.
- [ ] Tagged posts appear in Clips titled "Artist · Stage" (existing search matches the artist),
      subtitle "<Festival> · <Weekday>", behind the one 🎪 chip; the gym chip no longer matches them.
- [ ] Set detail shows the set-window HR slice with a peak callout, danced/peak/avg/clip stats,
      ✦ AUTO badges, and feeds the SHARED `ReelView`; the posted set reel titles "Artist · Stage".
- [ ] Recap ranks artists by peak HR inside their own set windows; the festival reel stitches all
      the pack's dance sessions.
- [ ] Unit suite green; full XCUITest suite green (real UI); 0 Swift 6 warnings;
      `HighlightEngine` untouched.
- [ ] Knowledge graph + `decisions.md` updated in the same change.

## Constraints

- Do not modify the `.fpack` wire format, the matcher's confidence semantics, or `HighlightEngine`.
- No notifications, recommender, For-You, QR, or poster scan (prompts 04–06).
- Photos discovery never prompts from a background pass (authorized-only; the live sheet and
  session detail already own the ask), and bytes never leave Photos.
- Verification honesty: Camera-app round-trip discovery + reel export on the floor are device
  legs — state them owed, not verified.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — tagging plan/captions/timeline geometry, set
   stats + recap over the Glastonbury fixture, composer/filter festival cases, night seed
   properties, the backup tripwire.
2. `make ios-test SIMULATOR='iPhone 17 Pro'` — full suite incl. the seeded night walkthrough
   (review → keep all → set detail → recap) and the 🎪 chip.
3. Device (owed): film from the Camera app during a claimed set → end the night → open review →
   the clip proposes the claimed artist; export a set reel.
