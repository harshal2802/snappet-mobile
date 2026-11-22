# Prompt: The published privacy page covers Google sign-in, Drive backup and clip copies

**File**: pdd/prompts/features/cloud-connect/280-privacy-page-google-drive.md
**Created**: 2026-11-21
**Project type**: Docs — the page served at `…/snappet-mobile/privacy-policy.html` (GitHub Pages from `docs/`).
**Chain**: `cloud-connect/PLAN.md` → follow-up after the stack merged
**Context**: `pdd/context/project.md`, `pdd/context/decisions.md`

## Goal

The Google sign-in app (published 2026-11-21) links to `docs/privacy-policy.html` as its privacy
policy. Prompts 267–269 updated `docs/privacy-policy.md` only, so the page people and Google
actually read said nothing about Google sign-in, Google Drive or clip copies, and still said
nothing is ever uploaded.

## What changed

- `privacy-policy.html` and `privacy-policy.md` say the same things again.
- New section "Google sign-in and Google user data": each thing the app asks Google for and the one
  feature it serves (email shown in the app; the private app folder for the encrypted backup; files
  the app itself creates for clip copies; only the items picked in Google's Photos picker), where
  the data goes (phone ↔ Google only, no Snappet server, tokens in the device keychain), what is
  not done with it (no sale, ads, model training or human access), how to remove it, and the
  Google API Services User Data Policy / Limited Use statement.
- Statements that had become untrue are qualified rather than left: "nothing is uploaded" for
  photos and videos, and "HealthKit data is never transmitted off your device" (heart-rate samples
  travel inside the encrypted backup only when "Include heart-rate samples" is switched on; off by
  default).
- "No account" now reads "No SnappetAI account"; Google sign-in is named as optional.
- Last updated: November 21, 2026.

## Checked against the code

Scopes (`GoogleScope`, drive.file, Photos picker), `includeHeartRate = false` by default, sign-out
revokes and clears the tokens, tokens stored `ThisDeviceOnly`.

## Not covered here

The policy still says nothing about the content the app downloads (festival lineups, exercise
photo packs, the Kilter index) or the wardrobe price lookup, which fetches a product page the
person names. None of them sends personal data, but "what the app connects to" deserves its own
paragraph.
