# Prompt: F0b — FeedActivity append-only log + interaction rows + outbox (additive persistence)

**File**: pdd/prompts/features/feed/F0b-feedactivity-log.md
**Created**: 2026-06-20
**Project type**: Native iOS feature (Swift / SwiftData; additive lightweight migration). Android Room mirror is FA0b.
**Chain**: PLAN.md → F0b (companion keystone; depends on F0)
**Source**: GitHub epic "Recap Feed" → issue "F0b FeedActivity log + interaction rows + outbox"
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Schema**: `pdd/context/snappet-core-schema.md`
**Design**: `/tmp/feed-dossier/_locked-design.md` §4.1 (`FeedActivity`), §4.4 (UUIDv5), §4.5 (social seams), §10 (migration risk)

## Goal

Persist the **social-ready foundation** the locked spec demands from day one: a thin, **append-only, AS2-shaped `FeedActivity` log** plus first-class **`Reaction` / `SaveItem` / `ShareEvent`** interaction rows and an **empty outbox** table — all with **provisioned-but-dormant** social columns (`actorRef="self"`, `visibility="private"`, `audienceTo=[]`) (`_locked-design.md:29`, `83-114`). This is the "C foundation" that makes "personal-now" become "social-ready" with **zero card-view rewrite** later. We persist the log even though `FeedCard` stays derive-on-read, because the social-ready judge is right that deferring it "guarantees the redesign the lens exists to prevent" (`_locked-design.md:13`). F0b also pins the **UUIDv5 content-identity scheme** (the cross-device dedup seam) with a golden-vector test, and hooks append-only writers into session-finish / climb-log so the log fills as the user climbs.

## Context the implementer needs

- The persisted schema is `SnappetSchema.models` in `SnappetCore.swift` (`ios_models.md:481-489`, `:514`). Adding a model pays the schema-registration + `SnappetBackup` mirror tax, and both backup tripwires must stay green (`testCodecCoversEverySchemaModel` + the count tripwire — the Kilter P4 prompt documents this pattern, `kilter-improvement/P4-session-history.md`). The migration is **lightweight / additive only** (new models + new tables; no column drops — `ios_models.md:500`, `552`; `_locked-design.md:293`).
- `FeedActivity` fields (verbatim from `_locked-design.md:86-103`): `id: UUID` (v4/v7, the repeatable activity row id), `contentId: String` (UUIDv5 stable content identity for cross-device dedup), `actorRef: String = "self"` (**the social flip point**), `verb: String` (`sent | flashed | loggedSession | hitPR | extendedStreak | recap | createdClimb | litBoard | sharedClip | correctedSend`), `objectRef: String` (FK → `KilterSession.id` / `WorkoutSession.id` / `climbUUID`), `objectKind: String` (`kilterSession | workoutSession | climb | clip | litEvent | aggregate`), `targetRef: String?`, `published: Date` (ordering + dedup + **keyset cursor key**), `visibility: String = "private"` (dormant), `audienceTo: [String] = []` (dormant structured people-tags), `foreignId: String = "\(verb):\(contentId)"` (idempotency key), `aggregationKey: String = "\(targetRef):\(verb):\(objectKind):\(weekBucket)"` ("X & 3 others" later), `updatedAt: Date` (LWW), `version: Int = 1`, `schemaVersion: Int = 1`.
- Interaction rows (separate append-only rows — `_locked-design.md:106-110`): `Reaction { id, activityContentId, actorRef:"self", type:emoji|note, createdAt }`, `SaveItem { id, activityContentId, collectionId, createdAt }`, `ShareEvent { id, activityContentId, channel:"export:instagram"|"export:imessage"|"user:<id>", createdAt }`. **`channel` is the seam:** `export:*` today, `user:*` tomorrow — the table shape never changes. Reactions are **private memory/curation** ("react-as-note to your own On-This-Day"), not hollow social likes (`_locked-design.md:111`, `292`).
- **Outbox table:** created **empty now, drained by nobody** — retrofitting an outbox onto live data is painful, so we pay the tiny cost up front (`_locked-design.md:113`, `283`).
- **UUIDv5 scheme** (`_locked-design.md:138-140`): pinned per-type namespaces, never changed — `NS_FEEDITEM`, `NS_SESSION`, `NS_CLIMB`, `NS_CLIP`. Inputs are **canonicalized** (normalize unicode, trim, fixed field order, fixed units) and built **only from fields shared by both platforms**. **Critical gotcha:** `KilterLogEntry` has no stable id on Android (`autoGenerate` Long) — a per-send `contentId` must canonicalize `(climbUuid, difficulty, statusRaw, dayBucket(date), sessionId?)`, **never the row id**, or dedup breaks across devices. Reuse/extend the existing `KilterCreatedClimb` golden-vector test discipline.
- Write seams: session-finish lifecycle is `KilterSessionManager.end/recover` (Kilter) and the workout session-complete path; the per-send write fires on `KilterLogEntry` creation. Writers are **append-only and idempotent** via `foreignId` — re-running never duplicates (`_locked-design.md:98`, mirrors the `FeedProjector` idempotency note `_direction-C.md:196`).

