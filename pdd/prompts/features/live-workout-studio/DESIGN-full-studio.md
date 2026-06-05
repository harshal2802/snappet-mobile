# Design Review: Per-Set Media + Full CapCut-Style Studio

**Created**: 2026-06-03
**Type**: PDD Research + Plan (deep design review → decomposed prompt chain).
**Status**: design complete; device-profiling spike (S0) pending before committing the heavy compositor.
**Supersedes / extends**: [`B1-session-media-tagging.md`](./B1-session-media-tagging.md) (adds per-set
assignment) and [`B3-clip-editor.md`](./B3-clip-editor.md) (the single-clip editor becomes the one-clip
case of a full timeline studio). Reads on top of [`RESEARCH.md`](./RESEARCH.md) and [`PLAN.md`](./PLAN.md).
**User direction (2026-06-03)**: per-**set** media with reassignment + a non-set **General** bucket ·
**full CapCut parity** editor · capture = **library auto-discover + picker** (no in-app camera) ·
"as smooth as possible".

---

## 0. Where we already are (don't rebuild this)

The `live-workout-studio` initiative already shipped a *session-level* media + editing pipeline:

| Built | File | What it does |
|---|---|---|
| `SessionMedia` `@Model` | `Features/WorkoutTracker/SessionMedia.swift` | One row per tagged photo/video, keyed to `WorkoutSession.id` by `offsetSec` (capture time). **No set link.** |
| Auto-discovery + picker | `Services/SessionMediaService.swift`, `MediaPicker.swift` | PHAssets in `[startedAt, completedAt] ± 90 s` → session-relative offsets; manual PHPicker add. Pure mapping is unit-tested. |
| `ClipEdit` `@Model` (B3) | `Features/WorkoutTracker/ClipEdit.swift` | Non-destructive single-clip edit list: trim/split, crop, aspect, speed, text overlays, mute/music. |
| `VideoStudio` service | `Services/VideoStudio.swift` | Builds `(AVMutableComposition, AVMutableVideoComposition)` from a `ClipEdit` snapshot — **shared** by preview (`AVPlayer`) and export (`AVAssetExportSession`). Overlays via `AVVideoCompositionCoreAnimationTool`. |
| Pure geometry | `Features/WorkoutTracker/ClipEditGeometry.swift` | Render-size, trim window, crop transform, overlay layer-point — no AVFoundation, unit-testable. |
| Editor UI | `ClipEditorView.swift` + `ClipEditorViewModel.swift` | Sheet; live preview rebuilt on every edit; split; export → share / save-to-Photos. |
| Engine bridge (B4) | `SessionHighlightInput.swift` (pure) + `SessionHighlightView.swift` | Session HR + tagged clips → `HighlightEngine` → reel. |

**Two gaps the user is asking us to close:**
1. Media is **session-scoped, never set-scoped** — there is no way to say "this clip is Set 3 of Bench."
2. The editor is a **single-clip** tool. CapCut is a **multi-clip timeline** with filters, transitions,
   keyframes, layered overlays, multi-track audio, captions, masks — a different architecture, not a
   bigger version of `ClipEdit`.

Everything below extends the existing pieces; it does not start from scratch.

---

## Part 1 — Per-set media attachment

### 1.1 The data-model decision

`SessionMedia` stays the single source of truth for "a clip belongs to this session." We make it
**also** carry an optional set assignment — additive fields, a SwiftData lightweight migration (the
`hrSeries` / Journal-`tags` precedent), so existing rows decode unchanged and land in **General**:

```swift
// added to SessionMedia (all optional / defaulted → additive migration, SnappetSchema.models unchanged)
var assignedExerciseID: UUID?     // FK to SessionExercise.id; nil = General (not tied to a set)
var assignedSetIndex: Int?        // index into that exercise's `sets`; nil with an exerciseID = "exercise, no specific set"
var assignmentSourceRaw: String   // "auto" | "manual" | "general"  (see §1.3 — why we need this)
```

