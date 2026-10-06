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

A reader that meets an unknown `kind` keeps the op (stores it, counts it in version vectors, relays it)
and ignores it when folding. That's how a newer app's ops survive an older phone.

### `fields`

| Key | Values |
|---|---|
| `name`, `emoji`, `room` | strings (`room` `""` = anywhere) |
| `effort` | `"s"` (1 point), `"m"` (2), `"l"` (3) |
| `repeats` | `{"mode":"daily"}` · `{"mode":"weekdays","days":[2,5]}` (Calendar weekdays, 1 = Sunday) · `{"mode":"weekly"}` · `{"mode":"after_done","every":14}` · `{"mode":"once"}` |
| `assignment` | `{"mode":"rotate","members":[…]}` · `{"mode":"fixed","member":"…"}` · `{"mode":"up_for_grabs"}` |

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

Folded, these give: one active chore ("Clean the fridge", effort `m`, claimed by Alex, no live
completions because the tick was undone), Dishes archived, and a 40-chore goal for the week of 28 Sep.

## Changing the format

Additive changes that old readers can ignore (a new `kind`, a new optional key) keep `v: 1`. Anything
an old reader would misread needs `v: 2`, a migration test, and an update here.
