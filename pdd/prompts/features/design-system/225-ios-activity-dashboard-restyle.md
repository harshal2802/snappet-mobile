# Prompt: Design-system reset, step 3e — the activity dashboard (prompt 225)

**File**: pdd/prompts/features/design-system/225-ios-activity-dashboard-restyle.md
**Created**: 2026-11-03
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "looks good")**: `docs/ux-research/design-system/activity-dashboard.html`
(before: `activity-before-*.png`, after: `activity-after-*.png`)

## Goal

Restyle an activity's page (`ActivityDashboardView`: Progress / Clips / About). It is visual only:
- the same accessibility ids
- the same tabs, taps and menus

## Approach

- **KPIs:** one `snappetPanel`, columns split by hairlines, light 20-pt numbers (were separate bold tiles).
- **Cards:** the `card()` helper is a `snappetPanel` with a grey sentence title + trailing label.
- **Hero chart:**
  - line + points in the accent (was the discipline colour)
  - filmed points stay bigger and **keep their `video.fill` marker**, plus the "📷 = has clips" legend. The user
    caught the first mockup dropping the marker.
  - the selection rule is tertiary
  - Play clip is an accent pill
- **Meaning colours stay:** the Effort chart keeps perfHard red and HRV keeps green.
- **Records:** neutral trophy tiles, medium values.
- **Frequency:** accent squares.
- **Bottom:**
  - Log it now is `SnappetWidePrimaryStyle` (was orange); Add to routine is a hairline outline.
  - Open on the board is a wide accent button (was Kilter amber `.borderedProminent`).
  - All of it sits on paper (was `.bar`); Undo uses the accent.
- **Shared pieces:**
  - `PastClipsChip` is an accent pill (was a workout-orange fill). It's also on session detail and the player.
  - About (`ExerciseDetailView`): the guide-photo row gets a neutral tile; primary muscles and step numbers use the
    accent.
  - Clips tab / Compare picker: medium date headers, `onBrand` badge text.

## Acceptance

- [x] Dark screenshots match the mockup (Progress top, records, About).
- [x] Full UI suite: only the known `525 kg` test failed. Unit suite alone: 2653 green (the first run's runner never
  started and the re-run passed).
- [x] Device: user on MrRobot 2026-11-03 ("merge after testing").
