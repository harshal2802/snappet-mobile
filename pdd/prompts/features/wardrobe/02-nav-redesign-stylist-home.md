# Prompt: Wardrobe nav redesign — kill the double bottom bar, stylist-first home (prompt 123)

**File**: pdd/prompts/features/wardrobe/02-nav-redesign-stylist-home.md
**Created**: 2026-07-12
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: wardrobe/01 → 02 (same PR #287, pre-merge UX fix from on-device review)
**Source**: user on-device feedback 2026-07-12: "I do not like this double navigation bar on the bottom"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Wardrobe 01 gave the module its own glass bottom bar (Closet · For You · Outfits) —
which stacks on the suite tab bar: duplicated chrome, cramped thumb zone, covered
content. Remove the module bar entirely and rebuild navigation as the **approved A+B
hybrid** (options wireframed in `docs/ux-research/wardrobe/redesign-nav.html`, user
picked hybrid): **B** — the root becomes a **stylist-first home** (Kilter landing-page
pattern): weather header, **For You carousel leads**, closet preview grid, recent
outfits, everything reach-or-push; **A** — "See all ›" pushes ONE
`WardrobeSectionsView` with a **top segmented control** (the Gym-Tracker
`WorkoutSection` pattern) for quick Closet/For You/Outfits jumps without popping home.

## Approach

- `WardrobeRootView`: drop the `Surface` enum + `safeAreaInset` glass bar; home =
  ScrollView (weather header · For You `HomeSuggestionCard` carousel → board · closet
  preview 4 tiles · `HomeOutfitRow` ×2) + coral FAB; `WardrobeSection` routes via
  `navigationDestination(for:)`.
- New `WardrobeSectionsView`: segmented `Picker` over the untouched `ClosetView` /
  `ForYouView` / `OutfitHistoryView` (they lose only their dead bottom-bar padding).
- `WardrobeUITests` rewritten for the home-first flow (For You card → board → save,
  preview → item, See-all → sections, segment-jump → Outfits).

## Acceptance criteria

- [x] Exactly ONE bottom bar anywhere in the module (the suite tab bar).
- [x] Home leads with For You; closet and outfits are one tap away; capture stays one tap (FAB).
- [x] Sections screen quick-jumps between the three surfaces without popping home.
- [x] Unit suite green; `WardrobeUITests` walkthrough green; knowledge graph updated.
