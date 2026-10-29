# Prompt: Design-system reset, step 2 — Home restyle, every element links to its source (prompt 212)

**File**: pdd/prompts/features/design-system/212-ios-home-restyle.md
**Created**: 2026-10-29
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved)**: `docs/ux-research/design-system/home-periwinkle.html`
**Depends on**: prompt 211 (tokens, components, pickable accent — #404)

## Goal

Step 2 of the design-system reset. User (2026-10-29): "make sure everything you show in home has a deep link to get
to its source" and "buddy as small avatar". Restyle the training Home (`TrainingHomeView`) in the calmer style —
one card style, regular weights, one accent — where every element opens the screen it came from.

## Approach

- Header: date, "Today", avatar → **Settings** sheet (`SuiteSettingsView`: Appearance, Heart rate & devices,
  Back up & restore).
- Buddy card: the pre-rendered still (`BuddyStills`, shared with the widget) as a 54-pt avatar, level, mood/form, XP
  line → your buddy. The 3D hatch stays for the one-time hatch; mid-workout the card shows the session + Resume.
- Today panel (glow): card → the routine's page; Start (primary), Skip today, Pause…; calm rest / done / paused states.
- This week (XP + thin per-day bars) → History on this week; a bar → History on that day (`HistoryDateRange`, chip).
  Streak (weeks, freezes) → your buddy. Equal-height pair.
- Recent wins as `SnappetRow`s → that session. Coming up: growth / freeze → buddy; milestone → routine or its latest
  session. Other apps as rows → the app. Notes as quiet lines with an inline "Do it today ›" link.
- Activity feed in one panel, back-to-back repeats collapsed (`FeedRuns.collapse`).

## Acceptance

- [x] `HomeLinksTests` (week / day windows, feed collapsing) + `TrainingHomeTests` green.
- [x] `HomeLinksUITests`: avatar → Settings → Appearance; This week → History with "This week" chip (chip clears);
      day bar → that day; Streak → buddy; win → session; milestone → routine/session. Today → routine runs only on a
      seeded planned weekday (skips otherwise). `ProgressionUITests` still green.
- [x] Light + dark screenshots reviewed.
- [x] Device: Home scrolls smoothly on MrRobot (user, 2026-10-29).
- [ ] Device: every link on the real history.
