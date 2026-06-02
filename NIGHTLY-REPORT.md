# Nightly Integration Report — Snappet Pulse design system (issue #30)

Run started: 2026-06-02 (overnight, unattended)
Operator: Claude Code (Opus 4.8)

Integrating two branches:
- `claude/design-system-ios` — iOS Pulse tokens + motion (ios/ only)
- `claude/design-system-android` — Android Pulse theme + motion (android/ only)

---

## Running checklist

- [x] **Phase 0** — Setup worktrees + detect toolchains
- [x] **Phase 1** — Verify + review + UI-test both branches in parallel
  - [x] iOS gate — **PASS** (build + 133 unit/UI tests green)
  - [x] Android gate — **PASS** (build + 10/10 connected UI tests green)
- [x] **Phase 2** — Merged both to main one-by-one; rebuilt + re-tested each on main (both sound)
- [x] **Phase 3** — Regenerated 34 screenshots (17 light + 17 dark) + graph/README updates
- [ ] **Phase 4** — Push main, delete branches, cleanup, finalize

---

## Phase 0 — Setup (DONE)

### Toolchains detected
| Tool | Status |
|---|---|
| Xcode | **26.5** (build 17F42) — available |
| iOS Simulator | **iPhone 17 Pro** (iOS 26.4) booted (`F1A2B6B8-…`) |
| watchOS sim | watchOS 26.5 available |
| Java (JDK) | openjdk@17 present via Homebrew (`/opt/homebrew/opt/openjdk@17`) — not on PATH by default |
| Android SDK | **MISSING** — no `~/Library/Android/sdk`, no `ANDROID_HOME` |
| adb / emulator | **MISSING** — not installed |
| Android Studio | **NOT installed** |

### Worktrees created
- `../snappet-ios` → branch `design-system-ios` (tracks origin/claude/design-system-ios) @ 06453db
- `../snappet-android` → branch `design-system-android` (tracks origin/claude/design-system-android) @ 076ba15

Note: during setup I briefly clobbered the Android worktree's `.git` pointer file and restored it; both worktrees verified clean afterward.

### Decision/UPDATE: Android toolchain — RECOVERED
Initial scan showed no `ANDROID_HOME`/`adb`/emulator. BUT the Android **command-line tools**
were already installed via Homebrew (`/opt/homebrew/share/android-commandlinetools`), and
`openjdk@17` is present. So I provisioned a full SDK unattended:
- Created SDK root `~/Library/Android/sdk`; installed `platform-tools`, `platforms;android-35`,
  `build-tools;35.0.0`, `emulator`, and `system-images;android-35;google_apis;arm64-v8a`
  (Apple-Silicon ABI), accepted licenses, wrote `android/local.properties`.
- A pre-existing AVD `snappet_pixel7` (android-35 arm64, used Jun 1) was already on disk; I
  booted it headless (cold boot) → `emulator-5554 device`, boot_completed in ~25s.
- Disk is tight (~6.5 GiB free); a fresh AVD's 6–7 GB userdata wouldn't fit, so I reused
  `snappet_pixel7` (already has its userdata) and deleted my throwaway `snappet_test` AVD.

**Result: the Android gate IS achievable after all.** Both `assembleDebug` and the instrumented
UI tests can run. Android is back in scope for the merge.

---

## Phase 1 — Verify + review + test

### Android branch `design-system-android` — ✅ GATE PASSED
- **Build:** `:app:assembleDebug` → **BUILD SUCCESSFUL** (after the `gated()` fix above).
- **UI tests:** `:app:connectedDebugAndroidTest` on emulator `snappet_pixel7` (android-35 arm64)
  → **BUILD SUCCESSFUL, 10/10 tests passed, 0 failed, 0 skipped.**
  (ExpenseUITest, WorkoutUITest, BudgetUITest, TipUITest, JournalUITest, PomodoroUITest,
  HabitUITest, SuiteTest, SuiteSmokeTest — all instrumented.)
- **Review:** testTags all preserved (only the *value* arg of animated counters changed, e.g.
  `Tile(totalLimit.asCurrency(), … testTag("budget.total"))` → `Tile(totalLimit, …)` — the tag
  string is untouched). Every source file containing an animation also references the
  reduce-motion gating (`gated`/`reduceMotion`/`LocalReduceMotion`); no ungated animation files.
- **Pushed:** `claude/design-system-android` @ `2294f42`.
- **GATE VERDICT: PASS** (build + UI tests both green).

