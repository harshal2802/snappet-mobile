# Prompt: iOS — accessibility pass (VoiceOver Studio + create-climb board, Dynamic Type, Reduce Motion)

**File**: pdd/prompts/features/52-ios-accessibility.md
**Created**: 2026-06-15
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: 2026-06-09 product review → iOS tracker [#100](https://github.com/harshal2802/Snappet/issues/100), Wave 3.
**Source**: GitHub issue [#79](https://github.com/harshal2802/Snappet/issues/79)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

VoiceOver users could browse climbs and log habits but were locked out of the two marquee creative
features (the Studio surface had zero labels; the create-a-climb board collapsed into one element),
sixteen absolute `.font(.system(size:))` sites ignored Dynamic Type (incl. the 56pt Pomodoro
countdown), and WorkoutTracker ran a second, ungated motion vocabulary so Reduce Motion users still
got slides in the largest module. Close those gaps.

## Approach

1. **One motion vocabulary, Reduce-Motion-correct.** `Transitions.swift`'s `Motion` is folded onto
   `SnappetMotion` (the gated Pulse tokens), and `workoutPhase`/`sectionSwap`/`liveBanner` become
   `reduceMotion:` factories returning `.opacity` cross-fades under Reduce Motion. The WorkoutTracker
   section swap, player phase, live banner, and the App Library focus chip route through the gated
   helpers (`Snappet.snappetAnimation(...)` for the `withAnimation` sites — the module qualifier
   disambiguates from the `View.snappetAnimation` modifier).
2. **Dynamic Type.** Absolute fonts → `@ScaledMetric(relativeTo: .largeTitle)` (Pomodoro countdown 56,
   rest timer 44, done seal 72, shell brand mark 44); Studio timeline 8/9pt chrome → scaled
   `.caption2`/`.caption`.
3. **Studio VoiceOver.** Explicit labels on the icon-only close / play-pause / keyframe (`diamond.fill`
   carries no default) / undo / redo / title; the centre playhead becomes an `accessibilityAdjustable`
   scrubber (±1 s); selected clips expose trim actions in the rotor (the 7pt drag handles are invisible
   to VoiceOver) and read a meaningful label.
4. **Create-climb board.** A VoiceOver-gated per-hole accessible overlay on `KilterEditableBoardView`:
   one 44pt hittable element per placeable hole, labelled by coarse board position + current role, whose
   double-tap cycles the role via the same logic as the sighted near-hit tap (extracted to a shared
   `cycle(_:)`). Built only under VoiceOver, so sighted tap is unchanged.

## Output

- `Features/Shell/Transitions.swift` — fold `Motion`, reduce-motion transition factories.
- `Features/WorkoutTracker/WorkoutTrackerModule.swift`, `WorkoutPlayerView.swift`,
  `Features/AppLibrary/AppLibraryView.swift` — gated motion call sites.
- `Features/Pomodoro/PomodoroRootView.swift`, `WorkoutPlayerView.swift`, `Features/Shell/RootShell.swift`,
  `Features/WorkoutTracker/StudioTimelineView.swift` — Dynamic Type.
- `Features/WorkoutTracker/StudioEditorView.swift`, `StudioTimelineView.swift` — Studio VoiceOver.
- `Features/Kilter/KilterEditableBoardView.swift` — per-hole accessible overlay.
- `pdd/context/decisions.md` + `docs/knowledge-graph/data.js`.

## Acceptance criteria

- [ ] Every Studio control reads a meaningful VoiceOver label; timeline trim/scrub usable via adjustable/rotor actions.
- [ ] A VoiceOver user can assign hold roles and save a climb (per-hole elements).
- [ ] Countdown / rest-timer / Studio text scales with Dynamic Type; key targets ≥44pt.
- [ ] With Reduce Motion on, WorkoutTracker section swaps and player phase transitions are crossfades, not slides.
- [ ] One motion vocabulary remains.

## Constraints

- VoiceOver/adjustable behavior is structurally implemented but can't be VoiceOver-tested off-device —
  record as device-pending (repo pattern). The 7pt timeline trim handles keep their visual size;
  trimming is offered as VoiceOver rotor actions rather than enlarging the dense handles.

## Test plan

`xcodebuild test -scheme Snappet -destination 'platform=iOS Simulator,id=…iPhone 17 Pro…'` stays green
(the studio/workout walkthroughs touch these surfaces). On-device: VoiceOver through the Studio and the
create-climb board; Dynamic Type at AX sizes; Reduce Motion on.
