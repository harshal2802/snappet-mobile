# Prompt: Wardrobe release polish — a cancellable edit sheet + small correctness fixes

**File**: pdd/prompts/features/wardrobe/06-release-polish-edit-sheet.md
**Created**: 2026-08-30
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: release-readiness review 2026-08-30 → wardrobe findings (P1 of 4 fix PRs)
**Source**: user ask — "find bugs and features which do not work intuitively … make this app release ready"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Close out the wardrobe findings from the release-readiness review. The headline bug: the item
edit sheet (`WardrobeItemEditSheet`) binds every field straight to the live `@Model`, so there is
no way to cancel an edit — every keystroke is already persisted, and swiping the sheet down keeps
half-applied values **without** the Done-path normalization (untrimmed brand/size/material, an
unparsed cost, an untaught vocabulary). That silently reopens the `'Uniqlo '`-vs-`'Uniqlo'` door
prompt 05 exists to close. Four smaller fixes ride along because they live in the same files.

## Context the implementer needs

- `WardrobeItemDetailView.swift` hosts the sheet. It also declares a completely unused
  `@Query private var allItems: [WardrobeItem]` (one wasted full-closet observation per detail
  open) and formats the "Added · cost" line with a hardcoded `"USD"`.
- The sheet's two form sections are **both** titled "Details" — the header renders twice.
- `WardrobePurchaseSection.swift` and `WearStats.costPerWearLabel` also hardcode USD, while
  Expense already derives the code from `Locale.current` (`ReceiptValidation.swift:132`).
- `WardrobeTidyStore.apply` re-`remember`s **every** item's brand and size on every run — not just
  the values the edits created — inflating `useCount`s. (`seedFromExistingItems` overwrites counts
  from the closet fold on the next Wardrobe open, so the skew self-heals; the loop is still wrong
  and does N pointless fetch-and-saves.)
- `WardrobeCaptureSheet.swift` drives its photo-cap alert off `isPresented:
  .constant(capMessage != nil)` — it only dismisses because the OK button manually nils the
  message. Any second dismissal path silently breaks.

## Approach

1. **Draft-based edit sheet.** `WardrobeItemEditSheet` copies the item's fields into local
   `@State` on appear (name, the four raw+map pairs, brand/size/material, productURL, seasons,
   costText). `WardrobeValueRow` binds to the drafts. **Done** writes back, normalizes exactly as
   before, saves, teaches the vocabulary, dismisses. A new **Cancel** button (and swipe-down)
   discards — no model writes ever happen before Done.
2. Delete the unused `allItems` query.
3. Retitle the second form section (category block stays "Details"; brand/size/material becomes
   "Brand & fit").
4. One currency-code source: `WearStats.localCurrencyCode` (`Locale.current.currency?.identifier
   ?? "USD"`), used by `costPerWearLabel`'s default, the detail "Added" line, and
   `WardrobePurchaseSection`. Tests keep passing an explicit code.
5. `WardrobeTidyStore.apply`: remember only the **applied edits'** new brand/size values.
6. Real two-way binding for the capture sheet's cap alert.

## Output

Changed: `WardrobeItemDetailView.swift`, `WardrobePurchaseSection.swift`, `WearStats.swift`,
`WardrobeTidyStore.swift`, `WardrobeCaptureSheet.swift`. Tests extended in
`WardrobeTidyStoreTests` (vocab fed only from edits) and a `WearStats` currency default check.

## Acceptance criteria

- [ ] Opening the edit sheet, changing fields, and swiping down leaves the item byte-identical.
- [ ] Done still normalizes brand/size/material, parses cost, and teaches the vocabulary.
- [ ] Editing an item with a custom category/color and pressing Done preserves the custom value
      (the prompt-05 regression guard still holds — drafts carry raw+map, never the typed setter).
- [ ] No duplicated "Details" header; no unused query; non-US locales see their own currency symbol.
- [ ] Tidy apply feeds the vocabulary only from its own edits; all existing tidy tests green.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` updated if a non-obvious choice was made.

## Constraints

- On-device only; no backend/network/accounts.
- The detail view's chips/purchase card must render identically after the refactor — this prompt
  changes edit *semantics*, not display.

## Test plan

1. `make ios-test-unit SIMULATOR='iPhone 17 Pro'` — full unit suite.
2. Wardrobe XCUITest slice (`-only-testing:` the wardrobe UI tests) — the sheet gained a button.
3. By eye in the sim: edit → swipe down → unchanged; edit → Done → changed + normalized.
