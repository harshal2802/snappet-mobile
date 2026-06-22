# Prompt: Clips — share a single clip

**File**: pdd/prompts/features/87-ios-clips-share.md
**Created**: 2026-06-22
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: prompt 82 Clips feed → its deferred "share" follow-up (#1b)
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## Goal

A ⋯ menu **"Share clip"** on a Clips post that hands the centered clip's video to the system share
sheet. The quick "send this clip" path; the rich HR-**overlay-burned** share stays the Studio's job
(⋯ → Edit this clip → export), so this is RAW (no re-encode, original quality).

## Context the implementer needs

- `Features/Shell/ShareSheet.swift` is the shared `UIActivityViewController` wrapper —
  `ShareSheet(items:[Any], onComplete:)`.
- The repo's PHAsset→AVAsset→export idiom: `PHImageManager.requestAVAsset(forVideo:)` (boxed across the
  continuation, AVAsset isn't `Sendable`) → `AVAssetExportSession` → `try await session.export(to:as:)`
  (see `StudioComposer.avAsset` / `.export`).
- `ClipPostCard.currentClip` is the centered carousel page; the ⋯ edit actions are video-only.

## Approach

- New `Features/Feed/ClipShareService.swift` (Foundation + Photos + AVFoundation): `exportForSharing(
  localIdentifier:) async -> URL?` — fetch the `PHAsset` (guard `mediaType == .video`), `requestAVAsset`,
  then try `AVAssetExportSession` **passthrough** → `.mov`; on failure (passthrough can construct yet throw
  for non-remuxable sources) retry a **HighestQuality re-encode** → `.mp4`. Returns nil on the sim / a
  missing asset / total failure.
- `ClipPostCard`: a ⋯ "Share clip" (video only) → `shareCurrentClip()` sets a busy flag + a
  `Task { @MainActor }` export → on success present `ShareSheet(items:[url])` (delete the temp file via
  `onComplete`); on nil show a "Couldn't prepare this clip" alert. A `ProgressView` while exporting.

## Output

- `ios/App/Snappet/Features/Feed/ClipShareService.swift`.
- `ios/App/Snappet/Features/Feed/ClipsFeedView.swift` — the ⋯ action + share sheet + alert.
- `docs/knowledge-graph/data.js`, `pdd/context/decisions.md`, `pdd/context/project.md`.

## Acceptance criteria

- [ ] A ⋯ "Share clip" (video clips) exports the centered clip and presents the system share sheet.
- [ ] The exported temp file is deleted after the sheet completes (no tmp accumulation).
- [ ] An export that can't passthrough re-encodes; a total failure shows an alert (not a silent spinner).
- [ ] No new `@Model` / no persistence. App type-checks (Swift 6, 0 warnings); full `SnappetTests` green.

## Constraints

- On-device only; the export needs a real `PHAsset` (the sim returns nil). Reuse `ShareSheet`; the rich
  overlay-burned share is NOT duplicated here (it's the Studio's).

## Test plan

1. `xcodegen generate && xcodebuild test … -only-testing:SnappetTests` — build 0-warning, suite green;
   `ClipsFeedUITests` green (the menu wiring).
2. On a device with clips: ⋯ → Share clip → the share sheet appears with the clip; cancel/share both
   clean up the temp file.
