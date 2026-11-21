# Prompt: Clip copies — choose what to free up (one clip; by age, activity, session)

**File**: pdd/prompts/features/cloud-connect/275-ios-clip-free-up-choose.md
**Created**: 2026-11-20
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P4 follow-up (on prompt 269's branch, after 274)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Prompt 274's "Free up space" was all-or-nothing: every copied clip left the phone. Let the person
choose.

## Product decisions (user, 2026-11-20)

"does free up space give me option to pick what to free up?" → offered per clip and by age; user:
"i like both of the options. but in option 2 along with age can we also have some filters based on
activity and sessions?"

1. **One clip** — "Remove from this iPhone" in a copied clip's "…" menu.
2. **A chooser** — Manage copies → "Free up space on this iPhone…" opens a screen with Age (any /
   older than 30 days / 6 months / 1 year), Activities (ticked rows) and Sessions (all, or picked).
   The three narrow each other; a running total shows clips and size.

## Approach

- **Pure** (`Core/MediaVault.swift`): `MediaVaultFreeUpItem`, `MediaVaultFreeUpChoice` (+ `Age`),
  `MediaVaultFreeUp.narrowed / selection / total / activities / sessions`,
  `MediaVaultText.freeUpTotal`.
- **Service**: `freeUpSpace(context:only:)`, `freeUpClip(_:context:)`, `freeUpItems(context:)`,
  `isBusy`. Verification, the iOS confirmation and the result note are prompt 274's, unchanged.
- **Views**: `Features/Backup/ClipFreeUpView.swift` (`ClipFreeUpView`, `ClipFreeUpSessionsView`,
  `ClipFreeUpCheckRow`); `ClipCopyMenuItems` gains the menu line. The old all-at-once button is
  gone — the chooser opens with everything selected, which is the same thing.

## Rules (each has a test)

- An original used by two clips leaves the phone only when both are chosen: freeing one session or
  one activity never takes footage out from under another. The total counts such an original once.
- From a clip's own menu the person means that footage, so every clip sharing the original goes
  with it.
- Unticking every activity selects nothing (a tick is literally "included"). "All sessions" is its
  own ticked row; unpicking the last session returns to it.
- The session list shows only sessions the age and activity choices allow.

## Known limits

- The chooser and the menu line have no UI test (they need a signed-in Google account with copies).
- A clip's age is when it was filmed, not when it was copied.
