# Household op log: wire format v1

The Household mini-app's data is an append-only log of operations ("ops"). Phones keep the whole log,
fold it into the board (`ChoreBoard.fold`), and sync by swapping version vectors and sending the ops
the other side is missing. This file is the contract between implementations: Swift today
(`ios/App/Snappet/Features/Household/ChoreLog.swift`), Kotlin in P4. The examples below are pinned
byte for byte by `SnappetTests/HouseholdWireFormatTests.swift`.

## One op

One JSON object per op. Writers emit **sorted keys**, no insignificant whitespace, no escaped slashes,
UTF-8 (emoji are written raw). Readers must not depend on key order.

| Key | Type | Meaning |
|---|---|---|
| `v` | int | Wire version. Always `1`. A reader rejects any other value. |
| `id` | uuid | The op's id. Folding dedupes on it. |
| `device` | uuid | The phone that wrote it. |
| `seq` | int | Per-device counter starting at 1, no gaps. Version vectors are `device → max seq`. |
| `at` | string | ISO-8601 UTC with milliseconds, `2026-10-04T18:30:00.250Z`. Readers also accept no milliseconds. |
| `kind` | string | One of the kinds below. |

UUIDs are written lowercase; readers accept either case. Keys a kind doesn't use are absent.

## Kinds

