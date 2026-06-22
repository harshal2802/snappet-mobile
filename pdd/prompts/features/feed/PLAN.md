# PLAN — Recap Feed (a self-composing session feed + social-ready activity graph)

**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift / SwiftUI) lead + Android (Kotlin / Compose) parity wave — code lands in this repo.
**Source**: GitHub epic "Recap Feed — self-composing session feed + social-ready activity graph" + child issues F0–F7 (iOS) / FA0–FA5 (Android).
**Design**: `/tmp/feed-dossier/_locked-design.md` (locked spec) → `docs/ux-research/feed/README.md` + `wireframes.html`.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## The keystone

`FeedComposer` + the `FeedCard` value type + the per-card `eligibility(predicate) -> Bool` / `salience(score) -> Double` registry — **pure, Foundation/Kotlin-stdlib only, golden-vector-tested across iOS↔Android, with ZERO UI and ZERO store** (`_locked-design.md:19`). Exactly as `KilterAllTimeStats` was the keystone for the Kilter initiative: it is the single artifact every other phase renders. It is *the engagement engine* (eligibility decides what unlocks, `salience × recencyDecay` decides order), *the graceful-degradation mechanism* (a card needing `hrSeries`/`SessionMedia` the platform lacks is never emitted — no greyed buttons, no "coming soon" stubs), and *the one caller behind two surfaces* (the infinite feed calls `compose(window: allTime)`; the Story Player calls `compose(window: thisWeek/thisMonth/thisYear)`) (`_locked-design.md:21-28`). It reuses, never reinvents — consuming `KilterAllTimeStats`, `KilterSessionStats`, `HRStats`, `HRVMetrics`, `ReelRanking` verbatim and only *surfacing* their numbers.

The **companion keystone** (same wave, separate PR) is the **`FeedActivity` persisted append-only log + `Reaction`/`SaveItem`/`ShareEvent` interaction rows + outbox** — the AS2-shaped backbone with dormant social columns (`_locked-design.md:29`, `83-114`). The composer reads activities and *dereferences* to the rich models; it never duplicates their data.

## The synthesis (why this shape)

