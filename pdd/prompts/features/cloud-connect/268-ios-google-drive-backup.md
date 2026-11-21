# Prompt: Google sign-in + Google Drive as a backup destination

**File**: pdd/prompts/features/cloud-connect/268-ios-google-drive-backup.md
**Created**: 2026-11-19
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: `cloud-connect/PLAN.md` → P3 (stacked on P2, prompt 267)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`
**Setup**: `docs/google-cloud-setup.md`

## Goal

The person's footage and storage are with Google, not Apple. Let the automatic backup (prompt 267)
go to **their Google Drive** instead of iCloud, and lay the sign-in that prompt 269 builds on.

## Product decision (user, 2026-11-19)

**Build now, client ID later.** No Google Cloud project exists yet: ship the code with the client ID
read from config, hide every Google control while it is empty, unit-test everything that needs no
Google, and write the console steps down.

## Approach

- **Pure** (`Core/GoogleAuth.swift`): `GoogleOAuthConfig` (client ID → reversed-ID redirect),
  `GooglePKCE`, `GoogleOAuth` (authorization URL, callback → code with state check, token / refresh /
  revoke requests, token parsing, error mapping), `GoogleDriveAPI` (list / resumable upload /
  download / delete in `appDataFolder`).
- **Edge** (`Services/GoogleAccount.swift`): `GoogleAccount` (two-half sign-in around the system
  browser sheet, keychain tokens, shared refresh, sign-out + revoke); `GoogleDriveVault: CloudVault`.
- `CloudBackupDestination.googleDrive`; `GoogleAccountRow` in the Automatic backup section.
- No Google SDK — URLSession + AuthenticationServices only.

## Constraints

- No client ID ⇒ no Google UI, no Google request, ever.
- Least scope: `drive.appdata` (a hidden folder only Snappet can read) + `openid email` to name the account.
- No client secret; PKCE + state on every sign-in; a redirect that is not ours exchanges nothing.
- Tokens: keychain, this device only. The backup key stays as in 267.
- The vault still only ever receives sealed bytes.

## Verification

- Unit: `GoogleAuthTests` (RFC 7636 vector, URL/callback/token/Drive request shapes),
  `GoogleAccountTests` against an in-memory fake Google (sign-in, forged state, unticked permission,
  shared refresh, revoked session, vault round trip incl. paging / replace / 401 retry, the backup
  service end to end over Drive).
- UI: `BackupUITests` — Google hidden without a client ID; with a signed-in stand-in the destination
  names the account, backs up, and signs out.
- Owed (needs the client ID): the real consent sheet, a real Drive upload/restore, token refresh
  over days, sign-in on the `.alpha` bundle.
