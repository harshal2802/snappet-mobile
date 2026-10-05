# Prompt: Household P2: invite, join and sync between iPhones on the home Wi-Fi (prompt 157)

**File**: pdd/prompts/features/household/02-household-local-sync.md
**Created**: 2026-10-04
**Project type**: Native iOS feature (Swift / SwiftUI). Code lands in this repo.
**Chain**: Household initiative, P2 of 4 (wireframe frames 4, 5, 6: `docs/ux-research/household-chores/wireframes.html`). Builds on P1 (prompt 156, PR #344).
**Source**: user, 2026-10-04: "continue working on IOS version first" (Android moves wholly to P4)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`, `pdd/context/household-wire-format.md`
**Schema**: `pdd/context/snappet-core-schema.md`

## Goal

Make the household real: a member invites others by QR, they join, and every phone's board converges by
exchanging ops **directly over the local network**: no server, no accounts, no cloud. P1 already stores
the board as an op log with merge rules decided; P2 is discovery, membership, a secure channel, and the
sync conversation, plus the screens that make sync visible and trustworthy (frames 4–6).

**iOS ↔ iOS only in P2.** The protocol is written so the P4 Android port can implement it with standard
crypto, but no Android work or testing happens here.

## Context the implementer needs

- P1's keystone: `Features/Household/ChoreLog.swift` (`ChoreOp`, v1 wire JSON, `VersionVector`),
  `ChoreBoard.fold` (order-independent, idempotent). `HouseholdStore` appends ops as this phone;
  `HouseholdOpRecord.payload` stores each op's wire JSON verbatim, so relaying an op is copying bytes.
- QR scanning: reuse `Core/SnappetScannerView` (camera-only, decode closure). URL entry: `RootShell.handle`
  + `SnappetDeepLink.route` + a `SuiteRouter` one-shot (the `pendingFestivalImport` pattern).
- Info.plist is `Snappet/Resources/Info.plist` (not generated). Local networking needs
  `NSLocalNetworkUsageDescription` + `NSBonjourServices`.
- iOS suspends sockets in the background. Sync runs **while the app is in the foreground**; that limit was
  accepted at wireframe review.

## Approach

### 1. Membership and keys

- `Household` gains `key: Data` (32 random bytes, generated lazily on first invite for P1 households) and
  `leftAt: Date?`. Backup row adds both as Optionals so P1 blobs decode.
- The household key never appears in a QR. An **invite** is a separate one-time token: 32 random bytes,
  valid 5 minutes, single-use, held in memory on the inviter only.
- QR / link: `snappet://household/join?v=1&h=<household uuid>&n=<name>&t=<token, base64url>&e=<expiry unix>`.
  The camera app can open it (deep link) or Household's own scanner can read it. "Copy link" is offered too.
- Joining: the joiner connects to the inviter (discovered by the token's tag, below), proves it holds the
  token, and receives the household id, name and key over the encrypted channel. The inviter then burns the
  token. The joiner creates the `Household` with that id and key, its **own** fresh device and member ids,
  and appends `add_member` for itself.
- A joiner who already has a solo board: the old household is kept (`leftAt` set) so its history and XP
  survive (`HouseholdXP` sums credits across **all** households for each one's `myMemberID`). The join sheet
  offers "Bring my N chores", which copies active chores as new `create_chore` ops into the joined household
  (no completions copied).
- One active household at a time = the newest with `leftAt == nil`.
- Restoring a backup re-rolls each household's `myDeviceID`, so two phones restored from one backup never
  write ops with the same device id and counter.

### 2. Discovery (Bonjour)

- Service type `_snappet-hh._tcp`. Each phone with a shared household runs an `NWListener` advertising a
  service named by its device id, with a TXT record:
  - `hh` = first 8 bytes (hex) of `HMAC-SHA256(key, "snappet-household-tag-v1")`. It identifies the household
    to members without revealing its id.
  - `inv` = the same construction over the invite token, present only while an invite is open.
  - `v=1`.
- An `NWBrowser` (`.bonjourWithTXTRecord`) finds peers. Connect to a peer whose `hh` matches (sync) or whose
  `inv` matches the scanned token (join). To avoid double connections, only the phone with the
  lexicographically smaller device id dials a household peer; the other waits.
- Start/stop: runs while the app is foreground **and** the active household has ≥ 2 members (or an invite or
  join is in progress). Solo users never see the Local Network prompt.

### 3. Secure channel (app-level, portable)

TLS-PSK was the P1 plan, but Android's TLS stack (Conscrypt) doesn't offer PSK suites to apps, so the
channel is built from primitives both platforms have: **HKDF-SHA256 + ChaCha20-Poly1305** (CryptoKit on
iOS; JCA/Tink on Android). Record this in decisions.

- Framing: 4-byte big-endian length, then the payload. Max frame 1 MiB; a bigger length closes the connection.
- Handshake (plaintext JSON frames):
  - dialer → listener: `{"t":"hello","v":1,"mode":"sync"|"join","device":"…","nonce":"<32B b64>"}`
  - listener → dialer: `{"t":"hello","v":1,"device":"…","nonce":"…"}`
- Keys: `HKDF-SHA256(ikm: secret, salt: dialerNonce ‖ listenerNonce, info: "snappet-hh-v1 d2l" | "snappet-hh-v1 l2d", 32 bytes)`,
  where `secret` = household key (sync) or invite token (join).
- Every later frame is a ChaCha20-Poly1305 sealed box (`nonce ‖ ciphertext ‖ tag`, 12-byte random nonce)
  over a JSON message. The first sealed message each way is `{"t":"auth","device":"…"}`. A frame that fails
  to open means the other side doesn't hold the secret; close immediately. Nothing about the household is
  sent before auth.
- Replay inside a session can only re-deliver an idempotent op; fresh nonces per session prevent
  cross-session replay.

### 4. The sync conversation (encrypted messages)

- `{"t":"state","vv":{"<device>":<seq>,…},"member":"…","name":"…","platform":"ios"}`, sent by both sides after auth.
- `{"t":"ops","ops":["<op wire json>",…]}`: each side sends `VersionVector(theirs).missing(from: mine)`,
  chunked to keep frames under the limit. Op strings are the stored payload bytes verbatim, so ops of kinds
  this phone doesn't understand are relayed untouched.
- `{"t":"done"}`; when both sides have sent `done`, the dialer closes.
- Join mode only: after auth, the listener (inviter) sends
  `{"t":"welcome","household":"…","name":"…","key":"<b64>"}`, then the normal `state`/`ops`/`done` follows on
  the same connection.
- Ingest: decode each op string, skip ids already stored, insert the record with its payload verbatim, then
  one fold + XP publish per batch.

**The conversation is a pure state machine** (`HouseholdSyncMachine`: `start() -> [Frame]`,
`receive(Data) -> [Frame]`, with an outcome) over an injected log source/sink. The `NWConnection` code only
moves bytes. Two machines wired back to back are the main test harness.

### 5. Peers and status

- `@Model HouseholdPeer` (householdID, deviceID, memberID, name, platform, lastSyncedAt, `ackedSeq` = the
  highest seq of **my** device the peer has confirmed). Backup row too.
- "Changes waiting" = my device's latest seq minus the max `ackedSeq` over peers (0 if no peers).
- Status pill on Today (frame 1): "N phones · synced 2m ago", "Syncing…", or "2 changes waiting" (frame 6).

### 6. Screens

- **Household** segment (frame 5): your name (editable, as an `add_member` op), the members list, each peer
  phone with a platform badge and "synced …", **Sync now**, **Invite someone**, **Join a household**, and the
  household name (editable, via a new additive op kind `rename_household`: v1 readers ignore unknown kinds;
  update the wire spec).
- **Invite sheet** (frame 4): QR, 5-minute countdown, "works once", Copy link, and the three trust rows.
  It changes to "Alex joined ✓" when the join completes.
- **Join**: scanner sheet (or opened link) → confirm sheet ("Join Flat 4B?", "Bring my N chores" toggle) →
  connecting → done. Errors are named: expired, already used, inviter not found on this network (check
  you're on the same Wi-Fi), other side closed.
- **Today**: "Both of you did it" stays the P1 merge (both credited, counts once); show the done-by names already in the row.
- Info.plist: `NSLocalNetworkUsageDescription` ("Snappet finds your household's phones on this Wi-Fi to share
  chores. Nothing leaves your network.") and `NSBonjourServices` = `_snappet-hh._tcp`.

## Output

- `Features/Household/`: `HouseholdInvite.swift` (pure: token, URL encode/parse, tags), `HouseholdSyncProtocol.swift`
  (pure + CryptoKit: framing, handshake, key derivation, seal/open, messages), `HouseholdSyncMachine.swift`
  (pure state machine), `HouseholdMembersView.swift`, `HouseholdInviteSheet.swift`, `HouseholdJoinFlow.swift`.
- `Services/HouseholdPeerService.swift`: NWListener + NWBrowser + NWConnection pipe, owned by `AppModel`,
  started/stopped by scene phase and household state.
- Model changes (`Household.key`, `leftAt`; `HouseholdPeer`) + backup rows + device-id re-roll on restore.
- `SnappetDeepLink.householdJoin`, `SuiteRouter.pendingHouseholdJoin`, RootShell routing.
- Wire spec: new `rename_household` kind + a new section specifying the sync protocol (handshake, keys,
  messages) as the P4 contract. Decisions entry. Knowledge graph nodes + edges. project.md.

## Acceptance criteria

- [ ] Two `HouseholdSyncMachine`s wired back to back converge: after sync both logs hold the union and fold to equal boards, including concurrent edits on both sides and ops relayed from a third device.
- [ ] A second sync with nothing new sends zero ops.
- [ ] Join over the machine pair: the joiner ends with the household id, name, key and the full log; the token is burnt; a second join with the same token fails; an expired token fails.
- [ ] Wrong secret: the handshake fails at auth and no household data (welcome, state, ops) is ever sent.
- [ ] A tampered or oversized frame closes the session without a crash.
- [ ] Framing handles split and coalesced frames.
- [ ] Invite URL round-trips; foreign or malformed URLs are rejected.
- [ ] An op of an unknown kind is relayed byte-for-byte.
- [ ] A real-socket loopback test (NWListener + NWConnection on 127.0.0.1, no Bonjour) runs a full sync between two stores.
- [ ] Joining with an existing solo board keeps old XP; "Bring my chores" copies active chores only.
- [ ] Restore re-rolls `myDeviceID`; backup round-trips the new fields and `HouseholdPeer` (tripwire green).
- [ ] Solo users never trigger the Local Network prompt (the service doesn't start with one member and no invite/join).
- [ ] Household tab, invite sheet and join confirm exist with accessibility ids; UI test covers the invite sheet + members tab.
- [ ] End-to-end on two simulators on this Mac (invite link via pasteboard → `simctl openurl` on the other): both boards converge.
- [ ] App type-checks (Swift 6, 0 warnings); unit + UI suites green.

## Constraints

- No server, no third-party networking or crypto dependency. CryptoKit + Network.framework only.
- The household key is never in a QR, a URL, a log line or a notification.
- Sync never blocks the main thread on I/O; folding stays on the main actor (logs are small).
- Don't widen the Local Network prompt's reach: it appears only after the user invites or joins.
- State verification honestly: simulators share the Mac's network; a two-iPhone run on real Wi-Fi is a device leg.

## Test plan

1. Unit: `HouseholdSyncProtocolTests` (framing, KDF vectors, seal/open, tamper), `HouseholdSyncMachineTests`
   (converge, idempotent re-sync, relay, join, wrong key, expired/burnt token), `HouseholdInviteTests`,
   `HouseholdLoopbackSyncTests` (real sockets), backup + store additions.
2. UI: `HouseholdUITests` additions (members tab, invite sheet with QR + Copy link).
3. Two simulators: boot two, install, create chores on A, invite → pbpaste the link → `simctl openurl` on B → confirm → both show the same board; tick on B, Sync now on A → A shows it.
4. Device leg (owed): MrRobot + a second iPhone on home Wi-Fi.
