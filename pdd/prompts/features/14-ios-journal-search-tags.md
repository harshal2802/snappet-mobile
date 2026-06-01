# Prompt: Journal — tags & search

**File**: pdd/prompts/features/14-ios-journal-search-tags.md
**Created**: 2026-05-31
**Project type**: Native iOS feature (Swift / SwiftUI) — code lands in this repo.
**Chain**: suite feature-completeness pass (P9 follow-up); one of six parallel mini-app increments.
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md` (§"Adding a mini-app"), `pdd/context/decisions.md`.

## Goal

Make Journal usable past a handful of entries: add **tags** to entries and **search/filter** the list by
text and tag. Today entries are title + free-form body with no way to organize or find them.

## Context the implementer needs

- Folder: `ios/App/Snappet/Features/Journal/` — `JournalRootView.swift`, `JournalEditorView.swift`, the
  inline `JournalModule`, and the `JournalEntry` `@Model` (registered in `Core/SnappetCore.swift`).
- **Model change (additive, safe):** add `var tags: [String] = []` to `JournalEntry`. SwiftData applies a
  lightweight migration for an additive property with a default; **do not** alter existing fields or the
  `SnappetSchema.models` list (the type is already registered — you only add a stored property to it).
- Pushed into the App Library's `NavigationStack`; **no nested `NavigationStack`**. The editor is a sheet.
- `core.log(module: "journal", action: "entry", …)` fires on new entries — keep that behavior.

## Approach

- **Tags on the model** — add `tags: [String]` to `JournalEntry` (normalize: trimmed, lowercased,
  de-duplicated, empties dropped).
- **Tag editor** — in `JournalEditorView`, a simple tag input (comma/return-committed chips) that reads/
  writes `entry.tags`. Show existing tags as removable chips.
- **Search + filter** — make `JournalRootView`'s list `.searchable`; filter entries whose title, body, or
  any tag contains the query (case-insensitive). Optionally a horizontal row of tag chips that filter to a
  selected tag. Keep filtering in a computed property / small helper, not inline in `body`.
- **List excerpt** — show the entry's tags (and keep the existing title/first-line display).
- Add `.accessibilityIdentifier(...)`: add button (`journal.add`), search field
  (`.searchable` is found via the search field; also tag the editor's tag input `journal.tagField`),
  editor title (`journal.titleField`) and body (`journal.bodyField`), save (`journal.save`). Keep the
  existing `journalRow` identifier.

## Output

- Edits to `Journal/JournalEntry` (`tags` property), `JournalEditorView.swift` (tag editor + identifiers),
  `JournalRootView.swift` (`.searchable` + tag filter + identifiers). New `SnappetUITests/JournalUITests.swift`.
  This prompt asset; a `decisions.md` note on the additive-migration choice.

## Acceptance criteria

- [ ] An entry can be saved with one or more tags; tags persist and render as chips.
- [ ] The list filters live by a search query matching title, body, or tag (case-insensitive).
- [ ] Existing entries (no tags) still load — additive migration doesn't wipe the store.
- [ ] add/search/tag/title/body/save controls carry stable `accessibilityIdentifier`s; `journalRow` kept.
- [ ] `xcodegen generate` + `xcodebuild build-for-testing` (iPhone 17 Pro sim) → clean (Swift 6, 0 warn);
      `JournalUITests` compiles.
- [ ] No nested `NavigationStack`; `SnappetSchema.models` unchanged; no platform imports in `HighlightEngine`.

## Constraints

- On-device only; no new dependencies. Additive model change only — never a destructive migration.

## Test plan

1. `cd ios/App && xcodegen generate && xcodebuild -scheme Snappet -sdk iphonesimulator -destination 'id=F1A2B6B8-C609-47F8-8D55-44D94C5577B4' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build-for-testing` → succeeds.
2. `JournalUITests`: create an entry with a tag → type the tag into search → assert only matching entries
   remain; clear search → all return.
