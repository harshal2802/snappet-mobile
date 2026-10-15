# Prompt: Library redesign L3 — pin, rename, merge, hide; the climb reset window

**File**: pdd/prompts/features/185-ios-library-pin-rename-merge-hide.md
**Created**: 2026-10-15
**Project type**: Native iOS feature (Swift / SwiftUI + SwiftData) — code lands in this repo.
**Chain**: Library redesign wireframes (`docs/ux-research/library-redesign/wireframes.html`, screen 5, decision 3A,
§08 L3); builds on prompts 183–184
**Context**: `pdd/context/decisions.md`

## Goal

Let you fix and shape your own Library: keep favourites on top, fix a typo or a duplicate climb name across every
session, retire a gym climb without deleting history, and set how long your gym's climbs live.

## Approach

- `LibraryEntry` @Model (decision 3A): pin / hide per activity, keyed by `ActivityKey` (raw = exerciseId + U+001F +
  nameKey). In `SnappetSchema` + `SnappetBackup` (`LibraryEntryRow`, defaulted array so old backups decode). An entry
  with neither flag is deleted.
- Pure `LibraryMaintenance`, undoable: `rename` (every log of the activity; a catalog lift becomes a name override and
  keeps its identity), `merge` (sources take the target's name — and a climb's gym/wall/colour — from its latest log;
  grades, attempts, sets and clips are never rewritten), `apply(…, undo:)`, `lookalikes` (contained name or a few typos
  apart; never different grades or names differing only in a number), capabilities (festivals / overviews can't be
  renamed; catalog lifts can't merge).
- Activity page "⋯": Pin · Rename… · Merge with… · Hide. Rename/merge show a toast with **Undo**; the page follows
  the activity to its new identity and the pin/hide moves with it. Merge sheet (`sheet(item:)`): suggestions first,
  nothing pre-ticked.
- Library Yours: pinned lead every sort (pin icon), swipe → Pin / Hide, "Show hidden (n)" in the sort menu.
- Workout Settings → "Climbs reset after" (2–12 weeks, Never) → `ActivityIdentity.configuredResetDays`.

## Acceptance criteria

- [x] `LibraryMaintenanceTests` (rename + undo, blanks, catalog override, capabilities, climb merge keeps attempts,
      look-alikes incl. grade/number guard, entry key round-trip); backup round-trip covers `LibraryEntry`.
- [x] `LibraryManageUITests`: rename → page follows → Undo; merge (nothing pre-ticked, V2–V5 aren't look-alikes);
      swipe pin leads, swipe hide + Show hidden.
- [ ] Device: rename / merge on your real climbs; change the reset window and see sets regroup.