## Approach

- Add `ios/App/Snappet/Features/Feed/FeedActivity.swift` — the `FeedActivity` `@Model` + the `Reaction` / `SaveItem` / `ShareEvent` `@Model` rows + the empty `FeedOutboxEntry` `@Model`, all with the exact field names/defaults above (so the Kotlin data classes in FA0b match 1:1).
- Add `ios/App/Snappet/Features/Feed/FeedContentIdentity.swift` — a **pure** UUIDv5 helper: the pinned namespaces + canonicalization (unicode-normalize, trim, fixed field order, fixed units) + the per-verb `contentId` builders (session, per-send, climb, clip), using **shared fields only** and **never** the Android-unstable row id. This file is platform-free (no SwiftData import) so FA0b ports it verbatim.
- Register the four new models in `SnappetSchema.models` (`SnappetCore.swift`) and add their `SnappetBackup` Row/File/recordCount/snapshot/restore mirrors (enum raw strings mirrored verbatim) so both backup tripwires stay green.
- Add an `ios/App/Snappet/Services/FeedActivityWriter.swift` (the platform/store edge) with append-only, `foreignId`-idempotent `record(...)` calls, hooked into the Kilter session-finish (`KilterSessionManager.end/recover`) and per-send-log seams and the workout session-complete seam. Reaction/SaveItem/ShareEvent writers exist but their UI callers arrive in F2/F4.
- Keep `FeedCard` **derive-on-read** — F0b adds **no card table** and does not change F0's composer beyond letting it `dereference` activities to the rich models via `objectRef`/`objectKind` (`_locked-design.md:29`, `81`).

## Output

- `FeedActivity.swift` — `FeedActivity` + `Reaction` + `SaveItem` + `ShareEvent` + `FeedOutboxEntry` `@Model`s.
- `FeedContentIdentity.swift` — pure UUIDv5 namespaces + canonicalization + per-verb `contentId` builders.
- `SnappetCore.swift` schema registration + `SnappetBackup` mirrors for all four new models.
- `Services/FeedActivityWriter.swift` — append-only idempotent writers wired into session-finish / per-send / workout-complete.
- `SnappetTests/FeedContentIdentityTests.swift` — the UUIDv5 **golden-vector** test (a fixed canonical input → a fixed UUID, cross-platform, reusing the `KilterCreatedClimb` discipline), including the no-stable-id per-send case.
- `SnappetTests/FeedActivityLogTests.swift` — append-only + `foreignId` idempotency + migration-decode tests.
- `docs/knowledge-graph/data.js` — add the `feed-activity` node (type: store) + `feeds`/`uses` edges (composer → dereferences activity; writers → append).

## Acceptance criteria

- [ ] `FeedActivity` + `Reaction` + `SaveItem` + `ShareEvent` + an **empty** `FeedOutboxEntry` persist with the exact field names/defaults from `_locked-design.md:86-110`; `actorRef="self"`, `visibility="private"`, `audienceTo=[]` are present **but dormant** (no UI reads them).
- [ ] The UUIDv5 golden-vector test pins `NS_FEEDITEM`/`NS_SESSION`/`NS_CLIMB`/`NS_CLIP` and produces a fixed UUID from a fixed canonical input; the **per-send `contentId` derives from `(climbUuid, difficulty, statusRaw, dayBucket, sessionId?)` and NEVER from the row id** — proven by a test that two different row ids with identical send facts yield the same `contentId`.
- [ ] Append-only writers are wired into Kilter session-finish, per-send-log, and workout-complete; re-running a write is **idempotent via `foreignId`** (no duplicate rows) — proven by a replay test.
- [ ] The migration is **strictly additive** (new models/tables only); a pre-change store opens cleanly; the four new models round-trip through `SnappetBackup`; `SnappetBackupTests.testCodecCoversEverySchemaModel` + the count tripwire stay green.
- [ ] `FeedContentIdentity.swift` imports no SwiftData/UIKit (pure, portable to Kotlin). **No card table added** — `FeedCard` stays derive-on-read.
- [ ] App type-checks (Swift 6, 0 warnings). `decisions.md` updated (the dormant-social-columns rationale + the no-row-id contentId gotcha).

## Constraints

- On-device only; additive lightweight migration only — no destructive schema change, no column drops. Enum raw strings mirrored verbatim in the backup Row.
- Outbox stays empty (drained by nobody); social columns provisioned but never read in v1. "Share" channels are `export:*` only.
- `contentId` inputs use shared fields only; the canonicalization must be byte-identical to FA0b's Kotlin port (golden vector is the contract).

## Test plan

1. Unit: `FeedContentIdentityTests` golden vectors + the no-row-id per-send equivalence; `FeedActivityLogTests` append-only/idempotency; the additive-migration decode + backup round-trip; both backup tripwires green; build-for-testing.
2. Sanity: finish a fixture Kilter session in a test harness, assert exactly one `FeedActivity` per event with a stable `foreignId`, and that re-finishing (recovery path) adds no duplicate. Sim wedge → `xcrun simctl shutdown all`.