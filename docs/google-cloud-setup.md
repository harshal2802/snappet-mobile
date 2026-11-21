# Google Cloud setup for Snappet (one-time, about 15 minutes)

Snappet's Google features (Google Drive backup — prompt 268; the clip vault and Google Photos picker —
prompt 269) stay **hidden** until the build carries a Google OAuth client ID. This is how to get one.
Google's console labels move around; the names below were right in late 2026.

## 1. Project and APIs

1. Go to <https://console.cloud.google.com/> and create a project (e.g. "Snappet").
2. **APIs & Services → Library**: enable **Google Drive API**. For prompt 269 also enable
   **Google Photos Picker API**.

## 2. Consent screen (Google Auth Platform)

1. **Branding**: app name "Snappet", your support email, developer contact email.
2. **Audience**: *External*. While the status is **Testing**, add your own Google address under
   *Test users* — only listed users can sign in.
3. **Data access → Add or remove scopes**:
   - `https://www.googleapis.com/auth/drive.appdata` (backup; non-sensitive)
   - for prompt 269: `https://www.googleapis.com/auth/drive.file` (non-sensitive) and
     `https://www.googleapis.com/auth/photospicker.mediaitems.readonly`

**Testing vs. production.** In *Testing*, Google expires the sign-in after **7 days** — backups then
stop with "Sign in to Google again". That is fine for trying it out, not for daily use. *Publish
app* (Audience → Publishing status) removes the limit. With only the Drive scopes above no Google
review is needed; the Photos picker scope may require Google's verification before the public can use it.

## 3. The iOS client ID

1. **Clients → Create client → Application type: iOS**.
2. Bundle ID: `com.snappet.app` (the development build). The TestFlight build uses
   `com.snappet.app.alpha` — create a second iOS client for it when you ship.
3. Copy the **Client ID** (`1234567890-abc….apps.googleusercontent.com`). There is no client secret
   for iOS clients, and the ID is not confidential.

## 4. Put it in the build

In `ios/App/project.yml`, app target settings:

```yaml
GOOGLE_CLIENT_ID: "1234567890-abc….apps.googleusercontent.com"
```

Then `cd ios/App && xcodegen generate` and build. No URL scheme needs registering: sign-in runs in
the system browser sheet, which hands the redirect straight back to the app.

## 5. Check it

Apps → Cloud & Backup → **Back up to** now lists **Google Drive**. Choose it, tap **Sign in with
Google**, approve, and "Last backup" should appear within a few seconds. The backup lives in a hidden
app folder: it does not show in your Drive, but counts toward storage, and you can remove it under
Drive → Settings → Manage apps → Snappet → Delete hidden app data.
