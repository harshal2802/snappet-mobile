#!/bin/sh

# Xcode Cloud post-clone step.
#
# The Xcode project (ios/App/Snappet.xcodeproj) is generated from ios/App/project.yml by XcodeGen and
# is gitignored, so it is NOT present in the freshly cloned repo. Generate it here — before Xcode Cloud
# resolves dependencies and builds/archives — otherwise the build fails with:
#   "Project Snappet.xcodeproj does not exist at ios/App/Snappet.xcodeproj"
# Then install the committed Package.resolved: Xcode Cloud DISABLES automatic package resolution and
# requires a Package.resolved (at Snappet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/), but that
# lives inside the generated/gitignored project — so the committed ios/App/Package.resolved is copied in.
#
# Xcode Cloud resolves `ci_scripts/` relative to the Xcode project, so when the project is in a
# subfolder it looks in `ios/App/ci_scripts/` (NOT the repo root). This script therefore lives in BOTH
# `ios/App/ci_scripts/` (where Xcode Cloud finds it) and the repo root (fallback); keep them identical.
# Homebrew is preinstalled.
# `-e` aborts on any error; `-x` traces every command into the Xcode Cloud build log so a failure here
# is diagnosable (instead of surfacing only as a confusing downstream "project does not exist").
set -ex

echo "▸ Installing XcodeGen"
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_AUTO_UPDATE=1
brew install xcodegen

# Homebrew's bin is NOT reliably on PATH in Xcode Cloud's non-login /bin/sh, so `xcodegen` can be
# "command not found" → `set -e` aborts → the project is never generated → the archive then fails with
# "project does not exist". Resolve Homebrew's prefix and put it on PATH explicitly (the documented
# repo gotcha: xcodegen lives at $(brew --prefix)/bin, e.g. /opt/homebrew/bin).
BREW_PREFIX="$(brew --prefix)"
export PATH="$BREW_PREFIX/bin:$PATH"
command -v xcodegen
xcodegen --version

echo "▸ Generating Snappet.xcodeproj from project.yml"
cd "$CI_PRIMARY_REPOSITORY_PATH/ios/App"
xcodegen generate

# Verify generation actually produced the project — fail LOUDLY here rather than letting the build hit
# the opaque "Project Snappet.xcodeproj does not exist" error later.
if [ ! -d "Snappet.xcodeproj" ]; then
  echo "✗ Snappet.xcodeproj was NOT generated — see the xcodegen output above" >&2
  ls -la
  exit 1
fi
echo "✅ Snappet.xcodeproj generated"

# Install the COMMITTED Package.resolved into the generated project. Xcode Cloud DISABLES automatic
# package resolution at the environment level, so `xcodebuild -resolvePackageDependencies` here can't
# generate it (same "a resolved file is required" error). The lock lives at ios/App/Package.resolved
# (refresh it locally with `xcodebuild -resolvePackageDependencies` when a package version changes).
echo "▸ Installing committed Package.resolved"
RESOLVED_SRC="$CI_PRIMARY_REPOSITORY_PATH/ios/App/Package.resolved"
# Fail LOUDLY with the exact fix if the committed lock is missing/stale-deleted, instead of letting the
# build hit the opaque "a resolved file is required when automatic dependency resolution is disabled".
# (`set -e` + `cp` would abort anyway, but only with a bare "No such file or directory".)
if [ ! -f "$RESOLVED_SRC" ]; then
  echo "✗ ios/App/Package.resolved is missing — Xcode Cloud disables automatic package resolution and cannot build without it." >&2
  echo "  Refresh it locally and recommit (do this whenever a package version in project.yml changes):" >&2
  echo "    cd ios/App && xcodegen generate && xcodebuild -resolvePackageDependencies \\" >&2
  echo "      && cp Snappet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Package.resolved" >&2
  exit 1
fi
SWIFTPM_DIR="Snappet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$SWIFTPM_DIR"
cp "$RESOLVED_SRC" "$SWIFTPM_DIR/Package.resolved"
echo "✅ Package.resolved installed"
