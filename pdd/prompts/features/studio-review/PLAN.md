# PLAN: Studio — clip edits, reels, one renderer

**Created**: 2026-11-23 (decisions updated 2026-11-24)
**Follows**: prompts 294–302 (the Studio code-review fixes, PRs #483–#491)
**Wireframes**: https://claude.ai/artifact/3RYh8wXPKKHEyLbfM2yiuT (review screens; the screens this
plan adds are not drawn yet)

## Why

Prompts 294–302 fixed the review's findings one at a time. Three causes are still in place, and
most of the remaining doubt about the Studio comes from them.

1. **Two drawings of every overlay.** The video is drawn by one compositor (prompt 300). Text,
   climb tags and the heart-rate tile are still drawn twice: SwiftUI in the preview, a Core
   Animation layer in the export. The simulator cannot draw that layer's text, so no test has seen
   an HR tile or a climb tag in a file from the new compositor.
2. **One project shared by a whole session.** "Edit this clip" is a filtered view of the session's
   project. Items that are not bound to a clip (HR tile, plain text, music, picture-in-picture,
   base frame) mean something different in each view. A bake burns whatever was in view, and the
   app then has to remember what it burned (prompts 294, 295). A timeline with baked and unbaked
   clips still renders those items twice.
3. **More than one "burn heart rate into a video".** The Clips feed overlay, "Share with heart
   rate", the Studio, and the reel maker (`Features/Reel`, `Services/ReelExporter.swift`) each
   decide which HR samples belong to a clip and draw them. The reel maker has no reference to
   Studio edits or to baked clips.

## What exists today (checked in the code, 2026-11-23)

- Every edit entry in the Clips feed (Sessions, Activities, Exercises), the session detail, the
  Quick Session player and Kilter opens the session's `StudioProject`, scoped to a clip or a post.
- The progress reel (Exercises) and the weekly / monthly highlight reels are built by a separate
  reel maker: `ReelView` + `ReelViewModel` + `ReelExporter`, planned by `HighlightEngine`
  (`ReelPlan`), with its own trim (`ReelTrim`), its own captions and its own HR scorebug. A posted
  reel is a `SessionMedia` row with `isReel`.
- Not checked on a device: whether a progress reel ignores a clip's Studio trim and filter (the
  code suggests it does), and whether it draws its scorebug over a baked clip's own tile.

## The model

Three layers. Each owns what only it can know.

| Layer | Owns | Edited in |
|---|---|---|
| **Session style** | The default look for the session's clips: HR tile design and position, climb-tag style, text font | Either editor ("apply to all clips") |
| **Clip edit** (one per video) | Trim, speed, crop, filter, volume, its climb tag, its text and stickers, its own music, and any override of the session style | "Edit this clip", and inside a reel |
| **Reel** (any number; may span sessions) | An ordered list of **clip uses**, transitions, reel music, titles, picture-in-picture, canvas shape and base frame | The reel editor ("Edit all clips", progress reel, highlight reel) |

A **clip use** is one appearance of a clip in a reel. It points at the clip; it does not copy it.
It may carry:

- an **override set**: optional values used **in this reel only** (absent = follow the clip).
  Trim, speed and volume are the first entries. The set is general, so filter and crop can be
  added later as two more optional fields with no migration;
