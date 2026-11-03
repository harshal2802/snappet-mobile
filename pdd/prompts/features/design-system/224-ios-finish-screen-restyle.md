# Prompt: Design-system reset, step 3e — the finish screen (prompt 224)

**File**: pdd/prompts/features/design-system/224-ios-finish-screen-restyle.md
**Created**: 2026-11-03
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement")**: `docs/ux-research/design-system/finish-screen.html`
(before: `finish-before-1.png`, after: `finish-after-1.png`)

## Goal

Restyle the completion summary the player shows on Finish (`FreeformDoneSummaryView`, `SessionXPCard`,
`RacketRecapCards`). It is visual only, like 223:
- the same accessibility ids
- the same strings (tests read "Workout Complete" / "Sets")
- the same actions

## Approach

- **Seal + milestone:** the accent (were workout orange). The title is 26 semibold and the name is a grey detail.
- **Actions:**
  - Done is `SnappetWidePrimaryStyle` (was orange `.borderedProminent`).
  - Save as routine is an accent-outline capsule; View detail is a hairline outline. Both were `.bordered` fills.
  - Discard is unchanged.
- **Studio CTA:** a neutral glyph tile, title and grey detail in a panel.
- **`SessionXPCard`:** one `snappetPanel`.
  - The 3D buddy keeps its cheer on a neutral tile (was a buddy-hue gradient).
  - "+N XP" is a light metric. `xp.total` is the combined element, so its label still starts with "+".
  - Reason rows: ink labels, grey values, hairline separators (values were heavy orange).
  - The level bar is 5 pt, accent with this session's gain lighter. The level-up line is perfFresh medium, and End
    pause is the accent.
- **`RacketRecapCards`:**
  - a panel with a sentence label (was racket-colour tracked caps) and a light record
  - neutral row glyphs and an outlined result capsule
  - a sentence-case per-game HR label

## Acceptance

- [x] Dark screenshot matches the mockup (top + actions). The XP card was drawn from code: a sim session is under 5
  min, and the 3D buddy renders blank on the sim.
- [ ] Full UI suite, then the unit suite separately.
- [ ] Device: user on MrRobot (the XP card + cheering buddy need a ≥ 5 min session).
