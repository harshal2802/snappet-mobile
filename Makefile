# Snappet Mobile — one entrypoint for iOS (+ watchOS) and Android build / test / release.
#
# This Makefile is a thin, discoverable wrapper around the tooling that already drives the repo:
# XcodeGen + xcodebuild + swift (iOS/engine), Gradle (Android), and fastlane (iOS release). It does
# NOT invent new build logic — every target maps to a command documented in README.md /
# android/README.md / CLAUDE.md / ios/App/fastlane. See pdd/prompts/features/105-tooling-makefile-build-release.md.
#
#   make            # list everything (same as `make help`)
#   make ios-sim    # build the iOS app for the simulator
#   make android    # build the Android debug APK
#   make test       # engine + iOS + Android unit tests
#   make release    # iOS → TestFlight (fastlane beta) + Android → Play bundle
#
# iOS/watchOS targets require macOS + Xcode and fail fast elsewhere. The engine (`swift test`),
# Android, and meta targets run anywhere the right toolchain is installed.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# ── Overridable configuration ────────────────────────────────────────────────
# Override on the command line, e.g.  make ios-sim SIMULATOR='iPhone 16'  CONFIG=Release
SIMULATOR ?= iPhone 16 Pro          # `xcrun simctl list devices` for installed names
CONFIG    ?= Debug                  # Debug | Release
SCHEME    ?= Snappet                # app+watch+widgets+tests; SnappetWatch is watch-only
BUILD     ?=                        # release build number (required by ios-release-alpha)

# iOS layout
IOS_DIR      := ios/App
ENGINE_DIR   := ios/HighlightEngine
PROJECT      := $(IOS_DIR)/Snappet.xcodeproj
DERIVED_DATA := $(IOS_DIR)/build/DerivedData
DEST_SIM     := platform=iOS Simulator,name=$(SIMULATOR)
DEST_DEVICE  := generic/platform=iOS
XCGEN        := xcodegen

# Android layout
ANDROID_DIR      := android
GRADLE           := ./gradlew
ANDROID_PKG      := com.snappet.mobile
ANDROID_ACTIVITY := .MainActivity
APK_DEBUG        := app/build/outputs/apk/debug/app-debug.apk

# iOS targets can't build on Linux/CI-Linux — fail with an actionable message, not an opaque
# "xcodebuild: command not found". Reused by every macOS-only recipe via `$(require_macos)`.
define require_macos
@if [ "$$(uname -s)" != "Darwin" ]; then \
	echo "✗ '$@' needs macOS + Xcode — iOS/watchOS targets can't build on $$(uname -s)."; \
	echo "  Engine tests run anywhere: 'make engine-test'. See CLAUDE.md → 'Building & testing'."; \
	exit 1; \
fi
endef

# ════════════════════════════════════════════════════════════════════════════
##@ Meta
# ════════════════════════════════════════════════════════════════════════════

.PHONY: help
help: ## List all targets (default)
	@awk 'BEGIN {FS = ":.*##"; printf "\nSnappet Mobile — make targets\n\nUsage: \033[36mmake <target>\033[0m\n"} \
		/^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@printf "\nVariables: SIMULATOR=%s  CONFIG=%s  SCHEME=%s  (override on the CLI)\n\n" "$(SIMULATOR)" "$(CONFIG)" "$(SCHEME)"

.PHONY: doctor
doctor: ## Report which toolchains are available on this machine
	@echo "OS:        $$(uname -s)"
	@printf "swift:     "; command -v swift      >/dev/null 2>&1 && swift --version | head -1 || echo "— (engine tests need Swift)"
	@printf "xcodegen:  "; command -v xcodegen   >/dev/null 2>&1 && xcodegen --version          || echo "— (brew install xcodegen)"
	@printf "xcodebuild:"; command -v xcodebuild >/dev/null 2>&1 && echo " present"             || echo " — (iOS builds need Xcode/macOS)"
	@printf "fastlane:  "; command -v fastlane   >/dev/null 2>&1 && echo "present"              || echo "— (iOS release needs fastlane)"
	@printf "java:      "; [ -n "$${JAVA_HOME:-}" ] && echo "JAVA_HOME=$$JAVA_HOME"             || echo "— (set JAVA_HOME to a JDK 17)"
	@printf "android:   "; [ -n "$${ANDROID_HOME:-}" ] && echo "ANDROID_HOME=$$ANDROID_HOME"    || echo "— (set ANDROID_HOME to the SDK)"
	@printf "adb:       "; command -v adb        >/dev/null 2>&1 && echo "present"              || echo "— (Android install/run need adb)"