Per the locked spec (`_locked-design.md:11-13`): **B is the spine** (self-composing intelligence = the engagement engine), **C is the foundation** (the append-only AS2 activity log + first-class interaction rows = the social insurance), **A is the texture** (the comfortable chronological session stream, the iOS inline auto-clip wow, the masonry "send wall"). The one override: **v1 derives session/insight *cards* ON READ (A's `TodayDigest` pattern) — no card migration — but we DO persist the thin `FeedActivity` log + interaction rows from day one (C)**, because deferring the log "guarantees the redesign the lens exists to prevent." Salience is kept but **recency-bounded** (a card never floats older than its trigger) and a chronological "Sessions-only" lens is always available.

## The chain

One PDD prompt = one PR. Each ships its committed feature prompt, keeps `pdd/context/` true, records decisions in `pdd/context/decisions.md` the same day, and updates `docs/knowledge-graph/data.js` (add `tab-feed` / `feed` / `feed-composer` / `feed-activity` / `story-player` / `feed-export` / `wall` nodes + `contains` / `navigate` / `uses` / `feeds` edges) **in the same change** (`_locked-design.md:254`).

### Wave 0 — Pure foundations (the keystone; shared, no UI, no surfaces)

| Phase | Prompt | Depends on |
|-------|--------|------------|
| **F0 (KEYSTONE)** | [F0-feedcomposer-keystone.md](./F0-feedcomposer-keystone.md) — pure `FeedCard` / `FeedCardKind` / `FeedCategory` + `FeedComposer.compose(...)` with the eligibility/salience registry; session + PR + streak + pyramid + volume cards (no HR/media yet); recency-bounded salience. Unit-tested, **iOS↔Android golden corpus**. No UI, no store. | — |
| **F0b** | [F0b-feedactivity-log.md](./F0b-feedactivity-log.md) — `FeedActivity` `@Model` + `Reaction` / `SaveItem` / `ShareEvent` rows + UUIDv5 namespaces + canonicalized `contentId` golden-vector + empty outbox table (additive SwiftData migration). Append-only writers hooked into session-finish / climb-log. | F0 |

### Wave 1 — iOS feed (lead platform)

| Phase | Prompt | Depends on |
|-------|--------|------------|
| **F1** | [F1-ios-feedview.md](./F1-ios-feedview.md) — `FeedView` shell + tab wiring (`SuiteTab.feed`, `RootShell` `TabView`) + `LazyVStack` + a1/a2 session cards on Pulse Pro + keyset `(published,id)` pagination + freshness kit (skeleton / optimistic-insert / "N new" pill / pull-to-refresh) + Lens bar + Sessions-only lens. | F0 |
| **F2** | F2-ios-hr-cards-detail.md — HR-deepened cards (e1/e2/e3) + `CardDetailView` (reuse `KilterSessionStats` / HR zone chart) + inline reactions/save (double-tap / long-press) + deep-link to source module. | F1 |
| **F3** | F3-ios-inline-autoclip.md — inline media auto-clip (single active `AVPlayer` nearest viewport center) from `SessionMedia`; media-first hero fallback chain. | F1 |
| **F3b** | F3b-ios-media-carousel.md — Instagram-style carousel of ALL session media (not just the highlight): swipeable card carousel + grouped browser (`By exercise · By session · All` over `assignedExerciseID`/`assignedClimbUUID`) + fullscreen viewer, each clip with a per-clip HR overlay (aligned via `offsetSec`) + name tag. Issue #227. *(added on review)* | F3 |
| **F4** | F4-ios-sharecomposer.md — `ShareComposerCover` + named template library (image, 9:16/4:5) → `ShareSheet`; **Animate** path (`clipReady` → `ReelExporter` HR-overlay burn, structured tag refs); append `ShareEvent`. | F2, F3 |
| **F5** | F5-ios-milestone-cards.md — synthetic cards wave-1 (a3 / b1–b5 / streak) — predicates in `FeedComposer`. | F1 |
| **F6** | F6-ios-story-player.md — `RecapStoryCover` (Wrapped grammar) + Stories rail + weekly/monthly/Year-in-Climb + remaining insight cards (c2–c5 / d1–d4 / e4–e5 / consistency / restNudge / onThisDay / g1). | F5 |
| **F7** | F7-ios-wall.md — `WallView` masonry send-wall + grid toggle. | F1 |

### Wave 2 — Android parity

| Phase | Prompt | Depends on |
|-------|--------|------------|
| **FA0** | FA0-android-feedcomposer-port.md — Kotlin port of `FeedComposer` / `FeedCard` / eligibility against the shared golden corpus (JVM-tested). | F0 |
| **FA0b** | FA0b-android-pulsecard-feedactivity.md — `pulseCard()` Compose modifier (shared primitive) + `FeedActivity` Room `@Entity` (v7→v8 additive migration) + interaction rows + outbox + write seam. | F0b, FA0 |
| **FA1** | FA1-android-feedscreen.md — `FeedScreen` shell + `RootShell.kt` third tab + `LazyColumn` + session cards + Paging 3 keyset + freshness kit + Lens bar. | FA0, FA0b |
| **FA2** | FA2-android-hr-summary-detail.md — HR summary cards (e1-summary / e3) + `CardDetailScreen` + reactions/save + deep-link. | FA1 |
| **FA3** | FA3-android-image-share.md — `ShareComposerScreen` (image templates only → `ACTION_SEND`); reel entry routes to Stage-0 `ReelRoot`. | FA1 |
| **FA4** | FA4-android-milestones-story.md — synthetic cards wave-1 (non-HR / non-media) + Story Player + Stories rail (eligible scenes only; media/zone scenes auto-skip). | FA1 |
| **FA5** | FA5-android-wall.md — `WallScreen` (`LazyVerticalStaggeredGrid`). | FA1 |

## Sequencing & ordering rationale

- **F0 first, always.** It is the spine every surface renders (`_locked-design.md:21`). Get it tested and golden-corpus-locked before any pixel. F0b follows F0 because the activity writers reference the same UUIDv5 namespaces and `contentId` canonicalization F0 establishes.
- **iOS wave then Android wave** (lead platform first, per repo convention). The shared spine (F0/F0b) is proven on the golden corpus once; FA0/FA0b *port* it against the same corpus — no re-design.
- **F1 is the gate for F2–F7.** It owns the tab insertion (`SuiteTab.feed`, `RootShell.swift:160-169`), the scroll backbone, the keyset cursor, and the freshness kit; everything downstream renders into it.
- **F2 ∥ F3 ∥ F5 ∥ F7 are independent after F1** — HR-detail, inline media, synthetic cards, and the Wall touch different files and can run in parallel. **F4 depends on F2+F3** (the Animate path needs both the detail share entry and the `clipReady` media plumbing). **F6 depends on F5** (the Story Player re-runs the same predicate registry the milestone cards populate).
- **Android mirrors the iOS dependency graph** one phase behind: FA1 gates FA2–FA5; FA2 ∥ FA3 ∥ FA4 ∥ FA5 after it.
- **Story Player (F6/FA4) is highest-wow / highest-execution-risk** (`_locked-design.md:286`): wireframe + prototype it FIRST per the wireframe-before-implementation rule; ship per-scene shareability so a 3-scene sparse story still feels complete.

## Scope guards (every phase — from `_locked-design.md:283`)

- **No backend, no accounts, no network, no real likes/comments/followers, no fan-out worker** (the outbox table is created but **stays empty**, drained by nobody). `actorRef="self"`, `visibility="private"` — the social columns are **provisioned but dormant**.
- **No Android reel/clip device pipeline** (Stage-0 `ReelRoot` only; deferred Media3 Transformer wave). **No Android workout HR at all** → workout-effort cards are **hard-gated iOS-only** (`_locked-design.md:217`).
- **`FeedCard` stays derive-on-read — NO card-table migration, ever.** Only the thin `FeedActivity` log + interaction rows + outbox are persisted (additive SwiftData / Room v7→v8, strictly additive: new tables, no column drops) (`_locked-design.md:293`).
- **"Share" = export to the OS share sheet only** (`UIActivityViewController` / `ACTION_SEND` / IG Stories sticker). **Music omitted** from any muxed clip (clean handoff). **No in-app music.**
- **Recency-bound every card** (never older than its trigger); always keep a chronological "Sessions-only" lens. **No banded memoization** unless profiling demands it — v1 keeps composition simple and temporal (`_locked-design.md:219`).
- **Cross-platform `contentId` uses shared fields ONLY.** `KilterLogEntry` has no stable id on Android (`autoGenerate` Long) — per-send `contentId` canonicalizes `(climbUuid, difficulty, statusRaw, dayBucket(date), sessionId?)`, **never the row id**, or dedup breaks across devices (`_locked-design.md:140`).
- **Pure cores stay platform-free** value types, unit-tested without a simulator. Platform I/O (AVFoundation export, share sheet, Photos, BLE) lives behind the Services edge. `HighlightEngine` stays platform-free.
- **State verification honestly:** type-check ≠ device run. Sharing / auto-clip export / IG handoff are **device-burn items** (sim-untestable; Apple cropping bug mitigated by rendering at exact 9:16/4:5, off-main-thread with cancellable progress).
- **No muscle-tagging cards** (D3/D4 muscle-balance need new capture); **no HRV/recovery on Android** (e5 iOS-only until chest-strap RR is mainstream).