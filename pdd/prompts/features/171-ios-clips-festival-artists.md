# Prompt: Clips — name the festival and artist; dynamic festival + artist filters

**File**: pdd/prompts/features/171-ios-clips-festival-artists.md
**Created**: 2026-10-09
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: phone check — user: "why do i only see Festival instead of festival+artist details on the post as well as filters.
can we make them dynamic as well"
**Context**: `pdd/context/decisions.md` (festival prompt 03 tagging)

## Why it only said "Festival"

A clip shows its artist only once it's MATCHED to a set (`FestivalTagSync`: confident matches auto-tag; the rest wait
in the Festival app's review queue). Untagged night clips fell back to the session name; the session header and the
chip only ever said the generic "Festival".

## Approach (user picked: festival chip → artist row; untagged = festival + day + "Tag artist")

- Posts carry `ClipFeedPostFestival` (pack id, festival name, day, artist?) — set posts (artist), a festival night's
  untagged clips (`SessionBundle.festivalNight`, artist nil), festival reels.
- Untagged night clips: title "Lost Lands 2026 · Saturday", subtitle "Not matched to an artist yet", and a
  **Tag artist** button (+ ⋯ menu item) opening the Festival app's own `FestivalTagReviewView` for that lineup; a
  confirmed match writes a `FestivalClipTag`, which the feed key already picks up.
- Session headers name the festival ("Sat 30 Aug · Lost Lands 2026").
- Filter: `festivalPack` + `festivalArtist` (.artist / .untagged), exclusive with `activity`. Chips (pure
  `ClipFestivalChips`): one per festival you have clips from (replacing the generic Festival chip), and — once one is
  picked — a second row: All · each matched artist (alphabetical) · Untagged (N).

## Acceptance criteria

- [x] Posts/headers name festival + artist; untagged offer Tag artist.
- [x] Festival chips per festival; artist row with matched artists + Untagged; filters exact (unit-tested).
- [x] `SnappetTests` 2384 green; Clips UI suite (see PR).
- [ ] Device: your Lost Lands posts show artists after "Tag artist" → review → confirm.
