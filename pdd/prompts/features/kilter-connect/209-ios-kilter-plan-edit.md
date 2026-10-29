# Prompt: Edit a planned Kilter session (prompt 209)

**File**: pdd/prompts/features/kilter-connect/209-ios-kilter-plan-edit.md
**Created**: 2026-10-29
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo (on PR #402's branch).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Wireframe (approved 2026-10-29)**: `docs/ux-research/kilter-plan-edit/wireframes.html` / `.png`

## Goal

User: "add option to edit the planned session and add and remove new climbs". The preview was rebuilt from settings
on every change (edits would vanish) and a started plan was a frozen list with only Skip.

## Approach (user's picks Q1–Q3: "I like your suggestions")

- Preview: **Edit** turns the suggestion into a draft the screen stops rebuilding — ⊖ / swipe remove, drag within a
  section, long-press "Move to <section>" across sections (SwiftUI lists can't drag between sections — the honest
  substitute for Q1's cross-section drag), "+ Add a warm-up / send / project" per section. Shuffle becomes **Reset**.
  Changing Adjust after editing shows "Rebuild the plan and lose your edits?" [Rebuild] [Keep my edits] (Q3).
  Start session uses the draft.
- "+ Add" sheet (`KilterPlanAddClimbSheet`): search, "Near this grade" (the section's band), All / Not tried /
  Projects / Sent, Classics; only climbs the board can light; ✓ Added for climbs already in the plan.
- During a session: swipe a pending (or skipped) climb → Remove; "+ Add a climb" files it by grade against the
  plan's working grade (Q2): below → warm-up, at → send, above → project. Sent / tried picks stay (history).
- Pure edits in `KilterPlanProgress` (removing / adding / moving / reordering / normalized / canRemove /
  goalForAdded); the session manager's `editPlanItems` keeps progress + "next pick" in step. No schema change
  (`KilterPlan.items` is the existing Codable array).

## Acceptance

- [x] `KilterPlanEditTests` + full unit suite green; `KilterPlanEditUITests` (edit → remove → add → start → remove
      mid-session) green; Kilter UI slice green.
- [ ] Device: edit a real plan, add from Projects, start, remove/add mid-session.
