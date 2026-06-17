#!/bin/sh

# Xcode Cloud post-clone step.
#
# The Xcode project (ios/App/Snappet.xcodeproj) is generated from ios/App/project.yml by XcodeGen and
# is gitignored, so it is NOT present in the freshly cloned repo. Generate it here — before Xcode Cloud
# resolves dependencies and builds — otherwise the build fails with:
#   "Project Snappet.xcodeproj does not exist at ios/App/Snappet.xcodeproj"
#
# Xcode Cloud runs scripts in a top-level `ci_scripts/` folder automatically. Homebrew is preinstalled.
set -e

echo "▸ Installing XcodeGen"
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_AUTO_UPDATE=1
brew install xcodegen

echo "▸ Generating Snappet.xcodeproj from project.yml"
cd "$CI_PRIMARY_REPOSITORY_PATH/ios/App"
xcodegen generate

echo "✅ Snappet.xcodeproj generated"
