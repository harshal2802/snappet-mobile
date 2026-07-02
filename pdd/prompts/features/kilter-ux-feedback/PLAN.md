# PLAN — Kilter mini-app UX feedback (real-user test, 2026-07-02)

**Created**: 2026-07-02
**Design deliverable**: `docs/ux-research/kilter-ux-feedback/wireframes.html` (approved before implementation,
per the wireframe-before-implementation rule)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

A real climber used the Kilter mini-app and reported four issues, verbatim:

1. *"connecting to the board was hard to see"*
2. *"filtering was not obvious"*
3. *"resets board to 12x14"*
4. *"most recent climbs takes a lot of screen real estate on the list"*

Each maps to a confirmed root cause in code and ships as its own prompt below. All four were approved
together off the wireframe deck and land on one feedback branch (one PR), in risk order — the pure
logic fix first, the visual changes after:

| # | Prompt | Feedback | Root cause |
|---|--------|----------|------------|
| F3 | [01-per-layout-size-memory.md](./01-per-layout-size-memory.md) | resets to 12×14 | one global `kilter.productSizeId` + `syncBoardSize()` overwrites with the layout default (lowest `product_size_id`) on layout switch **and** while the catalog is unreadable |
| F1 | [02-board-connection-visibility.md](./02-board-connection-visibility.md) | connect hard to see | the only Connect control is the 8th block down the climb-detail scroll; the browse screen has no connection surface |
| F4 | [03-compact-relight-strip.md](./03-compact-relight-strip.md) | recent climbs eat the list | the re-light rail renders ~200 pt of full cards (thumbnail + status + button) above the list |
| F2 | [04-filter-obviousness.md](./04-filter-obviousness.md) | filtering not obvious | criteria split across flat look-alike chips, a toolbar funnel among four icons, and a search field hidden behind a pull-down |

**Out of scope (follow-ups):** the Android Kilter mirror of all four (tracked separately — iOS is the
lead platform); rendered PNG shots for the wireframe deck.
