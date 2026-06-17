#!/bin/sh

# Xcode Cloud post-clone step.
#
# The Xcode project (ios/App/Snappet.xcodeproj) is generated from ios/App/project.yml by XcodeGen and
# is gitignored, so it is NOT present in the freshly cloned repo. Generate it here — before Xcode Cloud
# resolves dependencies and builds/archives — otherwise the build fails with:
#   "Project Snappet.xcodeproj does not exist at ios/App/Snappet.xcodeproj"
# Then resolve Swift packages: Xcode Cloud DISABLES automatic package resolution and requires a
# Package.resolved (at Snappet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved), but
# that lives inside the generated/gitignored project so it's never committed — so we write it here.
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

# Write Package.resolved (Xcode Cloud's resolve step has automatic resolution disabled and requires it).
echo "▸ Resolving Swift package dependencies"
xcodebuild -resolvePackageDependencies -project Snappet.xcodeproj -scheme Snappet

RESOLVED="Snappet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [ ! -f "$RESOLVED" ]; then
  echo "✗ $RESOLVED was NOT written — package resolution did not produce a resolved file" >&2
  exit 1
fi
echo "✅ Package.resolved written"
