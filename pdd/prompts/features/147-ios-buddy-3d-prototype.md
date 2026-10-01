# Prompt: Training buddy — 3D prototype (spike)

**File**: pdd/prompts/features/147-ios-buddy-3d-prototype.md
**Created**: 2026-10-01
**Project type**: Native iOS spike (Swift / SwiftUI / RealityKit) — code lands in this repo.
**Chain**: session-progression — 146 session detail history → **147 3D buddy prototype** → (next) progression design + wireframe

## Goal

The user wants a virtual character that grows with progress, with users choosing an art style and the
character rendered as a 3D model, not pictures. Before designing the progression system around it,
put a real 3D buddy on the phone to judge feel, performance and look.

## Approach

- Pure `BuddyLook` maps stage (Egg → Hatchling → Sprout → Adult → Legend) + Form (0–1) + pause to
  size, colour, glow, bob, eyes, slump, unlocked parts (shell cup, antennae, arms, halo, sparks) and a
  mood line. Form changes mood, never size: a missed week makes it tired, not smaller.
- `BuddyCreatureView`: the "creature" style built in code with RealityKit (no art assets) — spheres,
  cylinders, PBR materials with emissive glow, lights + a virtual camera. `BuddyRig` keeps the entity
  graph; per-frame updates (TimelineView) move/recolour, parts rebuild only on stage/pause change.
  Drag to turn, tap to cheer (jump + spin + arms up); blink; orbiting sparks; "Z z" when paused;
  Reduce Motion stops the idle animation.
- `BuddyPrototypeView` (Workout → Settings → Labs): style picker (Creature live; Companion / Athlete
  locked "Coming soon"), stage picker, Form slider, pause toggle, Cheer button. Nothing is saved.

## Acceptance criteria

- [x] `BuddyLookTests` (6): size by stage only, parts by stage, Form → mood, sparks, pause, clamping.
- [x] `BuddyPrototypeUITests`: opens from Labs, mood follows Form/pause, cheer; screenshots of every stage.
- [x] Installed on MrRobot.
- [ ] User feel-check on device → decide 3D vs 2D, then design progression (XP, level, Form, pause,
      streak freezes) and where the buddy lives (finish screen, session header, Home).
