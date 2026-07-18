# Festival — dance + video tagging for music-festival lineups

**Created**: 2026-07-16 · **Status**: 01 merged (#292) · 02 merged (#293) · 03 merged (#294, tagging + Clips) · 04 implemented (plan & smart nudges)
**Wireframes** (user-approved end state, 14 frames): `docs/ux-research/festival/wireframes.html`
**Decision record**: `pdd/context/decisions.md` § 2026-07-16

## The shape (decided at ideation — do not relitigate)

A **Festival mini-app** that owns the lineup *domain* (festivals → days → stages → sets), while all
capture rides the existing workout spine — the **Kilter shape, not the Wardrobe shape**:

- Lineups install like the Kilter climb catalog: `.fpack` packs (gzipped JSON, ~tens of KB) hosted on
  the Snappet Pages site at **`https://harshal2802.github.io/Snappet/music-festivals/`** (sibling of
  `board-data/`; the Pages site gets its own PR in the web-app repo). Provider→validator→store, one
  user-initiated GET, offline forever after — festivals have no signal.
- Being at a set is a **dance-discipline `WorkoutSession`** (watch HR, Live Activity, media
  assignment #283) — the mini-app never grows its own capture/HR/media stack.
- Tagging is **time-window overlap**: a set is an interval, every clip has a timestamp. The pure
  `FestivalSetMatcher` auto-tags with confidence; ambiguity is surfaced, never silently guessed.
- Payoff lands in the shared surfaces: artist·stage-titled Clips posts (existing search matches
  artists free), one 🎪 feed chip, set/festival reels through the shared `ReelView`, recap with
  artists ranked by *your HR*.
- ★ starred sets = "my plan" → local pre-set notifications (lead time + walk hint, offline), clash
  detection, a shareable plan QR (`SnappetShareable` stack), and a For-You sheet: pure
  `SetRecommender` ranking + on-device Foundation Models writing **only the reason lines** (E7
  contract: heuristic floor, FM refines, silent degradation).

## Prompt chain (one prompt = one job = one PR)

| # | Prompt | Scope | Status |
|---|--------|-------|--------|
| 01 | `01-festival-domain-and-matcher.md` | Pure domain: `.fpack` wire codec + validator, set/clash math, `FestivalSetMatcher` with confidence. No UI, no SwiftData. | **merged #292** |
| 02 | `02-festival-shell-and-install.md` | `AppModule` + UV-orchid accent, catalog install (empty state / browse / hosted provider), SwiftData models + backup Rows, day schedule, "I'm here" live sheet on the dance-session spine. Companion PR on the web-app repo: `music-festivals/` packs page. | **merged #293** |
| 03 | `03-festival-tagging-and-clips.md` | Matcher wired to session media, tag-review timeline sheet, artist·stage Clips posts + 🎪 chip, set detail (HR curve, peak-at-drop), set/festival reels via shared `ReelView`, recap. | **merged #294** |
| 04 | `04-festival-plan-and-nudges.md` | ★ plan, `UNUserNotificationCenter` reminders + clash alerts, pure `SetRecommender`, For-You sheet with FM reason lines. | **implemented** |
| 05 | QR lineup sharing | `SharedLineup: SnappetShareable` (deflate blob ⇄ install-link fallback, `SharedRoutine` pattern), share sheet, scanner + `snappet://festival/…` routes. | queued |
| 06 | poster scan (optional) | Lineup-poster photo → on-device FM structuring → draft pack. | later |

Device legs owed at the end (record in memory + decisions): notifications timing in the field,
watch-HR during a real set, camera-app clip discovery, QR scan phone-to-phone.
