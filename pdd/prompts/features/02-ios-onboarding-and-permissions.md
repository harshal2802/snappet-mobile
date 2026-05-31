# Prompt: Value-first onboarding + just-in-time permissions + limited-access fallback (P2)

**File**: pdd/prompts/features/02-ios-onboarding-and-permissions.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI).
**Chain**: `pdd/prompts/features/PLAN-ios-to-shippable.md` → P2
**Source**: [Snappet#60](https://github.com/harshal2802/Snappet/issues/60) §C (value-first, JIT permissions).
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Make the app actually usable on first launch with a **value-first** permission flow, and fix a latent
gap: `PhotoLibraryService.requestAccess()` is **never called anywhere**, so Photos authorization is
never requested and the reel flow would always throw `.denied`. Add an onboarding screen that explains
the value *before* asking, requests Health + Photos on an explicit tap (#60 §C), and handles
**`.limited`** Photo access with a manual `PHPicker` fallback (auto-discovery can't scan a limited
library).

## Context the implementer needs

- Entry: `SnappetApp.swift` → `RootView` → `WorkoutListView`; `RootView` runs `model.bootstrap()` which
  today silently requests Health and goes straight to the list.
- `AppModel.Phase` = idle/needsPermission/ready/error. `WorkoutListView` switches on it.
- `PhotoLibraryService.media(in:workoutStart:)` requires `.authorized` or `.limited`; under `.limited`
  the time-window fetch only sees the user-selected subset (crippled auto-discovery).
- HealthKit read-authorization status is **not readable** by design — don't try to query it; gate
  onboarding on a persisted "completed" flag instead, and request on tap.

## Approach

- **`AppModel`**: add `.onboarding` to `Phase`; persist a `hasOnboarded` flag (UserDefaults). On launch
  → `.onboarding` if not yet onboarded, else `bootstrap()`. Track `photoAccess: PHAuthorizationStatus`
  and expose `photosLimited`. Add `completeOnboarding()` (request Health, then Photos, persist, load)
  and keep `bootstrap()` for returning users.
- **`OnboardingView`** (new, `Features/Onboarding/`): value-first copy (what the app does + why it
  needs Health/Photos), one primary "Connect Health & Photos" button → `completeOnboarding()`. No
  silent prompts on appear.
- **Limited-access fallback**: a `MediaPicker` (`PHPickerViewControllerRepresentable`, configured with
  `photoLibrary: .shared()` so it returns asset identifiers). When `photosLimited` (or auto-discovery
  finds nothing), `ReelView` offers "Select clips" → map picked identifiers to `MediaItem`s via a new
  `PhotoLibraryService.media(forIdentifiers:workoutStart:)` (same creationDate→offset mapping).
- **`ReelViewModel`**: accept manually-picked media as the workout's media when provided; log nothing
  new (reuse existing events). Keep the engine call unchanged.

## Output

- `AppModel.swift` — phase + photoAccess + `completeOnboarding()`/`bootstrap()` updates.
- `Features/Onboarding/OnboardingView.swift` — the priming screen.
- `Services/MediaPicker.swift` — `PHPicker` bridge + result→identifier extraction.
- `PhotoLibraryService.swift` — `currentStatus` + `media(forIdentifiers:workoutStart:)`.
- `SnappetApp.swift`/`RootView` + `WorkoutListView.swift` + `ReelView`/`ReelViewModel` — routing + fallback.
- `decisions.md` entry: value-first JIT flow; `.limited` → manual picker.

## Acceptance criteria

- [ ] First launch shows onboarding; Health + Photos are requested only on the explicit button tap.
- [ ] Photos authorization is actually requested (the latent bug is fixed).
- [ ] `.limited` Photo access yields a working manual `PHPicker` path that produces `MediaItem`s.
- [ ] Whole app type-checks vs iOS 18 SDK (Swift 6, 0 warnings); engine untouched; `swift test` still green.
- [ ] No platform imports added to `HighlightEngine`.

## Constraints

- On-device only. Value-first: never request a permission before the screen that explains why.
- Type-check ≠ device run — state honestly that the permission UX is verified by type-check only here.
