# SnappetAI — Privacy Policy

**Effective date:** June 15, 2026
**Last updated:** November 22, 2026

SnappetAI ("the app", "we", "us") is built around a simple principle: **your data stays on your
device, or in cloud storage that belongs to you.** This policy explains what the app accesses, why, and what we do — and do not — do with it.

## The short version

- **No SnappetAI account. No sign-up. No servers.** SnappetAI has no backend. We do not have a server
  that receives, stores, or processes your data.
- **Everything is processed and stored locally** on your iPhone and Apple Watch. Your workouts,
  heart-rate data, photos, videos, highlight reels, journal entries, habits, expenses, and budgets
  leave your device only when **you** export or share them, or when you turn on one of the optional
  backups to **your own** iCloud or Google Drive (described below). Both are off until you switch
  them on.
- **Signing in with Google is optional** and is used only for those Google Drive features. The app
  works fully without it.
- **No analytics, no tracking, no advertising, and no data-collecting third-party SDKs.** (The app
  bundles an on-device machine-learning runtime to generate climbs; it makes no network calls and
  collects nothing.)
- **We never sell, rent, or share your data with anyone.**

## Data the app accesses (and why)

All access is requested just-in-time, with the system permission prompt, and is used only on your
device for the feature you invoked:

- **Health data (Apple HealthKit)** — with your permission, the app reads heart-rate, resting
  heart-rate, and workout data to build heart-rate-driven highlight reels, show your workout summary,
  and estimate effort/energy. On Apple Watch, the app may write a workout session so heart rate keeps
  streaming during a workout. **HealthKit data is processed on your device and is never used for
  advertising or marketing, nor shared or sold to any third party.** It leaves your device in one
  case only: if you turn on Automatic backup *and* switch on "Include heart-rate samples", the
  heart-rate samples saved with your workouts are included in the encrypted backup in your own cloud
  storage. That switch is off by default.
- **Photos & videos (Photo Library)** — with your permission, the app reads photos/videos shot during a
  workout to assemble highlight reels, and can save a finished reel back to your library. Media is read
  and rendered on-device. Nothing is uploaded unless you switch on "Keep clip copies in Google Drive"
  (below).
- **Camera** — used only if you scan a receipt in the expense tools. Images are processed on-device
  (text recognition) and are not uploaded.
- **Bluetooth** — used only to connect to accessories you choose: a heart-rate monitor or chest strap
  for live heart rate, and a climbing board or training device you connect in the app.
- **Local network** — used only if you share a household in the Household app, to find the other
  phones in that household on the same Wi-Fi (see below).
- **Notifications** — used only for workout/rest and focus-timer alerts you start.

## What leaves your device — only when you choose

The only time content leaves your device is when **you** take an explicit action:
- **Sharing or exporting** a highlight reel, a workout, or other content via the iOS share sheet
  (e.g., saving to Photos, AirDrop, Messages). What happens to it then is governed by the destination
  you pick, not by SnappetAI.