# ════════════════════════════════════════════════════════════════════════════
##@ iOS (+ watchOS) — requires macOS + Xcode
# ════════════════════════════════════════════════════════════════════════════

.PHONY: ios-generate
ios-generate: ## Generate Snappet.xcodeproj from project.yml (XcodeGen)
	$(require_macos)
	cd $(IOS_DIR) && $(XCGEN) generate

.PHONY: ios-resolve
ios-resolve: ios-generate ## Resolve SPM deps and refresh the committed Package.resolved
	$(require_macos)
	cd $(IOS_DIR) && xcodebuild -resolvePackageDependencies -scheme $(SCHEME) \
		&& cp Snappet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Package.resolved

.PHONY: ios ios-sim
ios: ios-sim ## Alias for ios-sim
ios-sim: ios-generate ## Build the iOS app for the simulator
	$(require_macos)
	cd $(IOS_DIR) && xcodebuild build -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination '$(DEST_SIM)' -derivedDataPath build/DerivedData

.PHONY: ios-device
ios-device: ios-generate ## Build the iOS app for a generic physical device
	$(require_macos)
	cd $(IOS_DIR) && xcodebuild build -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination '$(DEST_DEVICE)' -derivedDataPath build/DerivedData -allowProvisioningUpdates

.PHONY: ios-watch
ios-watch: ios-generate ## Build the watchOS companion (SnappetWatch scheme) for the simulator
	$(require_macos)
	cd $(IOS_DIR) && xcodebuild build -scheme SnappetWatch -configuration $(CONFIG) \
		-destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' -derivedDataPath build/DerivedData

.PHONY: ios-run
ios-run: ios-sim ## Build, boot the simulator, install + launch the app
	$(require_macos)
	@open -a Simulator
	@xcrun simctl boot '$(SIMULATOR)' 2>/dev/null || true
	@APP=$$(find $(DERIVED_DATA)/Build/Products -name 'Snappet.app' -maxdepth 3 | head -1); \
		echo "Installing $$APP"; \
		xcrun simctl install booted "$$APP"; \
		xcrun simctl launch booted com.snappet.app

# ── Tests ────────────────────────────────────────────────────────────────────

.PHONY: engine-test
engine-test: ## Run the HighlightEngine unit tests (pure SPM — no Xcode/sim, any OS)
	cd $(ENGINE_DIR) && swift test

.PHONY: ios-test
ios-test: ios-generate ## Run the full XCTest + XCUITest suite on the simulator
	$(require_macos)
	cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -configuration Debug \
		-destination '$(DEST_SIM)' -derivedDataPath build/DerivedData

.PHONY: ios-test-unit
ios-test-unit: ios-generate ## Run only the unit tests (SnappetTests), skipping the UI suite
	$(require_macos)
	cd $(IOS_DIR) && xcodebuild test -scheme $(SCHEME) -configuration Debug \
		-destination '$(DEST_SIM)' -derivedDataPath build/DerivedData -only-testing:SnappetTests

# ── Release / distribution ───────────────────────────────────────────────────

.PHONY: ios-archive
ios-archive: ios-generate ## Archive a Release build to ios/App/build (no upload)
	$(require_macos)
	cd $(IOS_DIR) && xcodebuild archive -scheme $(SCHEME) -configuration Release \
		-destination '$(DEST_DEVICE)' -archivePath build/Snappet.xcarchive -allowProvisioningUpdates

