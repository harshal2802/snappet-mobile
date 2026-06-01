# Distributing Snappet via ad-hoc OTA (GitHub Release → install link)

This sets up a **"tap a link → installs on iPhone"** flow, self-hosted on GitHub Releases.
CI builds an ad-hoc-signed `.ipa` on every published release and attaches it plus an OTA
`manifest.plist`; testers install from `docs/install.html` (served by GitHub Pages).

> **Hard limits of ad-hoc** (Apple's rules, not ours):
> - Requires a **paid Apple Developer account** ($99/yr). Your project targets team `P6U6C88W9J`.
> - Installs **only on devices whose UDID is registered** in the provisioning profile (max **100
>   iPhones/year** per account). Every new tester ⇒ add their UDID, regenerate the profile, update
>   the secret, re-run the build.
> - The install page must be opened in **Safari on iOS**. The signed app lasts **1 year** (until the
>   cert/profile expires), then needs a fresh build.
> - For unlimited testers with no UDID wrangling, use **TestFlight** instead (ask and I'll wire it up).

---

## One-time setup

### 1. Apple Developer portal (https://developer.apple.com/account)
1. **Register device UDIDs** — Devices → `+`. Get a UDID from *Settings → General → About →* (tap the
   serial-number row) or via Finder/Xcode. Add every tester's iPhone.
2. **Distribution certificate** — Certificates → `+` → **Apple Distribution**. Create it, download, and
   double-click to add it to your Mac's **login keychain**.
3. **App ID** — Identifiers → ensure `com.snappet.app` exists with **HealthKit** capability enabled
   (the app's `Snappet.entitlements` requests HealthKit; the profile must match or signing fails).
4. **Ad-hoc provisioning profile** — Profiles → `+` → Distribution → **Ad Hoc** → App ID
   `com.snappet.app` → your Apple Distribution cert → **select all the devices** → name it (e.g.
   `Snappet Ad Hoc`) → download the `.mobileprovision`.
5. **Export the cert as `.p12`** — Keychain Access → find *Apple Distribution: …* → right-click →
   **Export** → `.p12`, set a password.

### 2. GitHub repository secrets
*Settings → Secrets and variables → Actions → New repository secret.* Add four:

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | `base64 -i Certificates.p12 \| pbcopy` (the exported `.p12`) |
| `P12_PASSWORD` | the password you set when exporting the `.p12` |
| `PROVISIONING_PROFILE_BASE64` | `base64 -i Snappet_Ad_Hoc.mobileprovision \| pbcopy` |
| `KEYCHAIN_PASSWORD` | any random string (a throwaway CI keychain password) |

### 3. Enable GitHub Pages (for the install link)
*Settings → Pages → Build and deployment → Source: **Deploy from a branch** → Branch: `main` → `/docs`.*
Your install page is then `https://harshal2802.github.io/snappet-mobile/install.html`.

---

## Cutting a release

1. Bump the version if you like: `MARKETING_VERSION` in `ios/App/project.yml`.
2. Create a release: `gh release create v0.1.0 --title "Snappet v0.1.0" --notes "First test build"`
   (or use the GitHub UI). Publishing it triggers **`.github/workflows/release-ipa.yml`**.
3. The workflow signs, exports `Snappet.ipa`, builds `manifest.plist`, and attaches both to the release.
4. **Share this link** (the workflow also prints it in its log):
   ```
   https://harshal2802.github.io/snappet-mobile/install.html?tag=v0.1.0
   ```
   Testers open it in Safari → **Install on iPhone** → trust the developer in
   *Settings → General → VPN & Device Management*.

You can also re-run for an existing tag from the **Actions** tab → *Release IPA (ad-hoc OTA)* → *Run
workflow* → enter the tag.

---

## Adding a new tester later
Register their UDID (step 1.1) → regenerate the Ad Hoc profile to include it (step 1.4) → update the
`PROVISIONING_PROFILE_BASE64` secret → re-run the workflow for the tag. The cert/`.p12` is unchanged.

## Troubleshooting
- **"Unable to install"** on the device → its UDID isn't in the profile, or the profile/app-ID is
  missing the HealthKit capability.
- **Export fails with a signing error** → `CODE_SIGN_IDENTITY`/profile mismatch; confirm the `.p12` is an
  *Apple Distribution* cert and the profile is **Ad Hoc** for `com.snappet.app`.
- **Link does nothing** → not opened in Safari, or GitHub Pages isn't enabled yet, or the `?tag=` is wrong.
- **`release-testing` method rejected** → an older Xcode wants `ad-hoc`; change `method` in the
  workflow's ExportOptions step.