- **Automatic backup (optional, off by default).** If you turn it on in Apps → Cloud & Backup,
  SnappetAI keeps a copy of your records (workouts, climbing, journal, habits, finance, and the rest
  of the app's database) in **your own iCloud Drive**. The copy is encrypted on your iPhone before it
  leaves, with a key stored in your keychain; we cannot read it and it is never sent to us.
  Heart-rate samples are left out unless you switch on "Include heart-rate samples". Photos and
  videos are not part of it.
- **Automatic backup to Google Drive (optional).** The same encrypted backup can go to your Google
  Drive instead of iCloud. It is stored in a private app folder that only SnappetAI can read;
  SnappetAI cannot see your other Drive files.
- **Clip copies in Google Drive (optional, off by default).** If you switch on "Keep clip copies in
  Google Drive", SnappetAI copies your session photos and videos to a "Snappet Clips" folder in your
  own Google Drive, and can play or bring back a clip from there after it has been removed from your
  iPhone. These are ordinary files you can see and delete in Drive; they are **not encrypted** by
  SnappetAI.
- **iCloud device backup**, if you have it enabled for the device, may include the app's local data — this is
  Apple's encrypted backup, governed by Apple's privacy policy.

## Google sign-in and Google user data

Signing in with Google is optional and happens in the system browser sheet; SnappetAI never sees your
Google password. When you sign in, SnappetAI asks for only the following, and uses each only for the
feature named:

- **Your email address** — shown in the app so you can see which account is connected. It is stored
  on your iPhone and sent nowhere else.
- **A private app folder in your Google Drive** — to store and read back the encrypted Automatic
  backup.
- **Files SnappetAI itself creates in your Google Drive** — the "Snappet Clips" folder and the clip
  copies in it. SnappetAI cannot see or change any other file in your Drive.
- **Items you choose in Google Photos** — only if you use "Pick from Google Photos" to find footage
  that is no longer on your iPhone. SnappetAI reads only the photos and videos you select in Google's
  own picker, and copies those that match a missing clip into your "Snappet Clips" folder. It has no
  access to the rest of your Google Photos library.

**Where it goes.** Google user data travels only between your iPhone and Google. It is never sent to
us or to anyone else: there is no SnappetAI server. Your sign-in tokens are kept in the keychain on
your iPhone.

**What we do not do.** We do not sell Google user data, do not use it for advertising, do not use it
to train AI or machine-learning models, and no person at SnappetAI can read it.

**Removing it.** "Sign out" in Apps → Cloud & Backup revokes SnappetAI's access and removes the tokens
from your iPhone. You can also remove SnappetAI at <https://myaccount.google.com/permissions>. Clip
copies are files in your own Drive that you can delete there or from the app; the encrypted backup can
be removed in Google Drive on the web, under Settings → Manage apps → this app → Delete hidden app data.

SnappetAI's use and transfer of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## What the app connects to

SnappetAI has no server of its own. Besides the optional backups above, the app makes these
connections:

- **Content files from our public website.** Festival lineups, exercise guide photos, the
  climbing-board climb catalog, and the model used to generate climbs are plain files hosted on
  GitHub Pages (the same site as this page). Downloading one sends nothing about you or your data.
  As with any website, the host (GitHub) can see the request's IP address.
- **A product page you ask about.** If you use the price check in Wardrobe, the app loads the product
  link you entered directly from that shop's website, like opening it in a browser. The shop sees an
  ordinary visit from your IP address; nothing else from the app is sent.
- **Other phones in your household.** If you share a household in the Household app, the phones in it
  exchange that household's chores and activity directly with each other over your local Wi-Fi.
  Nothing goes through a server.
- **Links you open.** Links in the app (for example to a training article) open in your browser,
  under that site's own privacy policy.

## Improving the app

To improve highlight selection, the app records — **on your device only** — which auto-generated
highlights you keep, remove, pin, reorder, or export ("highlight feedback"). This stays in the app's
local storage, is used only on-device to tune the selection algorithm for you, and is never
transmitted off your device.

## Children's privacy

SnappetAI is not directed at children under 13 and does not knowingly collect data from them. Because
there is no SnappetAI account and no server, we do not receive personal information in the first place.

## Data retention and deletion

Because all data is stored locally, **deleting the app removes its data from your device.** You can also
delete individual items (workouts, journal entries, habits, expenses, reels) within the app, and revoke
Health/Photos/Camera/Bluetooth permissions any time in iOS Settings. Copies you chose to keep in your
own iCloud or Google Drive stay there until you delete them: turn the backup off in Apps → Cloud &
Backup, then remove the copies from iCloud storage settings or from Google Drive as described above.

## Changes to this policy

If this policy changes, we will update the "Last updated" date above and post the revised version at
this URL.

## Contact

Questions about this policy or your privacy: **snappet.ai.dev@gmail.com**

*SnappetAI has no backend and collects no data on any server. This policy describes on-device behavior
and the optional copies in your own iCloud and Google Drive.*
