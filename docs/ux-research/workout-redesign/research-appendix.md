# Research appendix — Workout (Gym Tracker) redesign

> Design-inspiration research behind the [README](./README.md) plan and [wireframes](./wireframes.html).
> Gathered by a 6-agent web sweep (Whoop, Hevy, Fitbod, Strava, Apple Fitness+, Gentler Streak, JEFIT,
> Kaya, Stokt, Spotify/Cash QR, …) and mapped onto the on-device-only Snappet "Pulse" system. The goal is
> to *elevate* the existing `SnappetColor` tokens, never to rebrand.

---

## 1. Dashboard / home

**What the best apps do**
- **One hero, not a grid.** Whoop opens with three dials answering "how hard should I train today?"; Apple
  Fitness leads with the activity rings. The top of the screen is *one* glanceable answer; everything else
  is progressive disclosure.
- **Resume / "up next" as a sticky priority card** (Peloton, Hevy/Strong "resume routine") — zero-scroll to
  the most likely next action; collapses when there's nothing to resume.
- **Recent sessions as compact summary cards** (Hevy: duration · total weight · sets · PR badges) — the card
  *celebrates and summarizes*; depth lives behind the tap. Short list + "See all", never infinite scroll.
- **PR / milestone badges** (Hevy live-PR banner; Fitbod logged 1.2M PRs in 2024) — the dopamine engine.
- **Consistency, framed kindly** (Gentler Streak's "sustainable range", an Apple Design Award) — a 7-day
  strip with "you're on track", not guilt-driven "don't break the chain".
- **Progressive disclosure / adaptive ordering** (Whoop's 3-tier model; Fitbod pre-picks the suggested
  workout so Start is one tap). MyFitnessPal's 2018 clutter redesign is the cautionary tale.

**What we adopted (Pulse Pro):** a conditional coral Resume card → one hero stat (coral ring) → a calm
7-day strip (today in coral) → a type-aware coral Start → a short mixed-discipline **recent-sessions feed**
(the single biggest current gap). One-accent discipline; the module dashboard stays rich *within* the gym
tracker and does **not** duplicate the suite Home feed.

---

## 2. Post-workout summary / session detail

**What the best apps do**
- **One type-chosen hero metric** (Strava run = distance·pace; Whoop = strain 0–21; Apple = Move ring;
  Caliber = Strength Score; Kaya = hardest send). Everything else demotes to a stat ribbon.
- **Zone-banded HR / effort viz**, not a bare line (Whoop 5 personalized zones + a stacked time-in-zone bar;
  Garmin time-in-zone + training effect).
- **Per-exercise / per-set breakdown with PR flags + the prior value in gray** (Hevy) — the "proof of work".
- **PR celebration moment** — confetti + haptic + named badge, *earned and rare* (Strava achievements; Hevy).
- **Type-adaptive layout** — the SAME scaffold renders a different hero + viz per type (the single biggest
  pattern). Climbing-native: a **grade pyramid** (Kaya ascent pyramid; Stokt) + an intensity band.
- **Shareable summary card** (Strava/Hevy/Gentler Streak) — the summary doubles as a marketing surface.
- **Antipattern:** Strava's 2025 activity redesign drew backlash for cramming map+stats+photos with nothing
  breathing — give one dominant zone.

**What we adopted:** unify `SessionDetailView` with the type-adaptive `FreeformDoneSummaryView` recap (one
scaffold, per-discipline skins): hero numeral + grade pyramid / time-in-zone / per-exercise rollups +
expandable breakdown + earned `CelebrationBurst`. "View detail" becomes *richer*, not poorer, than Finish.

---

## 3. Workout library (all types)

**What the best apps do**
- **Type as the first-class top facet** (Apple Fitness+ organizes the whole library by 12 workout types;
  Nike Training Club, Peloton) — the opposite of a flat strength list, and the only way to span modalities.
- **Two entry points** — a browsable standalone library (lean-back) *and* an inline multi-select +Add picker
  (lean-forward), the picker being a trimmed variant of the library (Hevy/Strong).
- **Faceted, persistent, composable filters** + a "no equipment" quick toggle; search always on top.
- **Recents/frequent first** — mid-workout users re-log known movements.
- **Rich detail = demo media → how-to → muscle map → YOUR history for this movement → records** (Hevy,
  JEFIT). History-by-movement (Setgraph/Strong) is the stickiest detail feature.
- **Inline custom creation with a measurement-type picker** (Hevy: weight&reps | bodyweight | duration) +
  "duplicate & edit".
- **Antipatterns:** flattening into one strength list; forcing a muscle map onto running/climbing; no
  library organization (Apple Fitness+'s documented weakness).

**What we adopted:** a polymorphic `LibraryItem` with **discipline as the top spine**; a faceted filter that
*swaps* by discipline; a "Recent across all types" band (the cross-discipline win); discipline-adaptive
detail (muscle map strength-only). Cross-session history needs the deferred per-entity `@Model` — flagged.

---

## 4. Routine / program builder (multi-type)

**What the best apps do**
- **One unified inline-editable card per exercise** whose columns adapt to the measure (JEFIT "Unified
  Workout Editing Screen": strength SET|KG|REPS|RPE; duration SET|TIME; cardio DURATION|DISTANCE|PACE) —
  edit sets in place, no drill-down. Rep **ranges** ("6–8"), set-type chips, per-set rest/interval.
- **Supersets/circuits as a visual GROUP container** (a colored left rail + A/B/C badges), not a per-set
  flag (Hevy, Strong, Fitbod superset weight-normalization).
- **Type-tagged blocks** so one routine mixes modalities (TrainHeroic exercises+circuits+notes; hybrid apps).
- **Drag-to-reorder + autosave** with a post-session "update routine?" prompt (Hevy).
- **Folders → Programs (week schedule) → routines**, reference-not-copy (Hevy, Ladder, Caliber).
- **Duplicate / start-from-template / save-as-routine**; seed starters so the empty state is never blank.
- **Antipatterns:** forcing a routine to a single type; modeling supersets as a boolean; copying routines
  into programs by value; a coach/marketplace tier (out of scope for an on-device solo app).

**What we adopted:** a **block-based** builder — type-tagged blocks (modality rhythm in one routine) +
adaptive cards (columns from the measure) + group-container supersets + drag-reorder. **Skip** the
coach/marketplace tier (on-device, solo); Programs are an optional later reference-not-copy tier.

---

## 5. QR sharing + smart planning

**Share-via-QR**
- **Reference-not-payload** (Spotify Codes → a URI; Cash App → a payment deep-link; WhatsApp contact QR) —
  the receiver's app resolves the id. The biggest payload-shrinking move, *but only works when the content
  is in shared local data.* A user routine is **not** in any shared catalog → it must travel.
- **Self-describing tag** (brand glyph center-punched; QR ECC-H tolerates ~30% occlusion) — keep the modules
  pure black-on-white for scannability, brand the surround.
- **Two-way sheet** (My Code / Scan segments) + **confirm-preview before import** — never silent-import.
- **Keep it small** (QR v3–4 ≈ ~134 alphanumeric chars scans phone-to-phone; pack a routine as exercise-id
  references + varints, not URL-encoded JSON).

**Smart planning (what we adopted: heuristic core + Apple-Intelligence sharpener)**
- **Recovery-as-fuel-gauge** (Fitbod per-muscle recovery %, 48–72h; Whoop recovery 0–100% green/yellow/red)
  → prioritize fresh groups, with a **manual soreness nudge** so the model stays honest.
- **One headline recommendation** (Whoop Strain Target: Rest/Maintain/Train/Push; Gentler Streak Activity
  Path) + a plain-language *why* — not a wall of numbers.
- **A draft you Accept / Swap / Tweak** (Fitbod swap; Freeletics "Adapt Session", "15 min only") — capture
  the edits as signals for next time.
- **Explainable, on-device, reproducible** — show the inputs; a transparent rules engine reads as more
  trustworthy than a black box and never needs the cloud. The Apple-Intelligence pass is an *optional
  on-device sharpener* (natural-language constraints), gated and degrading to the heuristic.

---

## 6. Visual design language & motion (the "Pulse Pro" direction)

- **Score-first hero numeral** — one big rounded number per screen (Whoop ~72pt recovery; Gentler Streak).
- **Semantic, not decorative, color** — Whoop: "every hue carries meaning." → a fixed vocabulary: **discipline
  accent = wayfinding** + a separate **green→amber→red performance ramp = effort/zone/PR**; coral = the
  single primary CTA. Never an accent just to fill a card.
- **Tiles are doorways** (Whoop overview) — glanceable summaries that drill in with spatial continuity.
- **Zone-banded curves / ring gauges** — banded meaning + one bright trace, not rainbow series.
- **Glass on chrome only** (iOS 26 Liquid Glass; Gentler Streak) — tab bar / floating controls / timer HUD;
  content cards stay flat + high-contrast. ~85% are pre-iOS-26 → solid fallback.
- **True-dark, data-pops dark mode** as the hero theme (gym/outdoor).
- **PR celebration tied to the brand accent** (Strava achievement glow; Boostcamp) — short haptic + brief
  visual inside the narrative, < 1.2 s, never a blocking popup.
- **Type identity = bold label + SF Symbol**, not color alone (color-blind safe).
- **Calm, spatially-continuous motion** (matched-geometry hero growth tile→detail) for review; snappy for entry.
- **Antipatterns:** glass everywhere; rainbow viz; coral overuse; hero-number inflation; pure-#000 dark mode;
  bouncy/over-springy review motion; a from-scratch rebrand.

---

## References (selected)

**Dashboards / home:** Whoop 5.0 home (whoop.com/thelocker), 925studios Whoop breakdown,
Gentler Streak (developer.apple.com Behind the Design; sketch.com blog), Hevy Personal Records & performance
(hevyapp.com/features), Fitbod strength score, Strong redesign case study, Mobbin Health-&-Fitness,
madappgang fitness examples, Stormotion fitness UX.
**Summaries:** Strava redesigned Activity Details + the5krunner critique + community backlash, Apple Fitness
activity summary, Whoop strain 0–21 + personalized zones, Hevy PRs/shareables, Gentler Streak, Caliber
Strength Score, Kaya intensity zones / ascent pyramid, Stokt stats, Boostcamp PR celebration.
**Library:** Apple Fitness+ (12 types), Nike Training Club, Peloton filters, Hevy/JEFIT/Strong exercise
libraries, Setgraph/Strong history-by-movement, MuscleMap SwiftUI SDK, "Best Strength Apps 2026" (cross-train).
**Builder:** Hevy gym routines / programming options / circuits, JEFIT Unified Editing + Set Types + Hybrid
guide, Strong templates/logging, Fitbod superset normalization, TrainHeroic coach builder, Edge hybrid,
Ladder, Caliber.
**QR + planning:** Spotify Codes, Cash App QR, WhatsApp/Signal contact QR, DENSO WAVE QR versions/capacity,
Fitbod algorithm Q&A (per-muscle recovery), Whoop Strain Coach, Gentler Streak Activity Path, Freeletics Coach.
**Visual/motion:** 925studios Whoop, Gentler Streak (pixso/sketch), Apple Design Awards, Strava redesign,
DesignRush fitness examples, iOS 26 Liquid Glass coverage (9to5mac/macrumors), Mobbin, LottieFiles.

*(Full URLs are preserved in the research workflow transcript. In-repo precedents to extend, not replace:
`SnappetColor.swift`, `SnappetCard.swift`, `SnappetMotion.swift`, `CelebrationBurst.swift`, the HR "Glass HUD"
zone-banded curve, `KilterRecommender.swift`, `KilterShareView.swift`, `KilterClimbIdentity.swift`.)*