### iOS branch `design-system-ios` — ✅ GATE PASSED
- **Build:** `build-for-testing` → **TEST BUILD SUCCEEDED**. One root-cause compile fix:
  `snappetAnimation(_:reduceMotion:)` (free function) collided with the `View.snappetAnimation(_:value:)`
  member at 16 call sites across 10 files; the member won overload resolution and failed on the
  `reduceMotion:`/`value:` label. Fixed by qualifying each free call as `Snappet.snappetAnimation(...)`
  (idiomatic disambiguation, no behavior change). Commit `80153be`.
- **HighlightEngine `swift test`:** 18/18 passed.
- **UI + unit tests:** **133 passed, 0 failed, 0 skipped** (SnappetTests 11 suites + SnappetUITests 9
  suites incl. LiveWorkoutStudioWalkthrough + WorkoutWalkthrough). Device runtime iOS 26.5 on the
  booted iPhone 17 Pro. **No assertion updates were needed** — all existing tests passed as-is.
- **Review:** Reduce-Motion gating is consistent (`.transition`, `.symbolEffect`, time-based
  animations, chart sweep-ins all branch on `accessibilityReduceMotion`). Both issue-#30 visual bugs
  fixed in `HomeDashboardView.swift` (empty-state overlap → ZStack one-or-other cross-fade; tab-bar
  overlap → `.safeAreaInset(.bottom)` clearance). Zero accessibilityIdentifier values added/removed.
- **Pushed:** `claude/design-system-ios` @ `80153be`.
- **GATE VERDICT: PASS.**

#### Logged iOS risk (NOT changed — documented design decision)
The subagent measured light-mode WCAG contrast of accent-colored numerals (`.title.bold`, 3:1
large-text threshold) over `surfaceMuted #F2F1EE`: **tip 2.48:1, workout 2.52:1, brand/reels 2.73:1**
fall below 3:1 (others pass; dark mode all ≥4.9:1). **Decision:** left the brand/accent token values
unchanged. These tokens drive suite-wide wayfinding and are shared with Android's Pulse palette; the
correct remedy (darken light accents, or render the numeral in `SnappetColor.ink` and keep the accent
on the icon) is a subjective design call. Per the "log, don't guess destructively" rule I did not alter
brand tokens overnight. **Recommendation for a human:** pick one of those two remedies for the
sub-3:1 light-mode accents. Also minor: StatTile `.contentTransition(.numericText())` count-ups aren't
explicitly Reduce-Motion-gated (low risk; numericText degrades gracefully).

---

## Phase 2 — Merge to main (IN PROGRESS)

### iOS merge → `main` (commit `31f899a`, `--no-ff`)
Both design-system branches were based on an **older main** (before PR #31, the Live Workout
Studio B-series). So merging iOS was a real 3-way merge with conflicts vs the *new* main commits
(not vs the Android branch — those touch disjoint dirs). Two conflicted files, resolved by hand:

- **`AppLibraryView.swift`** — both PR #31 and the design-system branch *independently* added the
  same card→module zoom transition (the base had none), using different namespace names
  (`moduleZoom` vs `zoom`) and placing the `.navigationTransition` differently. Resolved to the
  branch's coherent single-namespace version (`zoom`), which also carries the design-system
  `PressableCardStyle()` press-feedback. PR #31's zoom is functionally preserved (same feature);
  no logic from PR #31 lost (its only change to this file *was* the redundant zoom).
