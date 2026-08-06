# Prompt: Richer add form — brand, size, link, prices, open vocabularies (wardrobe prompt 05)

**File**: pdd/prompts/features/wardrobe/05-rich-add-form.md
**Created**: 2026-08-03
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: wardrobe device-feedback trio → P3 (P1 = prompt 03 pipeline, P2 = prompt 04 multi-photo)
**Source**: user device feedback 2026-08-02 — "make add to closet form more feature rich… brand, size,
online link, price bought, current price if online link is provided, allow a way to add custom value
in all the fields which have dropdown and also update same value in related dropdown for future."
**Wireframe**: `docs/ux-research/wardrobe/rich-form.html` — **approved before implementation**
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Capture the facts a closet actually needs — who made it, what size, what it cost, what it costs now —
and stop forcing them into fields that don't fit. This is not only new inputs: the real closet
already contains this data in the wrong places, so the prompt has to **move what's there** as well.

## The data this is designed against (measured, not assumed)

Pulled from MrRobot's App Group container, 100 garments:

- **`material` is being used as a brand field**: Uniqlo 32, Lululemon 30, Temu 10, Amazon 5,
  Zara/Nike/Adidas 2 each. **41 of 95** non-empty values carry stray leading/trailing whitespace, so
  `'Lululemon '` and `'Lululemon'` are two distinct values today (22 raw distinct → 19 normalized).
- **Size is typed into the item name** 10× ("Black tank top size M").
- **Six values are prints, not brands** — "Subtronics “BE NICE PLEASE”", "One piece zoro", "Illenium",
  "Lollapalooza", "Insomniac camp edc", "Hello kitty". The brand/print split is **not
  machine-decidable**; the migration must ask rather than guess.
- Cost is already well-adopted (93/100), so price-paid needs no encouragement — price *now* is the gap.

## Approach

- **Schema** (`WardrobeModels.swift`), all optional / inline-defaulted so the prompt-01 CloudKit
  posture holds and this stays a **zero-migration** change:
  `brand`, `sizeLabel`, `productURL`, `currentPrice`, `currentPriceCheckedAt` on `WardrobeItem`
  (`cost` already is price-paid). Plus `WardrobeVocabulary` (one row per remembered custom value:
  `field`, `value`, `mapsToRaw`, `useCount`) and `WardrobeTidyEdit` (the undo log — `batchID`,
  `itemID`, `field`, `oldValue`, `newValue`).
- **Custom values in scored dropdowns carry their own mapping.** `colorRaw` keeps the *display*
  string ("Mustard") and a sibling `colorMapRaw` holds the built-in it behaves like ("yellow"); the
  typed accessor prefers the raw, falls back to the map, then to the default. Storing the mapping
  **on the item** rather than looking it up keeps `OutfitComposer` a pure function of the item — no
  vocabulary fetch inside scoring. Same for category / pattern / style. Brand, size and material are
  unscored free text and get no mapping.
- **Pure logic**, unit-tested with no store:
  - `WardrobeVocabularyRules` — normalize (trim + collapse whitespace), case-insensitive dedupe,
    most-used-first ordering. This is what makes `'Uniqlo '` unable to recur.
  - `WardrobeTidyPlan` — analyze items → grouped proposals (material→brand, size-out-of-name),
    **with an `uncertain` bucket** for values that look like prints. Produces the edit list the UI
    renders and the store applies; never mutates anything itself.
- **Price check** — `Services/WardrobePriceService.swift`. **User-initiated only**: one `URLSession`
  GET per tap, no polling, no background refresh, no accounts. Parsing is on-device: a
  JSON-LD / OpenGraph / regex floor always runs, and Apple Intelligence refines it behind the E7
  contract (`#if canImport(FoundationModels)` + availability, silent degradation) — same shape as
  `WardrobeIntelligence`. **A failed check keeps the last known price and its old timestamp**; it
  must never blank good data. Always store `currentPriceCheckedAt` so a stale number can't read as live.
- **Tidy-up** — `WardrobeTidyView`, reviewable and **undoable**: applying writes `WardrobeTidyEdit`
  rows under one `batchID`, and "Undo tidy up" restores them. Nothing is rewritten before Apply.

## Output

- `WardrobeModels.swift` (fields + `WardrobeVocabulary` + `WardrobeTidyEdit`), `WardrobeTags.swift`
- `WardrobeVocabularyRules.swift`, `WardrobeTidyPlan.swift` — new, pure
- `WardrobeVocabularyStore.swift`, `WardrobeTidyStore.swift` — new
- `Services/WardrobePriceService.swift` — new
- `WardrobeCaptureSheet.swift`, `WardrobeItemDetailView.swift`, `WardrobeItemEditSheet`,
  `WardrobeValuePicker.swift` (the shared "your values + Add new…" sheet), `WardrobeTidyView.swift`
- `Core/SnappetBackup.swift` — rows for both new models
- Tests: `WardrobeVocabularyRulesTests`, `WardrobeTidyPlanTests`, `WardrobePriceParsingTests`
- `pdd/context/decisions.md`, `docs/knowledge-graph/data.js`

## Acceptance criteria

- [ ] Brand / size / link / price-paid / current-price all persist and round-trip through backup.
- [ ] A new custom value appears in that field's dropdown next time, ordered by use count.
- [ ] `'Uniqlo '` and `'Uniqlo'` normalize to ONE vocabulary entry.
- [ ] A custom color still scores in `OutfitComposer` via its mapping — an item with a custom color
      must not vanish from suggestions.
- [ ] The fast path is unchanged: a quick add never has to touch the new fields.
- [ ] Price check is user-initiated only; grep proves no timer/background/`onAppear` fetch.
- [ ] A failed price check leaves the previous price AND its previous timestamp intact.
- [ ] Tidy-up changes nothing before Apply, buckets the six print-like values as uncertain, and is
      fully reversible via one Undo.
- [ ] App changes type-check against the iOS 18 SDK (Swift 6, 0 warnings).
- [ ] `decisions.md` + `docs/knowledge-graph/data.js` updated in this change.

## Constraints

- The price fetch is the app's **first third-party network call**. Existing network (Kilter catalogs,
  festival lineups) hits our own GitHub Pages; this hits arbitrary retailers. Keep it user-initiated,
  one request per tap, and say so in the UI. Record the posture change in `decisions.md`.
- CloudKit-compatible: inline defaults / Optional, no `.unique`, no relationships.
- State verification honestly: a real retailer fetch + the Apple-Intelligence parse are **device-only**
  legs (FM needs an AI-capable device); the parsing floor is testable offline against saved HTML.

## Test plan

1. `WardrobeVocabularyRulesTests` — normalization, whitespace merge, case-insensitive dedupe, ordering.
2. `WardrobeTidyPlanTests` — seeded with the REAL shapes (`'Lululemon '` vs `'Lululemon'`, "…size M",
   "Illenium") — confident buckets, uncertain bucket, and that the plan is inert until applied.
3. `WardrobePriceParsingTests` — JSON-LD / OpenGraph / bare-markup fixtures, plus the failure case
   that must preserve the old price and timestamp.
4. Backup round trip covering both new models; tripwire green.
5. Device: real product URL on MrRobot, custom color end-to-end, tidy-up apply + undo on the real closet.