.PHONY: ios-screenshots
ios-screenshots: ios-generate ## Capture App Store screenshots (fastlane snapshot)
	$(require_macos)
	cd $(IOS_DIR) && fastlane screenshots

.PHONY: ios-release
ios-release: ios-generate ## Archive Release + upload to TestFlight (fastlane beta; needs ASC_* env)
	$(require_macos)
	@: $${ASC_KEY_ID:?set ASC_KEY_ID}   ; : $${ASC_ISSUER_ID:?set ASC_ISSUER_ID} ; : $${ASC_KEY_PATH:?set ASC_KEY_PATH}
	cd $(IOS_DIR) && fastlane beta

.PHONY: ios-release-alpha
ios-release-alpha: ## TestFlight alpha build: apply uncommitted .alpha overlay (BUILD=<n>) then fastlane beta
	$(require_macos)
	@: $${BUILD:?usage: make ios-release-alpha BUILD=<build-number>}
	@: $${ASC_KEY_ID:?set ASC_KEY_ID} ; : $${ASC_ISSUER_ID:?set ASC_ISSUER_ID} ; : $${ASC_KEY_PATH:?set ASC_KEY_PATH}
	scripts/alpha-build-overlay.sh $(BUILD)
	cd $(IOS_DIR) && APP_BUNDLE_ID=com.snappet.app.alpha fastlane beta
	@echo "⚠ Working tree is intentionally dirty from the alpha overlay — do NOT commit it."

.PHONY: ios-clean
ios-clean: ## Remove the generated project and iOS build artifacts
	rm -rf $(PROJECT) $(IOS_DIR)/build

# ════════════════════════════════════════════════════════════════════════════
##@ Android (+ Wear OS) — needs JAVA_HOME (JDK 17) + ANDROID_HOME
# ════════════════════════════════════════════════════════════════════════════

.PHONY: android android-debug
android: android-debug ## Alias for android-debug
android-debug: ## Build the debug APK (:app:assembleDebug)
	cd $(ANDROID_DIR) && $(GRADLE) :app:assembleDebug

.PHONY: android-release
android-release: ## Build the release APK (:app:assembleRelease)
	cd $(ANDROID_DIR) && $(GRADLE) :app:assembleRelease

.PHONY: android-bundle
android-bundle: ## Build the Play Store app bundle (:app:bundleRelease)
	cd $(ANDROID_DIR) && $(GRADLE) :app:bundleRelease

.PHONY: android-install
android-install: android-debug ## Install + launch the debug APK on a device/emulator (adb)
	cd $(ANDROID_DIR) && adb install -r $(APK_DEBUG) \
		&& adb shell am start -n $(ANDROID_PKG)/$(ANDROID_ACTIVITY)

.PHONY: android-run
android-run: android-install ## Alias for android-install

.PHONY: android-test
android-test: ## Run the JVM unit tests (:app:test)
	cd $(ANDROID_DIR) && $(GRADLE) :app:test

.PHONY: android-test-ui
android-test-ui: ## Run the instrumented Compose UI tests on a device/emulator
	cd $(ANDROID_DIR) && $(GRADLE) :app:connectedDebugAndroidTest

.PHONY: android-lint
android-lint: ## Run the Android linter (:app:lint)
	cd $(ANDROID_DIR) && $(GRADLE) :app:lint

.PHONY: android-clean
android-clean: ## Remove Android build artifacts (:clean)
	cd $(ANDROID_DIR) && $(GRADLE) clean

# ════════════════════════════════════════════════════════════════════════════
##@ Combined (both platforms)
# ════════════════════════════════════════════════════════════════════════════

.PHONY: build
build: ios-sim android-debug ## Build both apps (iOS simulator + Android debug)

.PHONY: test
test: engine-test ios-test android-test ## Run engine + iOS + Android unit tests

.PHONY: release
release: ios-release android-bundle ## Cut a release: iOS → TestFlight, Android → Play bundle

.PHONY: clean
clean: ios-clean android-clean ## Clean both platforms' build artifacts
