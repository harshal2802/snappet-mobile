# Kilter Improvement — research appendix

> The design + technical research behind [README.md](./README.md), with citations. Gathered by a
> 13-agent workflow (5 design/tech sweeps + 6 code maps + synthesis + a board-detection feasibility
> adversary), 2026-06-19. Dribbble/Pinterest/Mobbin links are mood-board references — many tag/search
> pages render empty to automated fetchers and must be browsed in a real browser.

---

## 1. Board / gym auto-detection — the technical reality (the crux)

**The finding that reshaped the feature.** The Aurora/Kilter board is a **write-only LED controller**.
Three facts, cross-checked against the BoardLib + grip-connect reverse-engineering work and the official
app's behavior, and confirmed against our own `KilterBoardController`:

1. **The BLE advertisement carries no board identity.** All Aurora boards (Kilter/Tension/Decoy…) advertise
   the *same* fixed primary service UUID (`4488B571-…`); discovery is by service-UUID filter, not board
   type. There is no layout/size field on the wire. The board doesn't even *know* its own layout — that
   lives in the app's SQLite config, keyed by IDs the board never sends.
2. **The advertised local name is `<owner-name>#<serial>@<apiLevel>`** (e.g. `mykilterboard#2353@3`). The
   leading name is owner-chosen (collisions possible); the `#serial` token can survive an app reinstall as
   a cross-check, but the convention is community-reverse-engineered, not hardware-confirmed.
3. **Angle is never transmitted electronically** — across every source, angle is always a manual in-app
   pick (even on motorized frames). So a cached angle is a smart *default*, never a read fact.
4. **The official app knows your gym's board because you pick it from an *online* gym directory** that
   syncs — a network/account feature our on-device-only constraint forbids. We cannot ship that directory.

**Conclusion:** detecting a *never-seen* board on-device is impossible. The feasible, genuinely useful
reframing is to **recognize a board this phone has connected to before** — keyed on `CBPeripheral.identifier`
(install-local, stable, already captured at `KilterBoardController.swift:329`), with the `#serial` as a
reinstall cross-check, and (Option B, user-chosen) a **coarse CoreLocation place** to suggest the board on
arrival and disambiguate two boards at one gym. Model it 1:1 on the app's existing `BandMemory`/`BLEBands`.

**Citations:**
- BLE protocol (service UUID, name format, LED message): https://stevie-ray.github.io/hangtime-grip-connect/devices/kilterboard · https://github.com/Stevie-Ray/hangtime-arduino-kilterboard · https://github.com/1-max-1/fake_kilter_board
- SQLite schema (products/layouts/sizes/sets) + logbook fields (board, angle, climb_name, grade): https://github.com/lemeryfertitta/BoardLib · https://pypi.org/project/boardlib/0.8.0
- Board sizes / how the board is used / official app gym selection: https://settercloset.com/pages/kb-board-sizes · https://settercloset.com/pages/kb-app · https://gripped.com/indoor-climbing/how-to-use-a-kilter-board/

---

## 2. Climbing logbook & session-history UI

**Patterns adopted (Flow 4):**
- **Context-aware stat headlining (the 3-4 facts rule).** Don't show every stat on a card — pick the 3-4
  most meaningful; Strava swaps elevation in for pace only when the route is hilly. → adaptive session cards.
- **Send-vs-attempt hierarchy.** Climbing is entity-then-attempt: a climb has attempts that resolve to a
  status (flash/send/project/DNF). → status chips everywhere, glyph+label.
- **Month/week grouping with sticky headers that double as period totals.** → roll-up headers
  ("June — 7 sessions · 41 sent · hardest V7").
- **Calendar + heatmap.** Hevy's tappable month calendar (day-dots open that day's session) *and* a
  GitHub-style consistency heatmap (cell intensity = volume), both as navigation. → user chose **both**.
- **Scope switcher** (Week / Month / All-time, Stōkt-style). → the scope segment.
- **Kind streaks** (Gentler Streak): "weeks climbed" + trend-vs-baseline, rest days legitimate.

**Reference apps:** Kilter/Aurora logbook (day-view grouped by date; per-climb embeds your own history) ·
Vertical-Life/8a.nu (unified scorecard) · Kaya (auto-session, volume counter → full logbook) · Flashd
(post-session 4-fact summary) · Stōkt (week/month/all scope) · Mountain Project (tick-list) · Strava
(context-aware card stats, single achievement badge).

