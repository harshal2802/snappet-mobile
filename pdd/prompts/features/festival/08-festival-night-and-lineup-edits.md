# Prompt: Festival — your night + lineup edits (prompt 232)

**File**: pdd/prompts/features/festival/08-festival-night-and-lineup-edits.md
**Created**: 2026-11-04
**Project type**: Native iOS (SwiftUI) — code lands in this repo.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Mockup**: `docs/ux-research/design-system/festival.html` (new frames: Start the night, arriving, "Where are you
now?", auto-move + notification + break / walking bar, set page I'm here + Edit time, Edit time, Festival home
"where am I", Edit lineup, Delay the schedule). The restyle frames in the same file are prompt 233.

## Why

The user's Halloween weekend: after "I'm here" on BOYS NOIZE B2B SALOME, the app never updated for the rest of
the night and wouldn't let them say they'd moved. Their asks, in their words:

- "there should be a way to say i am at the set on a individual sets page"
- "these set timing should be editable in case things start late or schedule change"
- "end the night means i am going home … at the end of each set ask where i am at or move to the next starred set
  automatically … option to add rest/walking to different set"
- "can we have option to start the night"
- "option to update where am i should be easyly accibile from festival home screen"
- "after i import or create a linup … edit it … shifting the entire schedule … on a given stage … delay due to
  weather"
- "give option to end the set along with end the night. and option to select what is next including
  walking/resting"

## Root causes (from the code)

1. A claim (`FestivalAttendance`) closed only on Switch or End the night — never at the set's end. The bar showed
   "On the floor — <artist>" forever.
2. The switcher offered only sets live **by the printed clock** plus one up-next. With a late-running night, the set
   the user was really at wasn't offered.
3. "I'm here" appeared only while a set was live by the clock; there was none on a set's page.
4. A night started only on the first "I'm here".
5. `Text("…" + "**x**")` concatenates into a `String`, which `Text` renders verbatim, so the bold markdown showed
   as asterisks (live sheet ×2, catalog privacy card).
6. The tag-review timeline drew every set on one row, so overlapping stages printed their names over each other.

## Approach

- **Pure `FestivalNight`:**
  - Status: off / at set / break · walking · arriving / between.
  - `claimHasEnded`: a claim made after the scheduled end is a running-late set and is left alone.
  - `outcome(after:)`: the next starred set playing at the end or starting within 30 min (same stage wins a tie),
    else ask.
  - `whereOptions`: on now (starred first) / running late (ended ≤ 45 min ago) / up next (≤ 90 min).
  - Still out at 2 h; an abandoned night ends itself after 6 h, back-dated.
- **`FestivalNightController`** (the SwiftData / live-services edge, lifted out of the schedule view):
  - Actions: claim, start the night, break / walking, end this set, end the night, confirm an auto-move.
  - `reconcile(now:)` runs on every schedule tick and on the home card. It loops, so coming back two sets later
    lands on the right one.
- **`FestivalNightStretch`** — a new additive `@Model` for break / walking / arriving. It is not an attendance row:
  attendance is the matcher's evidence and the danced total, so a break must not tag clips or count as dancing.
  It is in the schema, backup (round-trip seeded) and the session cascade, and is deleted with its lineup.
- **`FestivalAttendance.autoMoved`** (additive) drives "Moved you to your next starred set · Not there? Change /
  Got it".
- **Notifications:**
  - At the claimed set's end: "Moved you to ★ X" or "Where are you now?".
  - "Still out?" two hours after the night goes quiet.
  - One slot per lineup each.
- **UI:**
  - **Schedule bar:** I'm here / Start the night / On the floor / break-walking bar / "Where are you now?".
  - **Live sheet:** **End this set** (→ "What's next?") next to **End the night**; Switch opens the same picker.
  - **`FestivalWhereSheet`:** sets on now, running late and up next, then taking a break, walking to another
    stage, and End the night — heading home.
  - **Set page:** **I'm here** (any time) + **Edit time**, plus "Edited (was 23:30–01:00)".
  - **Festival home:** a "where am I" card per festival with a night on (Change where I am / Break), or one on
    today (Start the night).
- **Lineup edits — `FestivalLineupEdits`**, a JSON overlay on the new additive `FestivalLineup.editsData`:
  - Supports name, per-set artist / stage / start / end, removed, and added.
  - `FestivalLineup.pack()` applies it, so every surface sees the edited times. Set ids stay the original UUIDv5,
    so stars, claims and tags survive.
  - A set moved past rollover re-files under its new day. A stage left empty drops out.
  - Edits ride a reinstall and the backup (optional row field).
  - **Edit lineup** (schedule ⋯, or swipe / long-press a festival on the home list): Delay the schedule (all stages
    or one, from a time, by +15 / 30 / 45 / 60 / custom, with a preview), per-stage Delay this stage, tap a set to
    edit or remove it, Add a set, Add a stage, Rename, Reset all edits.
  - A delay touches only that festival day. A set already playing keeps its start and ends later.
  - **Edit time:** +5 / +15 / +30, exact times (past midnight handled), "Also move later sets on <stage>" on by
    default, and Reset to the lineup's time.
- **Fixes:**
  - The markdown strings are now single interpolated literals.
  - The timeline uses greedy lanes (`Block.lane`, `Layout.laneCount`).
  - The CSV export reads the edited pack.

## Acceptance

- [x] Unit: `FestivalLineupEditsTests` (apply / ids kept / reset / remove / add / re-file / delay targets / later
  sets), `FestivalNightTests` (claim end, outcome, where options, status, still out / abandoned, notification copy,
  timeline lanes), backup round trip incl. edits + a stretch (45 rows).
- [x] Affected UI suite: `FestivalUITests` (10/10 green, incl. the new Flow H + the home card) — the live sheet's switch → "Where are you now?" → claim; End this set →
  "What's next?" → break bar → End the night; the set page's Edit time (+15, "Edited (was …)") + I'm here; Edit
  lineup → Delay the schedule.
- [x] Unit suite alone green: 2674 (5 skipped).
- [ ] Device (MrRobot): a real night — start the night, a set ending into the next starred set, End this set →
  break, Edit time with later sets, a stage delay, the home card.
