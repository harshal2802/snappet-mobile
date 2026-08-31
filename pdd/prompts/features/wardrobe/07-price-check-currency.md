# Prompt: Price check keeps its currency — and the backup row catches up

**File**: pdd/prompts/features/wardrobe/07-price-check-currency.md
**Created**: 2026-08-31
**Project type**: Native iOS fix (Swift / SwiftUI) — code lands in this repo.
**Chain**: release-readiness review 2026-08-30 → finding 5's leftover sub-item (last code item)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

A fetched price must render in the currency it was quoted in. `WardrobePriceParser` extracts the
retailer's `currencyCode` (JSON-LD `priceCurrency`, OpenGraph, microdata) and
`WardrobePriceService` returns it — then `WardrobePurchaseSection.check()` matched
`.updated(amount, _, _)` and threw it away, so a €89 page rendered as $89. The
write-path-without-read-path family, one hop from the finish line.

While mirroring the new field into the backup, a bigger catch-up surfaced: `WardrobeItemRow`
never got the prompt-04/05 **columns** at all (brand, sizeLabel, productURL, currentPrice,
currentPriceCheckedAt, the four custom-value maps, coverPhotoRoleRaw). New *tables* got rows in
those prompts; new *columns* on an existing model did not — and neither tripwire could see it:
the model-coverage check proves each `@Model` has a row, and the snapshot-equality round trip
can't catch a field the row never captures (it's absent from both sides). Every backup restore
was silently dropping that data.

## Approach

- `WardrobeItem.currentPriceCurrencyRaw: String = ""` (empty = unlabeled parse / pre-07 check →
  the UI falls back to the local currency, the pre-07 behavior).
- `check()` stores the code with the amount. The **fetched** price renders with
  `WearStats.fetchedPriceDisplayCode` (retailer's code, else local); "Paid" stays local — the
  user typed that number. The ↑/↓ delta badge is gated on `WearStats.priceDeltaComparable`
  (same currency, or legacy-empty): a percentage between a $ cost and a € price is nonsense.
  Both helpers pure (local code is a parameter).
- `WardrobeItemRow`: all eleven missing columns added as **Optionals** (old backup files decode
  missing keys as nil → model defaults); `make()` restores them.
- Tests: two pure helper tests; a **model-level** fidelity test (seed all richer columns →
  snapshot → encode → decode → restore → assert each on the fetched model — the assertion style
  the snapshot-equality test structurally cannot provide); the shared seed item enriched.

## Acceptance criteria

- [ ] A check against a page quoting EUR shows the price as € and hides the delta badge for a
      $-entered cost; a same-currency check still shows it. Legacy checks unchanged.
- [ ] Backup → restore preserves brand/size/link/prices/currency/maps/cover-role (unit-tested on
      the restored model). Old backup files still decode.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated (the column-drift lesson).

## Constraints

- No migration: the new model field has an inline default (CloudKit-safe, lightweight).
- The price check's posture is untouched — one GET per explicit tap, never onAppear.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'`.
2. Device leg (owed, rides the existing price-check leg): check a real EUR/GBP product page.
