# Prompt: Design-system reset, step 1 — tokens, components, pickable accent (prompt 211)

**File**: pdd/prompts/features/design-system/211-ios-design-tokens-accent.md
**Created**: 2026-10-29
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockups (approved)**: `docs/ux-research/design-system/home-restyle.html`, `accent-options.html`, `home-periwinkle.html`

## Goal

User (2026-10-29), after comparing a screen recording of a reference app with Snappet's Home: "Snappet looks like
someone super new created it … help me make it look professional." Agreed plan: 1) tokens + components + a pickable
accent, 2) Home in the new style with every element deep-linking to its source, 3) the other screens. This is step 1.

## Approach

- **Accent, user-pickable** (user: "make this color profile configurable on the settings"): `SnappetAccent`
  Periwinkle (default, the user's pick) / Glacier / Teal / Coral, each with a light-mode and dark-mode value.
  `SnappetColor.brand` resolves from a UIKit trait bridged to a SwiftUI environment value (`SnappetAccentTrait` /
  `UITraitBridgedEnvironmentKey`), set once at the root (`.snappetTheme()`), so a change repaints every screen in place
  — ~80 `brand` uses and the root tint follow with no call-site changes and no lost navigation state.
- `onBrand` (text on a filled accent) and `brandGlow`; cooler, darker neutrals (paper / surface / hairline / text).
- **Appearance** System / Dark / Light.
- Type scale `SnappetType` (5 styles, regular weights, no tracked caps) and components: `snappetPanel(glow:)` (20-pt
  radius, hairline border, optional accent glow), `SnappetMetric` (big light number + small unit), `SnappetBars`
  (thin bars), `SnappetRow` (icon / title / subtitle / chevron), `.snappetPrimary` button.
- Settings → **Appearance** (swatches, live preview card, System/Dark/Light) — from the Apps tab toolbar for now;
  Home's avatar opens it in step 2.
- Meaning colours never follow the accent: done/green, heart-rate zones, Kilter hold colours, module wayfinding.

## Acceptance

- [x] `SnappetThemeTests` (default, fallback, WCAG ≥ 4.5:1 text on every accent in both modes, ≥ 3:1 accent on
      page, bar heights) — caught coral's 3.9:1 (darkened to #D13F33). Full unit suite green.
- [x] `AppearanceUITests`: Periwinkle → Teal repaints toolbar, tab bar and preview live (screenshots checked).
- [ ] Device: pick each accent and Dark/Light on the phone.
