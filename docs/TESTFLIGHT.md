# Distributing Snappet via TestFlight

The Apple-blessed way to share test builds: CI uploads each build to **App Store Connect**, and testers
install via the **TestFlight app** from a single link — **no device-UDID registration**, auto-updates,
up to 10,000 external testers.

Workflow: **`.github/workflows/testflight.yml`** (manual trigger). Needs a **paid Apple Developer
account** (team `P6U6C88W9J`).

> TestFlight vs. ad-hoc OTA (`docs/OTA-RELEASE.md`): TestFlight = any tester, one link, but builds go
> through Apple review/processing and (for external testers) a one-time Beta App Review. Ad-hoc =
> instant install but only on pre-registered devices. You can keep both.

---

## One-time setup

### 1. App record in App Store Connect (https://appstoreconnect.apple.com)
**My Apps → `+` → New App** → platform iOS → bundle ID `com.snappet.app` (must already exist as an App
ID under your team) → fill name/SKU. You don't need to submit to the App Store — TestFlight only.

### 2. App Store provisioning profile (Developer portal)
Profiles → `+` → **App Store** distribution → App ID `com.snappet.app` → your **Apple Distribution**
cert (the same `.p12` you use for ad-hoc) → name it (e.g. `Snappet App Store`) → download.

### 3. App Store Connect API key
*App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → `+`.*
Give it the **App Manager** role. Download the `AuthKey_XXXXXX.p8` (**one-time download**). Note the
**Key ID** and, at the top of the page, the **Issuer ID**.

### 4. GitHub repository secrets
*Settings → Secrets and variables → Actions.* TestFlight reuses three secrets from the ad-hoc setup
(`BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`) and adds four:

| Secret | Value |
|---|---|
| `APPSTORE_PROFILE_BASE64` | `base64 -i Snappet_App_Store.mobileprovision \| pbcopy` |
| `ASC_KEY_ID` | the API Key ID (e.g. `ABC123XYZ9`) |
| `ASC_ISSUER_ID` | the Issuer ID (a UUID) |
| `ASC_KEY_P8_BASE64` | `base64 -i AuthKey_ABC123XYZ9.p8 \| pbcopy` |

*(Plus the shared three from `docs/OTA-RELEASE.md`: the `.p12` cert, its password, and a keychain password.)*

---

## Shipping a build
1. **Actions** tab → **TestFlight** → **Run workflow** (optionally type a "What to Test" note).
2. CI archives with build number = the GitHub run number (always unique), exports an App Store-signed
   `.ipa`, and uploads it to App Store Connect.
3. After Apple finishes processing (~5–15 min), the build shows under **TestFlight** in App Store Connect.
4. Add testers:
   - **Internal** (up to 100, your team members): add them to a TestFlight internal group — instant, no review.
   - **External** (up to 10,000): create a public link under TestFlight → testers tap it and install via
     the TestFlight app. The first external build needs a one-time **Beta App Review**.

## Notes & troubleshooting
- **Bundle ID** `com.snappet.app` must be registered to your team and have a matching App record + App
  Store profile. If it's taken by another team, change `PRODUCT_BUNDLE_IDENTIFIER` (`ios/App/project.yml`)
  and `BUNDLE_ID` (the workflow), and recreate the App ID/record/profile.
- **HealthKit**: the App ID must have the HealthKit capability (the app's entitlements request it), or
  signing/upload fails.
- **Encryption compliance**: already handled — `ITSAppUsesNonExemptEncryption = false` is set in
  `Info.plist` (the app does no custom crypto), so App Store Connect won't prompt per build.
- **"Redundant binary / build number already used"**: shouldn't happen (build = run number), but if you
  re-run an old run, bump by triggering a fresh run.
- **`app-store-connect` method rejected** → an older Xcode wants `app-store`; change `method` in the
  workflow's ExportOptions step.