| `kind` | Extra keys | Effect |
|---|---|---|
| `add_member` | `member`, `name` | Adds (or renames) a member. Members list in first-added order. |
| `create_chore` | `chore`, `fields` | Creates a chore. Always the base, even if an edit has an earlier `at`. |
| `edit_chore` | `chore`, `fields` | Sets only the fields present. Per field, the latest op wins. |
| `archive_chore` | `chore` | Archives the chore. Sticky: beats any concurrent edit. |
| `complete` | `chore`, `member` | A tick. |
| `undo` | `op` | Retracts a `complete` or `claim` by its op id. |
| `claim` | `chore`, `member` | "I'll do it" for an up-for-grabs chore. Lasts until the chore is next done. |
| `set_goal` | `week`, `target`, `reward` | The house goal for the week starting `week` (`yyyy-MM-dd`, the calendar's first weekday). Latest wins. |
| `rename_household` | `name` | The shared household name (prompt 157). Latest non-empty wins. |
| `ask_help` | `chore`, `member`, `note` | Prompt 158: `member` asks for a hand. Open until the chore is next done, someone else claims it, a newer request replaces it, or `undo`. |
| `thank` | `member`, `by`, optional `chore` | A thank-you from `by` to `member`. `undo` retracts it. |
| `pause_house` | optional `until` (`yyyy-MM-dd`, inclusive) | The house on holiday from this op's time: nothing is overdue, and a week mostly paused neither breaks nor extends the streak. Ignored if already paused open-endedly. |
| `resume_house` | (none) | Ends the open pause. |
| `name_pet` | `name` | The house pet's name. Latest non-empty wins. |
| `start_power_hour` | `ends` (ISO-8601, like `at`), `target` | Prompt 159: a power hour from this op's time until `ends`. A start while one is running ends that one at this op's time. A start whose `ends` isn't after `at` is ignored; one without a readable `ends` folds as unknown. |
| `end_power_hour` | (none) | Ends the running power hour at this op's time. |

A reader that meets an unknown `kind` keeps the op (stores it, counts it in version vectors, relays it)
and ignores it when folding. That's how a newer app's ops survive an older phone.

### `fields`

| Key | Values |
|---|---|
| `name`, `emoji`, `room` | strings (`room` `""` = anywhere) |
| `effort` | `"s"` (1 point), `"m"` (2), `"l"` (3) |
| `repeats` | `{"mode":"daily"}` · `{"mode":"weekdays","days":[2,5]}` (Calendar weekdays, 1 = Sunday) · `{"mode":"weekly"}` · `{"mode":"after_done","every":14}` · `{"mode":"once"}` |
| `assignment` | `{"mode":"rotate","members":[…]}` · `{"mode":"fixed","member":"…"}` · `{"mode":"up_for_grabs"}` |

| `lean` | `true` / `false` (prompt 158): a rotating chore goes to whoever in its rotation has the fewest effort points this week (ties → rotation order) |

An unknown `effort`, `repeats.mode` or `assignment.mode` drops that one field; the rest of the op applies.

## Ordering and merging

Every phone folds ops in the same total order: `at`, then `device` (as an uppercase UUID string), then
`seq`. Folding is order-independent and idempotent: any permutation or duplication of the same ops
gives the same board.

A chore's completions group into **rounds**: the same day (daily, weekdays), the same week (weekly),
before the round's first tick + N days (after done), or ever (once). Everyone who ticked in a round is
credited (XP is per credited member); the round counts **once** toward the house goal, on the day it was
first done. So two people doing the fridge while apart is never a conflict.

## Examples

```json
{"at":"2026-10-04T08:00:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000001","kind":"add_member","member":"00000000-0000-0000-0000-0000000000a1","name":"Alex","seq":1,"v":1}
{"at":"2026-10-04T08:01:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d1","fields":{"assignment":{"mode":"up_for_grabs"},"effort":"l","emoji":"🧊","name":"Clean the fridge","repeats":{"every":14,"mode":"after_done"},"room":"Kitchen"},"id":"00000000-0000-0000-0000-000000000002","kind":"create_chore","seq":2,"v":1}
{"at":"2026-10-04T08:02:00.000Z","chore":"00000000-0000-0000-0000-0000000000c2","device":"00000000-0000-0000-0000-0000000000d1","fields":{"assignment":{"members":["00000000-0000-0000-0000-0000000000a1","00000000-0000-0000-0000-0000000000a2"],"mode":"rotate"},"effort":"s","emoji":"🍽️","name":"Dishes","repeats":{"days":[2,5],"mode":"weekdays"},"room":"Kitchen"},"id":"00000000-0000-0000-0000-000000000003","kind":"create_chore","seq":3,"v":1}
{"at":"2026-10-04T09:30:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d2","fields":{"effort":"m"},"id":"00000000-0000-0000-0000-000000000004","kind":"edit_chore","seq":1,"v":1}
{"at":"2026-10-04T18:30:00.250Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d2","id":"00000000-0000-0000-0000-000000000005","kind":"complete","member":"00000000-0000-0000-0000-0000000000a2","seq":2,"v":1}
{"at":"2026-10-04T18:31:00.000Z","device":"00000000-0000-0000-0000-0000000000d2","id":"00000000-0000-0000-0000-000000000006","kind":"undo","op":"00000000-0000-0000-0000-000000000005","seq":3,"v":1}
{"at":"2026-10-04T19:00:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000007","kind":"claim","member":"00000000-0000-0000-0000-0000000000a1","seq":4,"v":1}
{"at":"2026-10-04T19:05:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000008","kind":"set_goal","reward":"Pizza night","seq":5,"target":40,"v":1,"week":"2026-09-28"}
{"at":"2026-10-04T19:10:00.000Z","chore":"00000000-0000-0000-0000-0000000000c2","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000009","kind":"archive_chore","seq":6,"v":1}
```

Later kinds (prompts 157–158), pinned by `testLaterKindsRoundTripAndDecode`:

```json
{"at":"2026-10-05T08:00:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-00000000000a","kind":"rename_household","name":"Flat 4B","seq":7,"v":1}
{"at":"2026-10-05T08:01:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d1","fields":{"lean":true},"id":"00000000-0000-0000-0000-00000000000b","kind":"edit_chore","seq":8,"v":1}
{"at":"2026-10-05T08:02:00.000Z","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d2","id":"00000000-0000-0000-0000-00000000000c","kind":"ask_help","member":"00000000-0000-0000-0000-0000000000a2","note":"Away till Tue","seq":4,"v":1}
{"at":"2026-10-05T08:03:00.000Z","by":"00000000-0000-0000-0000-0000000000a2","chore":"00000000-0000-0000-0000-0000000000c1","device":"00000000-0000-0000-0000-0000000000d2","id":"00000000-0000-0000-0000-00000000000d","kind":"thank","member":"00000000-0000-0000-0000-0000000000a1","seq":5,"v":1}
{"at":"2026-10-05T08:04:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-00000000000e","kind":"pause_house","seq":9,"until":"2026-10-11","v":1}
{"at":"2026-10-05T08:05:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-00000000000f","kind":"resume_house","seq":10,"v":1}
{"at":"2026-10-05T08:06:00.000Z","device":"00000000-0000-0000-0000-0000000000d1","id":"00000000-0000-0000-0000-000000000010","kind":"name_pet","name":"Biscuit","seq":11,"v":1}
```

Folded, the first block gives: one active chore ("Clean the fridge", effort `m`, claimed by Alex, no live
completions because the tick was undone), Dishes archived, and a 40-chore goal for the week of 28 Sep.

## Sync protocol (v1, prompt 157)

Phones talk over TCP, found by Bonjour. Everything below is what a second implementation must match.

### Discovery

- Service type `_snappet-hh._tcp`, instance name = the phone's device id (lowercase UUID).
- TXT record: `v=1`; `hh` = household tag; `inv` = invite tag, only while an invite is open.
- Tag = first 8 bytes of `HMAC-SHA256(key: secret, message: label)`, lowercase hex. Labels:
  `snappet-household-tag-v1` (secret = household key) and `snappet-household-invite-v1` (secret = invite token).
- For discovery-triggered syncs only the phone with the smaller device id (string compare of the
  uppercase UUID) dials. A local change or "Sync now" dials every visible member.

### Invite link

`snappet://household/join?v=1&h=<household uuid>&n=<name>&t=<32-byte token, base64url, no padding>&e=<expiry, unix seconds>`.
The token is single-use, valid 5 minutes, and held only by the inviter. **The household key is never in
the link.**

### Frames

Each frame is a 4-byte big-endian length, then the payload. A length over 1 MiB closes the connection.

### Handshake

1. Dialer → listener, plaintext JSON: `{"t":"hello","v":1,"mode":"sync"|"join","device":"…","nonce":"<32 bytes, base64>"}`
2. Listener → dialer, plaintext: `{"t":"hello","v":1,"device":"…","nonce":"…"}`. If the listener has no
   secret for that mode, it sends `{"t":"reject","reason":"invite_closed"|"not_a_member"}` instead and closes.
3. Keys: `HKDF-SHA256(ikm: secret, salt: dialerNonce ‖ listenerNonce, info: label, length: 32)` with labels
   `snappet-hh-v1 d2l` (dialer → listener) and `snappet-hh-v1 l2d` (listener → dialer). The secret is the
   household key (`sync`) or the invite token (`join`).
4. Every later frame is a ChaCha20-Poly1305 sealed box: `nonce (12, random) ‖ ciphertext ‖ tag (16)`, no
   associated data, over one JSON message.
5. Each side's first sealed message is `{"t":"auth","device":"<its hello device>"}`. If the peer's auth
   doesn't open, the secret differs: close. Nothing about the household is sent before the peer's auth opens.

Test vector (secret = 32 × `0x01`, dialer nonce = 32 × `0x02`, listener nonce = 32 × `0x03`):

| | |
|---|---|
| d2l key | `42473905e765b737085a5f6d37b5644405dd34f767ae769f0224bc3e9025010e` |
| l2d key | `fdc39f71f0d96562ae664017149b9ddde56f926584971dfdd7844b8f9d964d27` |
| household tag | `04c02450e3f9af29` |

### Conversation (sealed messages)

- **join only:** after the dialer's auth, the listener sends
  `{"t":"welcome","household":"<uuid>","name":"…","key":"<32 bytes, base64>"}` and burns the token. The
  joiner creates the household with its own new device and member ids and appends `add_member` for itself.
- Both: `{"t":"state","vv":{"<device>":<max seq>,…},"member":"…","name":"…","platform":"ios"|"android"}`.
- Each side answers the other's `state` with the ops the peer is missing (`seq > vv[device]`), as
  `{"t":"ops","ops":["<op JSON>",…]}` in chunks of roughly 256 KB. **Op strings are the stored bytes verbatim**,
  so unknown kinds pass through unchanged.
- Then `{"t":"done"}`. When a side has sent and received `done`, the conversation is over; the dialer closes.
- Receivers ignore message types they don't know.

## Changing the format

Additive changes that old readers can ignore (a new `kind`, a new optional key) keep `v: 1`. Anything
an old reader would misread needs `v: 2`, a migration test, and an update here.