**Why reference a set by `(exerciseID, setIndex)` and not a `SetLog.id`:** `SessionExercise` already has
a stable `id: UUID` (it's `Identifiable`); `SetLog` does **not** have an id — it's a small positional
`Codable` value inside `SessionExercise.sets`. Sets are append-only during a live session and are not
reordered, so the index is stable in practice and needs **no** model change to `SetLog`. Adding
`SetLog.id` is the theoretically-cleaner FK but carries a real migration hazard: a `Codable` default
`var id = UUID()` mints a *fresh* id on every decode of old data until it's re-saved, which would
silently break any reference made before the first save. **Decision: assign by `(exerciseID, setIndex)`.**
(If a future feature reorders sets, revisit and add a persisted `SetLog.id` with a one-time backfill —
recorded here so it isn't re-litigated.)

`General` (no set) is simply `assignedExerciseID == nil`. The user's "general section which can't be
attached to any set" is the natural home for warm-ups, the post-workout selfie, gym B-roll, or anything
the auto-assigner couldn't place.

### 1.2 Auto-assignment algorithm (pure, testable)

Because capture is **library auto-discover** (not in-app camera that stamps the set directly), we
*infer* the set from capture time. This is exactly the kind of pure decision logic the repo pushes to a
testable edge (the `SessionHighlightInput` / `ClipEditGeometry` pattern): a new pure file
`SessionMediaAssignment.swift` (no SwiftData / Photos / AVFoundation imports), unit-tested in
`SnappetTests`.

Algorithm:
1. Flatten every **completed** set across all exercises into one timeline ordered by `completedAt`
   (converted to session-relative offsets, the same axis as `SessionMedia.offsetSec` and `HRPoint.t`).
2. Each set *owns* the interval `(previousCompletion, thisCompletion]` — i.e. the work + the lead-in
   since the last set finished. A clip at offset `t` is assigned to the set whose interval contains `t`.
3. **Rest-period rule**: a clip filmed during the rest *after* a set belongs to the **set just
   completed** (the one you filmed), not the next set. Documented default; the user can reassign.
4. Clips before the first completion or after the last (beyond a small pad), or inside an unusually
   wide gap, get **General** with `assignmentSource = "auto"` and a **low-confidence** flag so the UI
   nudges a confirm.
5. Output is a pure value (`[mediaID: Assignment]`); the service layer writes it back to `SessionMedia`.

This runs (a) automatically right after post-session discovery, and (b) on demand if the user taps
"re-detect". It only ever (re)writes rows whose `assignmentSource == "auto"` — never clobbers a manual
choice (§1.3).

### 1.3 Reassignment & the `auto` / `manual` / `general` distinction

The user explicitly wants to **fix the app's mistakes** and **pin clips to General**. That needs three
provenance states, not a boolean:

- `auto` — placed by the algorithm; re-running auto-assign may move it; show a low-confidence badge when
  uncertain.
- `manual` — the user dragged/picked it onto a set; **auto-assign must never override it.**
- `general` — the user deliberately put it in General (distinct from "auto couldn't place it"); also
  sticky against auto-assign.

UX in `SessionDetailView` (rebuild the flat gallery into **grouped sections**):
- Sections in session order: each **exercise → its sets** that have media, then a **General** section.
  Empty sets show nothing; the section header is the exercise name + "Set _n_".
- Each clip: tap → preview / open studio; long-press or a "•••" menu → **Move to…** (a compact picker
  of exercises/sets + "General"), which sets `assignmentSource = "manual"`.
- Drag-and-drop a thumbnail between sections for the CapCut-smooth feel (phase it after the picker —
  picker first, drag as polish).
- Auto-assigned, low-confidence clips get a subtle badge ("Set 3? — confirm") so a wrong guess is one
  tap to fix, not hidden.

### 1.4 Richer "attach during the session"

Even with library-based capture, in-session attachment can feel first-class:
- In `WorkoutPlayerView`, after a set is marked complete, offer a quick **📎 "attach clip to this set"**
  affordance that opens the PHPicker **pre-scoped to the current set** → those rows are written `manual`
  immediately (no inference needed for the in-the-moment case).
- A small per-set **thumbnail strip** shows clips already discovered/attached to that set, live.
- Post-session, auto-discovery + auto-assign fills in everything filmed but not hand-attached; the user
  confirms/fixes in the grouped gallery.

### 1.5 Downstream benefit (no engine change)

Per-set assignment makes B4 highlight generation smarter for free: "use my best set" → pin that set's
clips; weight clips from high-HR sets. Still just `MediaItem`s + offsets + `pinnedIds` into
`HighlightEngine` — **no engine change**, honoring the platform-free rule.

---

## Part 2 — Full CapCut-parity studio

### 2.1 The architectural truth

Today's pipeline — *one* `ClipEdit` → `AVMutableComposition` + a **layer-instruction**
`AVMutableVideoComposition` + a `coreAnimationTool` overlay layer — cleanly covers trim/split, crop,
aspect, speed, text, and audio-mute. It **cannot** reach CapCut parity by accretion, because parity
needs three things the current design lacks:

- a **multi-clip, multi-track timeline document** (not a single clip),
- a **per-frame programmable renderer** (filters/LUTs, blends, custom transitions, keyframed effects,
  chroma key) — i.e. a custom `AVVideoCompositing`, which the layer-instruction path can't do, and
- a **real-time, low-latency preview** that doesn't rebuild the world on every keystroke.

So the studio is built on **three new pillars**, with the existing `VideoStudio`/`ClipEditGeometry`
generalized rather than thrown away.

### 2.2 Pillar A — `StudioProject`: the timeline document

A new `@Model StudioProject` is the edit document (non-destructive, resolution-independent — the same
philosophy as `ClipEdit`, generalized to many clips and tracks). Nested Codable composites mirror the
`WorkoutSession.exercises` / `ClipEdit.textOverlays` pattern; one new entry in `SnappetSchema.models`.

```
StudioProject (@Model)
├─ aspect / canvas size / background (color | blur-fill)        // global output
├─ mainTrack:  [TimelineClip]   // ordered; each = source ref + trim + speed + transform + filter + keyframes
├─ transitions: [Transition]    // between adjacent mainTrack clips (type + duration)
├─ overlays:    [OverlayItem]   // text / sticker / image / PiP-video; time range + keyframable transform
├─ audioTracks: [AudioTrack]    // original (per clip) | music | voiceover; volume/fade mix, time-placed
└─ outputSettings               // resolution / fps / format (reuses B5 export presets)
```

- **Source-agnostic clips**: a `TimelineClip` references a `SessionMedia` (video) **or** a photo
  (reuse `PhotoClipRenderer`'s Ken-Burns). Mixed photo+video on one track is the deferred
  "mixed-orientation normalization" gap — the project's single `renderSize` closes it.
- **Keyframes** are a first-class value type (`[Keyframe]` of `{ tOutputSec, value }` for
  position/scale/rotation/opacity/filter-param), interpolated by pure math in a `StudioGeometry` file
  (the `ClipEditGeometry` successor). Keyframes power overlay animation, Ken-Burns, and effect ramps
  with one model.
- **Migration of `ClipEdit`**: the existing single-clip editor becomes the **one-clip project** case.
  A `StudioProject.from(_ clipEdit:)` bridge (or a one-time conversion) preserves shipped edits; `B3`'s
  `ClipEditorView` is replaced by the new editor (§2.5). `ClipEdit` may remain as the lightweight
  "quick trim" path or be fully folded in — decide in S1.

### 2.3 Pillar B — the custom compositor (the heavy lift / main risk)

Introduce `StudioCompositor: AVVideoCompositing` (Core Image + Metal-backed `CIContext`). Per frame it:
composites the active main-track clip(s) (with a transition blending two during overlaps), applies the
clip's filter/LUT (`CIColorCube` for LUTs, `CIColorControls`/curve filters for adjustments), applies
keyframed transforms, then composites overlay/sticker/PiP layers and chroma-key/segmentation masks
(`VNGeneratePersonSegmentationRequest` for background removal). `VideoStudio.makeComposition` becomes a
**builder**: `StudioProject → (AVComposition, AVVideoComposition[customCompositor], AVAudioMix, CALayer
overlay tree)`. Text/animated stickers that don't need per-pixel sampling can stay on the cheaper
`coreAnimationTool` layer; pixel effects go through the compositor.

> **This is the make-or-break engineering.** It's well-trodden (every iOS editor does it) but it's the
> on-device perf risk already flagged as B3's device gate. **S0 spike** profiles it before we commit
> depth (see §2.7).

### 2.4 Pillar C — smoothness (this is what "as smooth as possible" actually means)

"Smooth" is about *interaction latency*, not export. Engineer it deliberately:

- **Incremental recomposition.** Today `ClipEditorViewModel.rebuild()` rebuilds the entire composition
  on *every* edit. At timeline scale that stutters. Split invalidation: an overlay/text/filter-param
  change updates the CALayer tree or compositor params **without** re-inserting tracks; only
  add/remove/trim/reorder/transition touches the `AVComposition`. Debounce rapid edits (e.g. dragging a
  slider) and coalesce.
- **Filmstrip + waveform caches.** Background `AVAssetImageGenerator` thumbnails and pre-rendered audio
  waveforms, cached per asset — the core CapCut timeline feel. Generate off the main actor; the
  `@Model` never crosses to the background task — snapshot to a Sendable `ProjectPlan` value first
  (generalizing the existing `EditPlan` pattern).
- **Direct-manipulation canvas.** Drag/pinch/rotate text & stickers **on the preview**, with snapping
  (center / edges / other items) and haptics; trim handles draggable at 60fps. Tools live in a
  context-sensitive bottom panel, not modal sheets.
- **Optimistic + async preview.** Model edits apply instantly (undo/redo stack); the player catches up
  asynchronously. For scrubbing a filtered multi-clip timeline (where `AVPlayer` seeking lags), v1 uses
  the cached filmstrip for scrub feedback and `AVPlayer` for playback; **profile** whether a direct
  Metal/`MTKView` preview is needed (decide from S0).
- **Undo/redo everywhere.** A command stack over `StudioProject` edits — non-negotiable for the feel;
  absent today.

### 2.5 UX composition — how the pieces fit on one screen

Full-screen cover, CapCut layout, top→bottom:

1. **Preview canvas** in the chosen aspect; overlays directly manipulable here.
2. **Transport + time ruler** with a draggable playhead.
3. **Timeline** (horizontally scrollable, **pinch-zoomable**): main video track (clip thumbnails +
   trim handles + transition badges between clips), then stacked overlay/text/sticker tracks, then
   audio tracks (waveforms). Tap selects the editing context.
4. **Context toolbar** (progressive disclosure — the repo's stated principle): root tools — **Edit**
   (split/trim/speed/delete/duplicate/reverse/freeze), **Audio**, **Text**, **Stickers**,
   **Overlay/PiP**, **Effects/Filters**, **Captions**, **Aspect/Background**. Selecting one swaps the
   bottom panel to that tool's controls; nothing buries the canvas.
5. **Persistent**: undo/redo, play/pause, and **Export** (progress + cancel; reuses B5 share/save).

### 2.6 CapCut feature inventory → on-device feasibility (all no-backend)

| CapCut feature | iOS mechanism | Verdict |
|---|---|---|
| Multi-clip timeline, reorder, per-clip trim | sequential `AVMutableComposition` inserts | ✅ core (S1) |
| Transitions (dissolve/slide/zoom/…) | opacity/transform ramps; complex via custom compositor | ✅ S3 |
| Filters / LUTs / adjustments | `CIColorCube` / `CIColorControls` in `StudioCompositor` | ✅ S2 (needs Pillar B) |
| Text (styles, animated presets) | `CATextLayer` + `CAAnimation` (have basic) / keyframes | ✅ S4 |
| Stickers / emoji / animated GIF | `CALayer` image / `CAKeyframeAnimation` contents | ✅ S4 |
| Overlay / Picture-in-Picture | extra video track + compositor blend | ✅ S4 |
| Keyframes (pos/scale/opacity/rot/filter) | `Keyframe` model + interpolation; `CAKeyframeAnimation` | ✅ S4 |
| Speed (constant + curves/ramps) | `scaleTimeRange` (have constant); piecewise for curves | ✅ S1 const / S7 curves |
| Multi-track audio, music, volume/fade | extra audio tracks + `AVAudioMix` ramps | ✅ S5 |
| Voiceover | `AVAudioRecorder` → audio track | ✅ S5 |
| Auto-captions (speech→text) | **on-device** `SFSpeechRecognizer` → caption track | ✅ S6 (on-device) |
| Background removal / chroma key / masks | Vision person-segmentation / `CIFilter` / `CALayer` mask | ✅ S7 (advanced) |
| Ken-Burns on photos | reuse `PhotoClipRenderer` | ✅ S1 |
| Canvas / aspect / background blur-fill | `renderSize` + background CILayer | ✅ S2 |
| Reverse / freeze-frame | still-insert (freeze) / `AVAssetReader`+`Writer` pre-render (reverse, costly) | ✅ S7 |
| Undo/redo | command stack over `StudioProject` | ✅ S1 |
| Templates | serialize a `StudioProject` as a template | ✅ S8 |

**Overall verdict: GO, fully on-device** (AVFoundation + Core Image/Metal + Vision + Speech), no
backend, honoring the hard on-device-only constraint. The only real risk is **export/preview
performance** with many clips + filters + overlays — gated by S0.

### 2.7 Decomposition — the prompt chain (one prompt = one PR = one branch)

Numbered under this initiative folder. Two parallel tracks; **M** (per-set media) and **S** (studio)
are independent after their first prompt.

**Track M — per-set media** (extends B1/B2; mostly phone-feasible, Photos write needs a device):

| # | Scope | Depends on | Device? |
|---|---|---|---|
| **M1** | Pure `SessionMediaAssignment` algorithm (clips→sets from the completion timeline) + `SnappetTests`; additive `assignedExerciseID/assignedSetIndex/assignmentSourceRaw` on `SessionMedia` (migration); auto-assign after discovery. | B1 | partial |
| **M2** | Grouped-by-set gallery + **General** section in `SessionDetailView`; **Move to…** picker (manual, sticky); low-confidence confirm badges. | M1 | sim-testable |
| **M3** | Live per-set **📎 attach** affordance in `WorkoutPlayerView` (picker scoped to current set) + per-set thumbnail strip. | M1 | partial |
| **M4** | *(optional)* per-set weighting/pins into B4 highlight generation. No engine change. | M1, B4 | partial |

**Track S — full studio** (supersedes B3):

| # | Scope | Depends on | Device? |
|---|---|---|---|
| **S0** | **Spike** (`experiments/` or a device profiling pass): `StudioCompositor` with N clips + a filter + overlays — measure export time, peak memory, preview fps. Deliver a **GO / scope-trim** verdict on compositor depth (conventions: a spike delivers a *decision*). | — | ✅ device |
| **S1** | `StudioProject` model (multi-clip main track, overlay/audio tracks, transitions placeholder, keyframe type) + builder that reproduces today's single-clip behavior as a one-clip project; **timeline UI** (filmstrip, pinch-zoom, trim, reorder, split); **undo/redo**; migrate/bridge `ClipEdit`. *No new pixel effects yet.* | S0 | partial |
| **S2** | `StudioCompositor` (Core Image/Metal) → **filters / LUTs / adjustments** + canvas **background** (color/blur-fill); incremental recomposition for filter-param changes. | S1 | ✅ profiling |
| **S3** | **Transitions** library between clips. | S1, S2 | ✅ profiling |
| **S4** | **Overlays**: PiP video, stickers/GIF, animated text presets, **keyframes** (transform/opacity/filter). | S1, S2 | partial |
| **S5** | **Audio suite**: multi-track, music library, volume/fade mix, voiceover record, beat markers. | S1 | partial |
| **S6** | **Auto-captions** (on-device `Speech`) → editable caption track. | S1, S4 | ✅ device |
| **S7** | **Advanced**: chroma key / person-segmentation masks, speed curves, reverse, freeze-frame. | S2, S4 | ✅ profiling |
| **S8** | **Polish**: snapping/haptics/gesture refinement, **templates**, export presets (res/fps/format); generalize B5 share/save. | S1–S7 | ✅ device |

Pillar C (smoothness) is threaded through S1 (filmstrip + incremental recompose + undo) and finished in S8.

### 2.8 Knowledge-graph updates (standing instruction — do these *in the implementing PR*)

`docs/knowledge-graph/data.js` must change in the same PR as each surface. Planned nodes/edges:
- `media-assignment` (service / pure) — `uses` from `wt-session-detail`; `feeds` `model-workout`.
- `studio-project` (model) — `persists` from the editor; replaces/extends the `wt-clip-editor` data story.
- `studio-editor` (cover) — supersedes `wt-clip-editor`; `present`/`cover` edge from `wt-session-detail`.
- `studio-compositor` (service) — `uses` from `studio-editor`; the AVFoundation/CoreImage render seam.
- Re-grouped media gallery: keep `wt-session-detail`, note the per-set sectioning in its `desc`.
Each S/M prompt lists the exact node(s) it adds so the graph never drifts.

---

## 3. Decision gates & honest risks

- **S0 gates compositor depth.** If a multi-clip + filters + overlays export is too heavy on-device,
  trim transition/effect count and/or add chunked export before S3–S7. (This is the existing B3 gate,
  made concrete.)
- **`(exerciseID, setIndex)` vs `SetLog.id`** — chose index for a clean additive migration; revisit if
  sets ever become reorderable (§1.1).
- **Live tagging during an active session** — still the open B1 question (does PHAsset discovery see a
  clip mid-session or only after Camera finalizes it?). M3's in-the-moment attach sidesteps it for
  hand-attached clips; full live auto-tag may still want in-app capture (deferred, per user).
- **Preview scrub latency** on a filtered multi-clip timeline — decide AVPlayer-vs-Metal-preview from S0.
- **Export memory** with many clips/overlays — chunked export / lower preview resolution as fallbacks.
- **Scope honesty**: full parity is large. The chain is ordered so the end-to-end loop (multi-clip edit
  → export → share) lands at **S1+S2**, with S3–S8 as monotonic enhancements — no prompt leaves the
  studio in a worse state.

## 4. What this supersedes (so the plan doesn't read as contradicting earlier scoping)
- **B1** stays; M-track adds per-set assignment **on top** (additive fields, sticky-manual override).
- **B3**'s single-clip `ClipEditorView` is **replaced** by the `StudioProject` editor; the single-clip
  behavior survives as the one-clip project case (S1 migration/bridge).
- The non-destructive, resolution-independent, pure-math-at-the-edge philosophy of `ClipEdit` /
  `ClipEditGeometry` is **kept and generalized**, not discarded.
