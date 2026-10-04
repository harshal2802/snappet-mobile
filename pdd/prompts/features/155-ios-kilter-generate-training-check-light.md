# Prompt: Kilter Generate — "was this in the training data?" + light it in the panel

**File**: pdd/prompts/features/155-ios-kilter-generate-training-check-light.md
**Created**: 2026-10-04
**Project type**: Native iOS feature (Swift / SwiftUI) + a data file on the Snappet web repo (Snappet#76).
**Design**: `docs/ux-research/kilter-generate/wireframes.html` (Q1 A publish the index · Q2 80% · Q3 auto-light OFF by default, with a switch)

## Goal

1. After generating a climb, say whether the model's training data had it — an exact copy, a match with a
   climb held out of training, ≥80% of holds shared, or new (with the nearest training climb).
2. Light the generated climb on a board from the Generate panel itself, without saving it first.

## Approach

- **Training index** (Snappet#76): `build-climb-dataset.py --training-index` re-derives the v1 split from the
  published snapshot — verified exact (87,879 train / 10,961 val examples = 52,878 / 6,600 / 6,860 climbs) —
  into `climb-generator/training-index.json.gz` (~4.6 MB, listed in the manifest as `trainingIndex`).
- `KilterGeneratorAssets.ensureTrainingIndex()` downloads + gunzips it once (reusing the catalog's gunzip);
  `KilterTrainingIndexStore` (actor) decodes + caches it; warmed when the generator model is ready.
- Pure `KilterTrainingIndex.check(frames:)`: exact `(placement, role)` set → in training / held out (val, test);
  otherwise the nearest **training** climb by shared placements over the larger climb (extra holds count
  against; ties → more ascents); ≥0.8 → very close (same holds, different roles = very close). Compact
  storage: sorted placements + one exact key per climb.
- Generate panel: a result card under the preview ("See it on the board" swaps the preview to that climb);
  a light section — Connect board (lights once connected), Light / Light again, "Auto-light each new climb"
  (`kilter.generate.autoLight`, default off), and an off-board warning with "Generate for <your size>".
- **Bug fixed**: the panel auto-lit with the generator's size LED map; LED addresses differ per size, so a
  climb generated for another size lit the wrong holds. It now lights with your board's size
  (`kilter.productSizeId`) and says which holds your board doesn't have.

## Acceptance criteria

- [x] `KilterTrainingIndexTests` (8): decode, exact training, held-out val/test, 80% close, same holds other
      roles, extra holds count against, nearest = training + more ascents, nothing in common.
- [x] Probe on the real index: "cam pussie" → in training; one hold changed → very close 6/7; decode 3.4 s
      in the debug simulator (off-main, prewarmed). Unit suite 2263 green.
- [ ] Device: generate at the board — training card, Connect board → lights, auto-light switch, size warning.