**Citations:** https://apps.apple.com/us/app/kilter-board-climbing-wall-app/id6755110303 ·
https://apps.apple.com/us/app/vertical-life-climbing/id710386774 · https://www.8a.nu/premium ·
https://kayaclimb.com/blog/logging-your-climbs-on-kaya · https://www.flashd.app/ ·
https://apps.apple.com/us/app/st%C5%8Dkt-climbing/id1436843282 ·
https://apps.apple.com/us/app/mountain-project/id452308783

**Visual refs:** Climbing Dashboard UI (Jack Willis) https://dribbble.com/shots/14287138-Climbing-Dashboard-UI ·
Climbing Guide app feed https://dribbble.com/shots/11073691-Climbing-Guide-app-the-feed ·
calendar heat-map tag https://dribbble.com/tags/calendar_heat_map ·
activity-history tag https://dribbble.com/tags/activity-history ·
fitness-calendar https://dribbble.com/search/fitness-calendar ·
Strava Android Fitness Progress (Mobbin) https://mobbin.com/explore/screens/852f7ee0-07a6-45cf-8111-ccad12d6e7fc

---

## 3. Climbing analytics & premium fitness dashboards

**Patterns adopted (Flow 3):**
- **Score-first hero numeral** (Whoop ~72pt; 8a-style climber level). → the Climbing-Level hero.
- **Grade pyramid (ordered horizontal bars), the signature climbing viz.** → promoted to Swift Charts,
  segmented by style.
- **Intensity/effort zones relative to YOUR max** (Kaya): warmup/moderate/hard/limit. → intensity band.
- **Ring/arc gauges** for bounded ratios (send rate, flash rate). → the two rings.
- **Attempts-to-send / velocity** trending down = improving. → velocity stat.
- **Week-over-week deltas with a ghost prior trace** (Whoop/Hevy/Strava). → "vs previous period".
- **Trend bars + range chips** (30d/3m/1y/all, Hevy). → tier-2 trend screen.
- **Angle distribution** — a uniquely-Kilter dimension never aggregated today. → angle module.

**Grade-pyramid color/accessibility (critical, drives design rule 6):** grades are an **ordinal** sequence —
do **not** assign one categorical hue per grade. Encode order by **position** (ascending rows) + an explicit
**grade label** on every bar, banded by a single ramp. Encode ascent **style** (flash/send/project — a
*nominal* category) by the **Wong/Okabe-Ito** palette **plus pattern + label**, never hue alone. Keep WCAG
contrast on labels; never let the red/green perf ramp carry meaning without an icon/label.

**Reference apps:** Whoop (hero + strict 3-color semantics + 3-tier disclosure) · Hevy (range chips +
compare-to-previous + per-exercise progression) · Strava (Relative Effort this-week-vs-last; *redesign
backlash caution* — keep stats dominant) · Gentler Streak (kind framing) · Kaya (ascent pyramid + intensity
zones) · 8a.nu/Vertical-Life (scorecard + style weighting) · Lattice/Crimpd (benchmark-vs-population).

**Citations:** https://www.925studios.co/blog/whoop-design-breakdown ·
https://www.whoop.com/us/en/thelocker/track-progress-with-new-trend-views/ ·
https://www.hevyapp.com/features/gym-progress/ ·
https://support.strava.com/hc/en-us/articles/360032451811-Fitness ·
https://docs.gentler.app/understanding-your-activity-path/interpret-the-activity-path ·
https://support.kayaclimb.com/support/solutions/articles/61000297882-kaya-pro-performance-analytics-explained ·
https://kayaclimb.com/blog/intensity-zones · https://medium.com/@buckthecanuck/climb-through-the-data-with-me-80fb144ea408

**Visual refs:** Mobbin Progress library https://mobbin.com/explore/mobile/screens/progress ·
Strava iOS Workout Stats https://mobbin.com/explore/screens/9827c10a-8c85-4fa3-af72-f65bbbfd50cc ·
analytics-dashboard tag https://dribbble.com/tags/analytics-dashboard ·
Pinterest climbing grade-pyramid https://www.pinterest.com/search/pins/?q=climbing%20grade%20pyramid%20stats%20app

---

## 4. "Climbs you set" / setter-log galleries (Flow 2)

**Patterns adopted:**
- **Setter-scoped "Climbs" list** — every problem you authored in one place; promote it from a filter to a
  first-class destination.
- **Board-thumbnail as the card hero** — the lit-holds render is the climb's identity → 2-up thumbnail grid.
- **Draft vs Saved status** with revert-to-draft (Kilter/Stōkt). → status segment (prefer *deriving* Draft).
- **Delete guarded by "has anyone climbed it"** (Kilter/Stōkt). → on-device analog: delete **keeps your
  logged ascents** (`KilterCreatedClimb.delete`).
