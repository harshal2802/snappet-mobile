# Prompt: Root Makefile — one entrypoint for iOS + Android build / test / release

**File**: pdd/prompts/features/105-tooling-makefile-build-release.md
**Created**: 2026-06-23
**Project type**: Build tooling — a `Makefile` at the repo root that wraps the existing
XcodeGen / xcodebuild / swift / Gradle / fastlane commands. No app source changes.
**Chain**: PLAN-ios-to-shippable.md → ship (developer ergonomics; consolidates the build/release verbs)
**Context**: `pdd/context/project.md`, `pdd/context/conventions.md`, `pdd/context/decisions.md`

## Goal

The build/test/release commands for this repo are real and correct, but they're scattered across
`README.md`, `android/README.md`, `CLAUDE.md`, `ios/App/fastlane/`, and `scripts/`, with
different working directories and a fistful of `xcodebuild`/`gradlew` flags each. Make every
common job — build iOS for the simulator **or** a device, build the Android debug/release artifact,
run the test suites, and cut a release — a single discoverable `make <target>` from the repo root,
without hiding or duplicating the underlying tooling.

## Context the implementer needs

The Makefile must **wrap the commands that already exist**, not invent new ones:

- **iOS (macOS + Xcode only).** Project is generated from `ios/App/project.yml` via XcodeGen
  (`Snappet.xcodeproj` is gitignored). Scheme `Snappet` builds app + watch + widgets + test
  targets; scheme `SnappetWatch` is watch-only. Simulator dest used in the repo is
  `platform=iOS Simulator,name=iPhone 16 Pro`; a device/archive build uses
  `generic/platform=iOS`. `Package.resolved` is committed at `ios/App/Package.resolved` and
  refreshed with `xcodebuild -resolvePackageDependencies` (mirrors `ci_scripts/ci_post_clone.sh`).
- **Engine.** `ios/HighlightEngine` is a standalone SPM package — `swift test` runs anywhere Swift
  is installed (no Xcode/sim), so it must NOT be gated behind the macOS guard.
- **iOS release.** `ios/App/fastlane` defines `beta` (archive Release → TestFlight via an ASC API
  key read from env: `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH`) and `screenshots`. The
  committed identity is `com.snappet.app`; the `.alpha` TestFlight identity is applied as a local,
  uncommitted overlay via `scripts/alpha-build-overlay.sh <build>` (see decision 2026-06-15). The
  Makefile must drive both paths without committing alpha state.
- **Android.** Gradle wrapper at `android/gradlew`. Debug APK = `:app:assembleDebug`; release APK =
  `:app:assembleRelease`; Play bundle = `:app:bundleRelease`; unit tests = `:app:test`; instrumented
  Compose UI tests (needs a device/emulator) = `:app:connectedDebugAndroidTest`; `:app:lint`.
  Install+launch = `adb install -r …/app-debug.apk && adb shell am start -n com.snappet.mobile/.MainActivity`.
  `JAVA_HOME`/`ANDROID_HOME` are machine-specific (dev box uses Homebrew paths) — the Makefile must
  take them from the environment, never hardcode them.

The constraint that makes this non-trivial: iOS targets cannot run on Linux/CI-Linux, so they need a
clear, early macOS guard with an actionable message (not an opaque `xcodebuild: command not found`),
while the engine + Android + help targets stay portable. Variables (simulator name, configuration,
build number) must be overridable on the command line.

## Approach / Output

Add a single **`/Makefile`** at the repo root. No app/source/config changes.

- **Self-documenting `help` as the default goal**, grouped into sections (Meta / iOS / Android /
  Combined / Release), parsed from `##`-annotated targets so the list can't drift from the targets.
- **Overridable variables** with sane defaults: `SIMULATOR ?= iPhone 16 Pro`, `CONFIG ?= Debug`,
  `SCHEME ?= Snappet`, `BUILD ?=` (release build number), iOS/Android dirs, `GRADLE`, package id.
- **macOS guard** (`require_macos`) reused by every iOS target; engine/Android/meta targets skip it.
- **iOS targets**: `ios-generate`, `ios-resolve`, `ios` / `ios-sim` (build for sim), `ios-device`
  (build for generic device), `ios-watch`, `ios-run` (build + boot sim + install + launch),
  `engine-test` (pure `swift test`), `ios-test` (xcodebuild test on sim), `ios-archive`,
  `ios-screenshots`, `ios-release` (fastlane beta), `ios-release-alpha` (alpha overlay + beta),
  `ios-clean`. `ios-generate` runs automatically before build/test targets that need the project.
- **Android targets**: `android` / `android-debug`, `android-release`, `android-bundle`,
  `android-install`, `android-run`, `android-test`, `android-test-ui`, `android-lint`,
  `android-clean`.
- **Combined**: `build` (iOS sim + Android debug), `test` (engine + iOS + Android unit),
  `release` (iOS TestFlight + Android Play bundle), `clean`.
- **`.PHONY`** for all targets; `SHELL := /usr/bin/env bash` with `-e` so a failed sub-command stops
  the target.

Document the new entrypoint in `README.md` (point the Getting-started build blocks at `make help`,
keeping the raw commands as the "what it runs under the hood" reference) and record the
tooling-only decision in `pdd/context/decisions.md`.

## Acceptance criteria

- [ ] `make` (no args) and `make help` print a grouped, accurate target list and exit 0 on any OS.
- [ ] Every target wraps an existing, correct command (no new build logic); variables
      (`SIMULATOR`, `CONFIG`, `SCHEME`, `BUILD`) are overridable on the command line.
- [ ] iOS-only targets fail fast on non-macOS with an actionable message; `engine-test`, Android,
      and meta targets run on any OS with the right toolchain.
- [ ] `make release` cuts the iOS TestFlight build (fastlane `beta`) and the Android Play bundle
      (`bundleRelease`); `make ios-release-alpha BUILD=<n>` applies the uncommitted alpha overlay first.
- [ ] No app source / `project.yml` / Gradle config changes; committed identity stays `com.snappet.app`.
- [ ] `README.md` references `make help`; `decisions.md` records the choice.

## Constraints

- Tooling only — no Swift/Kotlin/config logic changes; the Makefile must not duplicate or fork the
  fastlane lanes, the alpha overlay, or the Gradle config, only call them.
- `JAVA_HOME` / `ANDROID_HOME` and the ASC API-key env vars are environment inputs — never hardcoded
  or committed. Alpha identity stays a local overlay (decision 2026-06-15).
- This is a build-tooling change with no user-facing surface, so the knowledge graph
  (`docs/knowledge-graph/data.js`) is intentionally not touched.

## Test plan

1. `make help`, `make` → grouped target list, exit 0 (verified on Linux + macOS).
2. `make engine-test` → runs `swift test` in `ios/HighlightEngine` on any box with Swift.
3. On macOS: `make ios-sim`, `make ios-test`, `make android-debug` build/test; `make ios-device`
   produces a device build; `make ios-release` / `make android-bundle` produce the release artifacts.
4. On Linux: an iOS target (e.g. `make ios-sim`) fails immediately with the macOS-required message;
   `make android-debug` still works with `JAVA_HOME`/`ANDROID_HOME` set.
