#!/usr/bin/env bash
# Apply the LOCAL alpha-distribution overlay (com.snappet.app.alpha) on top of the production config,
# for TestFlight/alpha archives. This is NOT the committed identity — production stays com.snappet.app.
# Re-run after any `xcodegen generate` that reset the project to the committed (production) bundle ids.
#
#   Usage: scripts/alpha-build-overlay.sh <build-number>
#   Then:  cd ios/App && APP_BUNDLE_ID=com.snappet.app.alpha \
#            ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=… fastlane beta
#
# The App Store Connect record "SnappetAI" is registered under com.snappet.app.alpha (alpha phase);
# see pdd/context/decisions.md (2026-06-15 App Store publishing).
set -euo pipefail
BUILD="${1:?usage: alpha-build-overlay.sh <build-number>}"
cd "$(dirname "$0")/../ios/App"

sed -i '' \
  -e 's|com.snappet.app.watchkitapp|com.snappet.app.alpha.watchkitapp|g' \
  -e 's|com.snappet.app.widgets|com.snappet.app.alpha.widgets|g' \
  -e 's|PRODUCT_BUNDLE_IDENTIFIER: com.snappet.app$|PRODUCT_BUNDLE_IDENTIFIER: com.snappet.app.alpha|' \
  -e 's|INFOPLIST_KEY_WKCompanionAppBundleIdentifier: com.snappet.app|INFOPLIST_KEY_WKCompanionAppBundleIdentifier: com.snappet.app.alpha|' \
  -e "s|CURRENT_PROJECT_VERSION: \"[0-9][0-9]*\"|CURRENT_PROJECT_VERSION: \"${BUILD}\"|g" \
  project.yml

# The watch's static Info.plist hardcodes the companion id (GENERATE_INFOPLIST_FILE: NO ⇒ the
# INFOPLIST_KEY_ build setting is inert), so set it directly to match the .alpha phone app.
plutil -replace WKCompanionAppBundleIdentifier -string "com.snappet.app.alpha" SnappetWatch/Info.plist

/opt/homebrew/bin/xcodegen generate >/dev/null
echo "✅ Alpha overlay applied: com.snappet.app.alpha, build ${BUILD}."
echo "   Working tree is intentionally dirty — do NOT commit these identity/build edits."