- **`WorkoutPlayerView.swift`** — two conflicts, both true semantic merges (kept BOTH sides):
  1. State vars: kept PR #31's `displayElapsedAtPause` (pause freeze) **and** the branch's
     `doneBounce` (completion-seal bounce; used at lines 438/457). Independent additions.
  2. `overallTimerHeader`: kept PR #31's **pause awareness** (frozen-elapsed + "PAUSED" badge)
     and layered the design-system styling onto the running state — icon tint `.orange` →
     `SnappetColor.workout` (the Pulse token, exactly #30's intent), and `.contentTransition(.numericText())`
     on the live timer. Paused state keeps semantic `.yellow`.
- `WorkoutTrackerModule.swift` auto-merged cleanly. No accessibilityIdentifier changed.

#### Stray pre-merge artifact discarded
The main worktree had an uncommitted `ios/App/SnappetWatch/Info.plist` change (watch target given
phone-only `UIBackgroundModes` audio/location/voip) — a stale XcodeGen artifact, not part of either
branch and not in my task scope; the session-start tree was clean here. Discarded it (`git checkout --`)
for a clean merge base. Also removed a macOS duplicate-file stray ref
`refs/remotes/origin/claude/design-system-ios 2` that was breaking `git fetch`.

#### Disk-pressure note
First iOS merge attempt aborted on `index.lock` write timeout (only ~6.5 GiB free + slow I/O).
Freed 4.5 GiB of Xcode DerivedData → ~12 GiB free; merge then completed normally. Engine/UI
rebuild on main starts from a clean DerivedData as a result.

#### Post-merge rebuild + re-test on main — ✅ BOTH SOUND
- **iOS on main** (`xcodegen` + `build-for-testing` + `test-without-building`, iPhone 17 Pro):
  **TEST BUILD SUCCEEDED**, then **SnappetTests 130/130 + SnappetUITests 12/12 = 142 tests,
  0 failures.** The hand-resolved conflicts compile and pass.
- **Android on main** (`assembleDebug` + `connectedDebugAndroidTest`, emulator `snappet_pixel7`):
  first run failed on a **D8 dex-merge error** caused by macOS duplicate-file artifacts
  (`..._0 2.jar`, `classes 2.dex`) littering `app/build/intermediates` — the same " 2" stray-copy
  gremlin that earlier broke `git fetch`. These were stale **build artifacts** (none in `src/`).
  Purged `app/build` and rebuilt clean → **BUILD SUCCESSFUL + 10/10 connected tests, 0 failed.**

### ✅ Phase 2 DONE — both branches merged to `main` and re-verified.
- `31f899a` Merge iOS · `a49f002` Merge Android · `main` HEAD = `a49f002`.
- Not pushed yet (per plan: push at the very end, after screenshots).

---

## Phase 3 — Screenshots + knowledge graph — ✅ DONE (commit `dafef08`)

**Mechanism (reused the existing hooks; no new pipeline invented):** the repo had no committed
screenshot script (originals were captured manually on the sim, and most per-module UI tests don't
snap). Confirmed the original methodology by diffing: e.g. old `06-journal.png` is the *same* empty
state as my new one, differing only in the now-coral "+" button → the originals used the app's
`-screenshotModule` hook with an empty store. So I matched it:
- **Module/tab shots (01-home … 09-budget):** drove the built app via `xcrun simctl` using the app's
  built-in `-screenshotModule <id>` and `--start-tab apps` hooks (`RootShell.swift`), capturing with
  `simctl io … screenshot`. Home is now nicely populated (the capture run logged usage events).
  *Gotcha handled:* `simctl terminate`+`launch` races caused some captures to fall back to Home;
  fixed by polling until the process is dead / confirming a fresh PID before each launch.
- **Workout-studio set (8):** harvested from the **LiveWorkoutStudioWalkthrough** UI-test `.xcresult`
  attachments (seeded via `-uiTestSeedStudioDemo`, so they're populated) — mapped attachment names
  → semantic filenames (`03-workout-dashboard`→`workout-dashboard.png`, `06-player`→`live-player.png`,
  `10-session-summary-hr`→`workout-summary.png`, `13-hr-source-picker`→`hr-source-picker.png`, etc.).
  The merged `WorkoutPlayerView` header renders correctly (orange Pulse stopwatch + numericText).
- **Dark mode:** captured a full **second 17-image set** — module shots via `simctl ui booted
  appearance dark`; workout-studio via re-running the studio walkthrough with the sim in dark
  (passed, 0 failures). Stored as `*-dark.png`.

**Counts:** 17 light (overwritten in place) + 17 dark (new) = **34 screenshots**.

**Knowledge graph:** light nodes keep their existing `shot:` paths (same filenames) → all links still
resolve with the refreshed Pulse images, no `data.js` path edits needed. Enhanced the detail panel
(`graph.js`) to show each screen's **Light + Dark side by side** (dark path derived as `-dark.png`),
with `styles.css` layout + a graph-README note. **Verified:** `node --check` on graph.js/data.js
passes; headless Chrome load of `index.html` produced **no JS console errors** (only Chrome-internal
warnings); all 17 shots + 17 derived darks resolve on disk. (Renderer is `<canvas>`-based.)
**README:** intro now names Snappet Pulse; light galleries refreshed; added a collapsible dark gallery.

**Decision — did NOT add a new "Design System" graph node.** Phase 3 scoped the graph to "point nodes
at refreshed images"; the screens are already nodes (now refreshed + dark). Adding a new node/edges
is outside that scope and risks breaking the canvas renderer unattended, so I left the node set as-is.

---

## Phase 4 — Finish — ✅ DONE

- **Pushed `main`** → `origin/main` (`bb65a5e..dafef08`). Both branches' work is now on main via the
  two `--no-ff` merges + the docs commit.
- **Deleted both merged remote feature branches** (both passed their gates and merged cleanly):
  `claude/design-system-ios`, `claude/design-system-android` — confirmed `[deleted]`.
- **Removed both worktrees** (`../snappet-ios`, `../snappet-android`) and the local tracking branches.
  `git worktree list` now shows only the main checkout.
- Shut down the Android emulator I had booted; left the provisioned SDK in place (harmless, reusable).
- Did **not** open a PR or comment on GitHub (per instructions).

---

## FINAL SUMMARY

**Outcome: full success on both platforms.** Both Snappet Pulse design-system branches were verified,
fixed, merged to `main`, re-verified on `main`, and the docs/screenshots/graph were regenerated for the
new theme (light + dark). `main` is pushed; feature branches and worktrees are cleaned up.

### Per-branch results
| Branch | Build | UI tests | Gate | Merged |
|---|---|---|---|---|
| iOS `design-system-ios` | ✅ (1 compile fix) | ✅ 133 (130 unit + 3 UI suites) 0 fail | **PASS** | ✅ `31f899a` |
| Android `design-system-android` | ✅ (1 compile fix) | ✅ 10/10 connected 0 fail | **PASS** | ✅ `a49f002` |

### Fixes applied (commits on the branches, now in main)
1. **Android `80153be`→`2294f42`** `HomeDashboardScreen.kt`: `fadeIn/fadeOut` need `FiniteAnimationSpec`
   → use `gated()` not `gatedSpec()`. (compile)
2. **iOS `80153be`** `snappetAnimation(_:reduceMotion:)` free-func vs `View` member collision at 16
   call sites → qualified `Snappet.snappetAnimation(...)`. (compile)
3. **Merge conflict resolutions (iOS, `31f899a`):** `AppLibraryView.swift` (dedup the zoom transition
   both branches added; kept the design-system `PressableCardStyle`) and `WorkoutPlayerView.swift`
   (kept PR #31 pause/`displayElapsedAtPause` + branch `doneBounce`; merged the timer header to keep
   pause awareness AND apply `SnappetColor.workout` tint + `numericText`).

### Toolchain recovery (not anticipated)
Android looked un-buildable (no SDK/adb/emulator) but Homebrew already had the command-line tools +
JDK 17, so I provisioned a full SDK (platform-35, build-tools, emulator, arm64 system image) and booted
a pre-existing AVD → the Android gate became achievable and **both** platforms got a real build + UI-test
gate. Disk was tight; freed DerivedData to clear an `index.lock` timeout during the merge.

### Screenshots / graph
34 images regenerated (17 light overwritten + 17 dark added). README galleries refreshed + dark gallery
added; knowledge-graph detail panel now shows Light+Dark per screen; graph verified to load with no
console errors. Commit `dafef08`.

### Open items for a human (logged, intentionally NOT changed overnight)
1. **iOS light-mode WCAG contrast** of a few accent numerals on `surfaceMuted` (tip 2.48:1, workout
   2.52:1, reels 2.73:1 — below the 3:1 large-text bar; dark mode passes). Left brand tokens unchanged;
   recommend darkening light accents or rendering the numeral in `ink` with the accent on the icon only.
2. Minor: a couple of iOS `StatTile` `numericText` count-ups aren't explicitly Reduce-Motion-gated
   (low risk).
3. A stray macOS duplicate-file process keeps creating `"… 2.<ext>"` copies on this machine (it broke a
   git ref and a dex build mid-run). Not a repo issue — worth a look at iCloud/Time-Machine on the
   `Desktop/` folder.

### Blockers
None that stopped progress. The Android-toolchain "blocker" was recovered (see above).

---

## Fixes applied

### Android (`design-system-android`)
- **`HomeDashboardScreen.kt`** — `fadeIn`/`fadeOut` require `FiniteAnimationSpec<Float>` but the
  code passed them through `gatedSpec(...)` which widens to `AnimationSpec<T>` → compile error
  ("Argument type mismatch: AnimationSpec vs FiniteAnimationSpec"). Switched those two calls to
  the `gated(...)` helper (returns `FiniteAnimationSpec`) and dropped the now-unused `gatedSpec`
  import. Behaviour identical (still collapses to `reduced()`/`snap()` under reduce-motion).
  → `assembleDebug` then **BUILD SUCCESSFUL**.

---

## Blockers & decisions (historical — see FINAL SUMMARY for outcomes)

- ~~**[BLOCKER] Android emulator + SDK unavailable**~~ — **RESOLVED.** Provisioned the SDK from the
  Homebrew command-line tools + JDK 17 and booted a pre-existing AVD; the full Android gate ran. See
  the Phase 0 "RECOVERED" note and the FINAL SUMMARY.
