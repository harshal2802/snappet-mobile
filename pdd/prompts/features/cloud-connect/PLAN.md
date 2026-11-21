# PLAN: Cloud Connect

**Created**: 2026-11-19
**Design**: [`docs/ux-research/cloud-connect/index.html`](../../../../docs/ux-research/cloud-connect/index.html)
(capability matrix, architecture, state machines, wireframes)

## Why

A clip is stored as a PHAsset `localIdentifier` — valid on one phone's Photos library only. It
dies when the asset is deleted (Google Photos "Free up space"), re-imported, or the store is
restored onto a new phone. Separately, Snappet's own records live only on the device. This
initiative makes clips survive those events and gives the store an optional cloud safety net.

## Platform facts that shape it (checked 2026-11-17)

- **iCloud Photos needs no sign-in.** Snappet reads the same library through PhotoKit; a
  `PHCloudIdentifier` maps an asset across the user's devices.
- **Google Photos cannot be a silent fallback.** Since 2025-03-31 its Library API only returns
  items the calling app uploaded; anything else needs the user to hand-pick in Google's Picker.
  There is no lookup by filename or path.
- **App Review 5.1.3(ii)**: apps may not store personal health information in iCloud.

## Phases (one prompt = one PR)

| # | Prompt | What | Leaves the phone? |
|---|---|---|---|
| P1 | `265-ios-media-link-resilience.md` | Stamp cloud identifier + fingerprint on every clip; re-link dead identifiers; "Not on this phone" state; Studio opens iCloud-offloaded originals | No |
| P1b | `266-ios-manual-relink.md` | Missing-clip notice in Clips + "Find missing clips" sheet: pick footage from this iPhone, verified against the fingerprint | No |
| P2 | `267-ios-icloud-backup.md` | Opt-in automatic backup of the `SnappetBackup` file to the person's iCloud, encrypted on the phone; restore list; welcome-back offer | **Yes, when switched on** (named exception, decisions 2026-11-19) |
| P3 | `268-ios-google-drive-backup.md` | Google sign-in (PKCE, no SDK) + Google Drive as a second backup destination; hidden until a client ID is configured (`docs/google-cloud-setup.md`) | Yes, when switched on |
| P4 | `269-ios-clip-vault-google-photos.md` | Opt-in clip copies in a Google Drive folder, played from there when not in Photos; pick old footage in Google Photos and copy it Google → Drive | Yes, when switched on / picked |

Product decisions (user, 2026-11-19): cloud features are an **opt-in exception** to on-device-only
(off by default, backups encrypted on the phone); heart-rate samples are a **default-off switch**;
Google code is built now with the client ID supplied later; the clip vault is built.
