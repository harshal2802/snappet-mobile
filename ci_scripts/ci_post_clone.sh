#!/bin/sh

# Xcode Cloud post-clone step.
#
# The Xcode project (ios/App/Snappet.xcodeproj) is generated from ios/App/project.yml by XcodeGen and
# is gitignored, so it is NOT present in the freshly cloned repo. Generate it here — before Xcode Cloud
# resolves dependencies and builds/archives — otherwise the build fails with:
#   "Project Snappet.xcodeproj does not exist at ios/App/Snappet.xcodeproj"
#
# Xcode Cloud runs scripts in a top-level `ci_scripts/` folder automatically. Homebrew is preinstalled.
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
