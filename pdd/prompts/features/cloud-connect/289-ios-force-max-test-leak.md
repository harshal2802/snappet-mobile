# Prompt: The interval force UI test no longer inherits the last run's max

**File**: pdd/prompts/features/cloud-connect/289-ios-force-max-test-leak.md
**Created**: 2026-11-22
**Project type**: iOS (test isolation)

## Problem

`StructuredIntervalRunnerTests.testForceSensorShowsLiveForceAndTargetBand` failed on a developer
Mac with `"525 kg" is not equal to "52 kg"`. UI-test launches keep the force max in a scratch
UserDefaults suite (so a test on a real phone cannot overwrite the person's max), but that suite
was never emptied. Every keystroke in the field is saved at once, so a run that stopped after
typing "5" left 5 behind; the next run typed "52" after it and saved 525; from then on "52" made
"52552", which is refused, and 525 stayed. A fresh CI simulator never showed it.

## Change

- `ForceMaxStore.emptyScratchDefaults()` empties the scratch suite before handing it out;
  `AppModel` uses it for every test-store launch (`UITestStore.isFreshStore`, so seeded launches
  too).
- The UI test asserts the field starts empty before typing.

## Tests

`ForceMaxStoreTests` (new): a max is kept and cleared; the scratch suite starts empty. The UI test
passes twice in a row on a simulator that held the stale 525.

## Also checked, nothing changed

`HouseholdUITests.testHousePetScreenAndRecap` and
`ClipsPostUITests.testAPostWithStatsCaptionAndViewAll` both pass on their own. The pet test's
earlier failure in a full run was not reproduced.