- an on/off switch for each thing that comes from the clip (climb tag, HR tile, each text, the
  clip's music).

The same clip may be used twice in one reel with different trims. This replaces split parts.

Three rules that keep later additions from changing the model:

- **One function gives "the clip as this reel sees it"** (the clip edit with the override set laid
  over it). The render plan, the HR window and the timeline read only that result, so none of
  them knows which properties can be overridden.
- **A clip's items are positioned on the output frame, not on the source video.** A different crop
  in a reel changes the picture behind a tag; the tag stays where it was put. A filter applies to
  the video only, never to the items on top.
- **A reel is its own object.** It is owned by neither a session nor an activity. It is listed in
  one "Reels" list, and also under every session and every activity it uses a clip from (the same
  reel, not copies). A reel made by a rule remembers where it was made, so "Progress reel" under
  an exercise finds the existing one.

In a reel that mixes sessions, each clip keeps its own session's heart rate, zones and maximum,
and arrives with its own session's style. One reel switch, "Use one style for this reel", makes
them match. A clip whose session or video was deleted is a missing clip use (the "clip missing"
state from prompt 302, with a remove action).

## Decisions (user, 2026-11-23 and 2026-11-24)

1. **Both editors, with full features.** A per-clip editor and a reel editor. The reel editor can
   edit a clip in place; that changes the clip everywhere.
2. **Trims are shared by default, with a per-reel override.** Dragging a trim handle in the reel
   editor asks once: "Trim just in this reel" or "Trim the clip everywhere". A reel trim shows a
   badge and can be reset to the clip's trim. Speed and volume follow the same rule. Filter and
   crop will get a per-reel override too, later; the override set is built to take them.
3. **Reel items may overlap clip items, as long as they are easy to see and switch.** Each clip in
   a reel has a "From this clip" list with one plain on/off switch per item (off = off in this
   reel only). Reel items and clip items sit in separate rows on the timeline.
4. **Several reels per session.** A reel list with new, duplicate, rename and delete.
5. **Music in both.** A clip may have its own music; a reel may have its own. When a reel has
   music, each clip's music is off in that reel by default, with a "Play this clip's music"
   switch in "From this clip". The clip's original sound is separate and keeps its own volume.
6. **Session style is inherited.** Changing the HR tile in the session style changes every clip
   that has not overridden it.
7. **Progress reels and highlight reels are reels in this model.** They are created automatically
   (by rule, or by the highlight engine's picks) and can then be opened in the reel editor. The
   separate exporter is retired. This means a reel may point at clips from other sessions and
   other activities from the start.
8. **A reel belongs to no single session or activity.** It appears in a "Reels" list and under
   everything it contains.

## What the user sees

- **No change** from the phases that move drawing into the compositor and unify heart rate,
  except: text and the HR tile in the preview may shift slightly to match the exported file, and
  one of feed / share / Studio may change an HR number if they disagree today.
- **Visible change, once**, when the editors move to the new model: "Edit this clip" edits that
  clip only; "Edit all clips" opens a reel; music, transitions and titles are reel items; the
  "From this clip" list and the reel list appear.
- The editor's states stay as prompt 301 left them: loading, ready, rendering (locked, with
  progress), finished, clip missing.
- A bake burns one clip edit plus the style it inherits, clears the edit, and marks the clip
  "style already burned". The per-item record and the stand-down from prompts 294–295 go away.

## Phases (one prompt = one PR)

| # | Prompt | What | Visible? |
|---|---|---|---|
| P0 | — | Verify and merge #483–#491: affected UI suites, the phone checks each prompt lists, a review of #489–#491 | — |
| — | 303 | Review fixes for prompts 300–302 (`303-ios-studio-review-fixes-300-302.md`). Done before P1; the prompt numbers below are provisional and moved up by one for it | Small fixes |
| — | 305 | **305 = baked clips keep their heart-rate timing** (`305-ios-studio-baked-clip-hr-time-map.md`). A user-reported priority, done with P0–P1: a baked clip carries a map from its video's time back to the recording, and every heart-rate reader uses it. Adds one optional `SessionMedia` field. The prompt numbers of P2–P11 moved up by one more for it | An HR tile added to a baked clip is on the right seconds |
| — | 306 | **306 = heart-rate timing checked end to end** (`306-ios-studio-hr-timing-end-to-end.md`). Part of P0's verification: a UI test opens an unbaked clip, a clip baked with a start trim and a clip baked at 2× in the running Studio, reads the preview tile's bpm against a ramp, and exports. A DEBUG-only seed and read-out; no model change. The prompt numbers of P2–P11 moved up by one more for it | Debug only |
| — | 307 | **307 = the phone's overlay reference committed** (`307-ios-studio-overlay-reference.md`). The 11 frames and manifest from "Capture overlay reference" on the phone, 2026-11-26, are the "before" pictures for P2 and P3. The sticker frame shows a bug in today's export (black boxes) and is marked wrong | No |
| — | 308 | **308 = stickers burn as black boxes in an export** (`308-ios-studio-sticker-export.md`). Found by the capture above; fixed in the export, then the sticker frame is captured again. The prompt numbers moved again for 307 and 308: P2 and P3 to 310 and 311 (309 was already P4), P5–P11 up by two | Stickers appear in exported videos |
| — | 320 | **320 = a UI-test launch touches nothing outside its test store** (`320-ios-test-launch-isolation.md`). A seeded device run backed its test store up to the person's Google Drive and deleted their settings: one test-launch gate for every side effect, settings saved and put back on a phone, a read-out device tests check before their first tap | Test-only |
| P1 | 304 | **Golden frames + device self-check.** A small fixture video and HR series in the repo; unit tests render frames and compare them with stored images. A debug screen renders the same fixture on the phone and reports pass / fail and export time | Debug only |
| P2 | 310 | **Text, stickers and climb tags drawn by the compositor.** The render plan lists them per moment; the canvas keeps only the handles and draws the item being dragged. The Core Animation tool is no longer used for them | Preview matches export |
| P3 | 311 | **HR tile drawn by the compositor**, with its values per moment in the render plan. Golden frames cover the tile across a transition | Preview matches export |
| P4 | 309 | **One heart-rate resolver** (`309-ios-one-heart-rate-resolver.md`) for the feed overlay, "Share with heart rate", the Studio and reels, and a test that one clip gives the same numbers on all of them. Done before P2 and P3 (it does not depend on them). The Recap poster chip, the activity pages' average and the reel scorebug changed; a Studio edit is now read on Recap, activity and festival screens too; feed, share and Studio changed only for footage more than 90 s outside the recording (no tile) and where a window reaches past the recording's first or last sample (AVG counts it once) | A number may change |
| P5 | 312 | **The model and the migration**, behind the existing screens. Session style, clip edit, reel, clip use; `StudioProject` rows migrated (clip-bound items → the clip; unbound text, music, picture-in-picture, transitions → a reel; HR tile → session style); backup round-trip | No |
| P6 | 313 | **Clip editor on clip edits.** "Edit this clip" everywhere (feed tabs, session detail, Quick Session, Kilter); feed, share and bake read the clip edit; the bake becomes one flag; scope filters, the baked record and the stand-down are removed | Yes |
| P7 | 314 | **Reel editor.** Clip uses, per-reel trim / speed / volume, "From this clip" switches, the music rule, the reel list. Split parts become clip uses | Yes |
| P8 | 315 | **Session style controls**: apply to all clips, override on one clip, reset | Yes |
| P9 | 316 | **Progress reels as reels.** The Exercises rule (PRs only / one per month / all) creates a reel; the date and set captions are reel text; listed under the activity it was made from | Yes |
| P10 | 317 | **Highlight reels as reels.** The engine's picks become clip uses with reel-only trims; the quick reel builder stays as the front door, with "Open in editor"; `ReelExporter` is retired; posted reels (`isReel`) keep working | Yes |
| P11 | 318+ | The review's remaining items on the new base: controls for photos, stickers, background; photo clips, picture-in-picture sound and music fades in the render; timeline polish (thumbnails, waveform, drag-reorder, snapping, transition length); the "Save to original" sheet | Yes |

P1–P5 change nothing the user has to learn. The visible change arrives at P6–P7, on a base the
golden frames already cover.

## Verification

- **Golden frames** (P1) are the gate for every later phase: a change to how a frame looks must
  change a stored image in the same PR.
- **The device self-check** (P1) is how Photos, real footage and performance are checked: one tap
  on the phone, with export time shown. Run before each merge from P2 on.
- **Migration tests** (P5): fixture stores made by the current build (a scoped bake, split parts,
  a project with music and picture-in-picture, a baked clip with a record) are migrated in unit
  tests and compared with the expected clip edits and reels. The phone must never get a build
  missing the new fields (`phone build = schema superset`).
- **Cross-surface HR test** (P4): same clip, same numbers, on every surface.

## How the plan is run (user, 2026-11-24)

- All work lands on the integration branch `studio-v2`; `main` is not touched until the end.
- Each phase is one PR into `studio-v2`. It is merged without asking when all of these pass: the
  full unit suite (golden frames included, from P1); the affected UI suites on the simulator for a
  phase that changes screens; an independent review with no important finding left open;
  migration fixtures (from P5); no golden image changed without the prompt saying why.
- One checkpoint: the wireframes for the new screens are shown to the user before P6.
- At the end the user gets one list of steps to check on the phone, covering prompt 294 onward,
  riskiest first. `studio-v2` merges to `main` after that pass.

## Settled questions (user accepted the suggested answers, 2026-11-24)

1. A feed post with several clips opens a "pick a clip" step, not a reel (first version).
2. The quick reel builder (`ReelView`) stays for one-tap reels, with "Open in editor" for anything
   more.
3. Per-reel filter and crop overrides are wanted, after the first version.
4. A clip baked before prompt 295 (no record of what was burned) is treated as "style already
   burned". Re-check when the migration fixtures exist.

## Still open

1. How a reel made of clips from several sessions is posted to the feed. Today a posted reel is a
   `SessionMedia` row on one session. Check how the weekly reel does it before P5; the model may
   need a post that is not tied to one session.
