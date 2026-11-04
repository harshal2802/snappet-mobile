# Prompt: Design-system reset — buddy & progression (prompt 230)

**File**: pdd/prompts/features/design-system/230-ios-buddy-progression-restyle.md
**Created**: 2026-11-04
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup (approved, user: "lets implement")**: `docs/ux-research/design-system/buddy-progression.html`
(before: `buddy-before-*.png`, as built: `buddy-after-*.png`)

## Goal

Fix the leftover the wireframe audit found: Home's buddy hero in its not-hatched and training-now states still had
an orange Hatch / Resume with white text. Restyle the rest of the buddy surfaces with it:
- `TrainingHomeView` (`BuddyHero`, every state)
- `BuddyScreen` + its Form / Style sheets
- `ProgressionMoments` (level up, grew up)
- `BuddyPrototypeView`

It is visual only. Ids and the "Resting" mood prefix the tests read are unchanged.

## Approach

- **Buttons:** Hatch, Resume workout and the moments' Nice / Meet your … use `SnappetWidePrimaryStyle` (ink on the
  accent).
- **Headings:** semibold (were heavy). The moment kickers are sentence case in the accent ("Level up", "Your buddy
  grew up"; were orange tracked caps). The big level / stage names are light (were black rounded).
- **Progress:** level bars, the grew-up arrow and the training-now "+N XP so far" use the accent (were orange /
  yellow).
- **Meaning:** Form is perfFresh at 45%+ and perfModerate below (were system green / orange / yellow). Paused is the
  accent (was blue / cyan).
- **Your buddy:**
  - Form / Week streak tiles get sentence labels and light numbers
  - row icons sit on neutral tiles (were blue / orange / green)
  - Recent XP is a sentence label with grey values (were heavy orange)
- **Sheets:** the Form sheet's % is light; the Style sheet's selection border is the accent.

## Acceptance

- [x] Affected suites green: ProgressionUITests, BuddyPrototypeUITests, HomeLinksUITests, CompletionMomentTests. As
  built matches the mockup.
- [x] Unit suite alone: 2653 green.
- [x] Device: user on MrRobot 2026-11-04 ("merge").