- **Editable metadata, immutable-ish identity** (Stōkt: edit name/grade). → Edit re-opens the editor.
- **Per-climb stat card** (grade, angle, hold count, provenance) — but **local data only**: no community
  ascents/quality (none exist on-device).

**Reference apps:** Kilter/Aurora (+ button → tap holds; draft→published; "Reclaim the boulders you
created") · Stōkt (set-and-publish; edit name/grade) · Tension Board 2 (Aurora authoring + Workout-AI from
logbook) · TopLogger/Climbing Studio/Vertical-Life (setter logs, build dates, QR) · Kaya (logbook counter).

**Citations:** https://kilterboard.io/support ·
https://climbingbusinessjournal.com/new-kilter-board-app-reclaim-the-boulders-you-created/ ·
https://www.getstokt.com/faqs · https://apps.apple.com/us/app/tension-board-2/id1488028660 ·
https://climbingbusinessjournal.com/apps-for-routesetting-management-in-2022/ ·
empty-state UX https://mobbin.com/glossary/empty-state · filter/sort https://mobbin.com/explore/mobile/screens/filter-sort

**Visual refs:** climbing-app tag https://dribbble.com/tags/climbing_app ·
masonry gallery (2-up thumbnails) https://dribbble.com/tags/masonry_photo_gallery ·
status toggle filters https://dribbble.com/shots/11729129-Status-toggle-filters ·
portfolio app ("my creations") https://dribbble.com/tags/portfolio_app ·
route metadata as pills https://dribbble.com/shots/5569645-AR-Concept-app-Climbing

---

## 5. Premium dark-mode visual language (Pulse Pro, all flows)

**Do's:** spend coral like cash (one moment per screen) · keep the two color systems air-gapped (amber =
wayfinding, perf ramp = effort/state) · warm-neutral paper (`#121214`/`#1E1E22`), **not** pure black, with
**fully-saturated** accents · glass **only** on floating chrome over something rich · band the grade pyramid
and HR zones with the single ramp, crowned by one hero · role-coded holds + explicit colorblind safety.

**Don'ts:** don't paint full cards in an accent (accents are dots/edge-bars/badges/hairlines/numerals) ·
don't desaturate accents to match the neutral · don't put glass over empty paper (it muddies) · don't
over-rainbow analytics (the Strava-redesign backlash) · don't rely on hue alone for meaning.

**Reference apps:** Whoop (dark, data-dense, one hero, strict semantics) · Kaya (ascent pyramid, intensity
zones, board viz) · Apple Fitness (rings-hero → workouts → trends scaffold) · Gentler Streak (warm, humane,
forgiving) · Future (consistency calendar) · Kilter app (role-coded holds + colorblind mode) · SwiftClimb
(heatmaps + pyramid + skills radar).

**Citations:** https://www.925studios.co/blog/whoop-design-breakdown ·
https://www.whoop.com/us/en/thelocker/the-all-new-whoop-home-screen/ ·
https://kayaclimb.com/features-home · http://andrewbergan.com/2018/02/24/visualizing-my-climbing-route-pyramid.html ·
https://www.usebould.com/best-climbing-apps

**Visual refs (Mobbin — "what shipped, not what's pretty"):**
Apple Fitness summary https://mobbin.com/explore/screens/f8ca0d70-c83d-41de-94d0-2c45cd3c266d ·
Strava iOS Workout Stats https://mobbin.com/explore/screens/9827c10a-8c85-4fa3-af72-f65bbbfd50cc ·
Future Workout Overview (consistency calendar) https://mobbin.com/explore/screens/7a7d0256-2454-4e34-88da-fce5571d6686 ·
Mobbin dark-mode gallery https://mobbin.com/explore/web/screens/dark-mode

---

## 6. Grounding in existing Snappet code + prior research

- Tokens to extend (no rebrand): `ios/App/Snappet/DesignSystem/SnappetColor.swift` — kilter accent
  (`0xB45309`/`0xF59E0B`), perf ramp (`perfFresh`/`perfModerate`/`perfHard`), brand coral
  (`0xFF5A4D`/`0xFF7A6B`), paper `0x121214`.
- Prior research to build on: `docs/ux-research/workout-redesign/` (Pulse Pro foundation, grade-pyramid,
  visual language) and `docs/ux-research/quick-session-redesign/` (climb entity-then-attempt model).
- The keystone engine already exists and is tested: `KilterSessionStats` + `KilterSessionStatsTests`.
- The board-memory template already exists and is tested: `BandMemory` + `BLEBands` (the
  [[fitness-band-richness-roadmap]] work).

*Every external claim above was used only to inform design; every code claim in the README was checked
against source at the cited `file:line`.*
