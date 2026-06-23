# Prompt: Clips — audio + Instagram-style mute/unmute toggle

**File**: pdd/prompts/features/93-ios-clips-audio-mute-toggle.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: Clips playback-polish pass (3 of 4) → user-reported "audio from video is missing … mute/unmute the way Instagram does".
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

Clip audio is inaudible and there's no visible audio control. Make an unmuted clip play sound **through the
ring/silent switch** (Instagram/TikTok-style), and add a 🔊/🔇 toggle on the playing clip so the user can
mute/unmute at will.

## Context the implementer needs

- Root cause: **the app never configures an `AVAudioSession`** (a full-tree grep finds zero
  `setCategory`). Playback runs on the default `soloAmbient`/`ambient` category, which the hardware silent
  switch mutes — so audio is inaudible even when `player.isMuted == false`. This was a recorded deliberate
  choice (decisions.md:4703, "audio respects the silent switch — no audio-session override") that the
  Clips feed inherited; we are **reversing** it for Clips.
- The mute plumbing is correct already: `PlayingClipRef.muted` (ClipsFeedView.swift) is the single source
  of truth; `ClipMediaSurface` syncs `player.isMuted` from it (line 54/119); autoplay starts muted
  (prompt 90), tap-to-play is unmuted. There is **no** "tap-to-play stays muted" bug.
- There is **no visible speaker control** today; the only mute change is an obscure tap-to-unmute on a
  muted autoplay clip, and you can't re-mute.
- Chosen behavior (confirmed with the user): **interrupt** other audio while a clip is unmuted (pause the
  user's music/podcast) and **restore** it when the clip mutes / scrolls away — i.e. plain `.playback`.

## Approach

- **New `ClipAudioSession`** helper (`ios/App/Snappet/Services/`, AVFoundation I/O — keep it out of pure
  code): `activatePlayback()` → `AVAudioSession.sharedInstance()` `setCategory(.playback)` + `setActive(true)`;
  `deactivate()` → `setActive(false, options: .notifyOthersOnDeactivation)` so the user's music resumes.
  Idempotent / safe to call repeatedly; swallow + log errors (never crash on an audio-session failure).
- **Activate on unmute, deactivate when nothing is unmuted.** Call `activatePlayback()` whenever a clip
  becomes unmuted (the `onToggleMute` path below + tap-to-play). Call `deactivate()` when the feed has no
  unmuted clip — when `playingClip` clears (scroll-away / autoplay-off) or a clip is re-muted, and on
  `ClipMediaSurface` teardown. The single source of truth (`playingClip?.muted`) decides.
- **Speaker toggle** in `ClipPosterView` (ClipsFeedView.swift), overlaid on the carousel ZStack
  (e.g. `.overlay(alignment: .bottomTrailing)`), shown only when `isPlaying && item.media.kind == "video"`:
  `speaker.slash.fill` when muted, `speaker.wave.2.fill` when unmuted. Driver = `playingClip.muted`.
  **Generalize** the existing `onUnmute` closure to `onToggleMute` that flips `pc.muted` **both** ways (and
  triggers the session activate/deactivate). Give the button `allowsHitTesting(true)` + a `contentShape` so
  it sits above the player surface (and above the tap-to-fullscreen gesture added in prompt 94).
- Keep the control in the **caller** (`ClipPosterView`), not in the shared `ClipMediaSurface` — the
  fullscreen `MediaPage` reuses that surface and the feed's scroll-stop/transfer logic reads
  `playingClip.muted`.

## Output

- `ios/App/Snappet/Services/ClipAudioSession.swift` (new).
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — the 🔊/🔇 toggle, `onToggleMute`, and the
  session activate/deactivate wiring on the mute transitions + `playingClip` clears.
- `ios/App/Snappet/Features/Feed/ClipMediaSurface.swift` — deactivate the session on teardown.
- `docs/knowledge-graph/data.js` (a `ClipAudioSession` node + edge), `pdd/context/decisions.md` (record the
  reversal of decisions.md:4703 for Clips).

## Acceptance criteria

- [ ] Unmuting a clip plays its audio **even with the phone on silent**; the user's other audio pauses
      while a clip is unmuted and resumes when it mutes / scrolls away.
- [ ] A 🔊/🔇 button on the playing clip toggles mute; its icon reflects `playingClip.muted`; autoplay
      still starts muted; scrolling away still stops an unmuted clip.
- [ ] Recap's fullscreen viewer + the export path are unaffected (they don't grab the session unless a
      clip is unmuted there too).
- [ ] App type-checks (Swift 6, 0 warnings); full `SnappetTests` green.

## Constraints

- AVFoundation I/O in `Services` only. Single source of truth stays `playingClip.muted`.
- This reverses a recorded decision — record the reversal in `decisions.md` the same day.
- Device-verify (audio + silent switch + other-app interruption can't be unit-tested).

## Test plan

1. `xcodebuild test … -only-testing:SnappetTests` — build 0-warning, suite green.
2. On a device, phone on **silent**, music playing: unmute a clip → clip audio plays + music pauses; tap
   🔇 / scroll away → music resumes. Toggle reflects state across autoplay + tap-to-play.
