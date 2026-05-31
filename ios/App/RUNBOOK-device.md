# Device runbook — get Snappet running on your iPhone and start collecting data

This is the concrete, step-by-step path to running the v0.1 app **on a real device** against your
real Apple Watch workouts, and pulling off the first training data. It is the runtime verification
that prompt [`01-ios-device-build-and-run.md`](../../pdd/prompts/features/01-ios-device-build-and-run.md)
(P1) describes — the first time this app has ever left a type-check.

> **Why a real device is mandatory:** HealthKit and Photos do **not** run in the iOS Simulator, and
> the flagship flow needs a real heart-rate series plus photos/videos you actually shot during a
> workout. The simulator can't do any of this. Use a physical iPhone.

## Prereqs

- **macOS + Xcode 16** (or newer) with the iOS 18 SDK installed.
- An **Apple Developer account** — a free Apple ID works for on-device development ("free signing");
  no paid membership needed just to run it on your own phone.
- A **physical iPhone** running iOS 18.0+ (not the simulator).
- A **paired Apple Watch** with **some completed workouts already recorded** (go do a walk/run/climb on
  the Watch first if you have none — the app reads *completed* workouts, not live sessions).
- At least one workout where you **shot photos or videos on your iPhone during the workout's time
  window** — that's what auto-discovery matches on.
- [Homebrew](https://brew.sh) (to install XcodeGen).

## 1. Generate and open the project

XcodeGen builds `Snappet.xcodeproj` from [`project.yml`](project.yml) so there's no `.pbxproj` churn
in git.

```bash
brew install xcodegen                 # one-time
cd ios/App && xcodegen generate && open Snappet.xcodeproj
```

## 2. Sign and run from Xcode

1. In the Project navigator, select the **Snappet** project, then the **Snappet** target →
   **Signing & Capabilities**.
2. Check **Automatically manage signing** and set your **Team** (your Apple ID).
3. The bundle id is `com.snappet.app`. If Xcode reports it's taken / can't register it, set a
   **unique** bundle id (e.g. `com.<yourname>.snappet`) — only the id changes; the HealthKit
   capability and `Info.plist` usage strings stay.
4. Plug in your iPhone (trust the Mac if prompted) and pick it as the **run destination** (top bar) —
   choose your **physical device**, not a simulator.
5. Press **Run** (Cmd-R). First run on a free account: on the phone, approve the developer profile
   under **Settings → General → VPN & Device Management**, then run again.

## 3. On-device walkthrough (the flagship flow)

1. On first launch you'll see the **onboarding** screen. Tap **Connect Health & Photos**.
2. **Health**: grant heart rate, workouts, and resting heart rate. (iOS shows Health permissions only
   once — if you skip one, re-enable later under **Settings → Health → Data Access & Devices →
   Snappet**.)
3. **Photos**: choose **Allow Full Access** (recommended — auto-discovery scans the whole library by
   time window). If you pick **Limited**, auto-discovery can't scan; the app falls back to a manual
   picker — use the **Select clips** button (or the photo+ toolbar button) on a reel to pick clips
   yourself.
4. On the workout list, **pull to refresh** to load your completed Apple Watch workouts.
5. **Open a workout that had photos/videos shot during it.** The app reads its HR series, auto-finds
   the media in the workout window, and builds a reel ranked by HR intensity.
6. Tap **Preview reel** to play the current cut in-app before exporting.
7. Optional edits: swipe ◂ to **Pin** a moment (pinned clips always stay in), swipe ▸ to **Remove**,
   tap **Edit** to **reorder**, **Regenerate** for a fresh cut, **Restore** a removed moment.
8. Tap **Share reel** to export. Snappet builds the `.mp4` and opens the system **share sheet** — save
   to Photos, AirDrop, or send it.

Every action here (proposed / removed / pinned / reordered / regenerated / exported) is logged as
training data — see below.

## 4. Where the training data lands, and how to pull it

`FeedbackStore` appends one JSON object per event to **`highlight-feedback.jsonl`** in the app's
**Application Support** directory (on-device, never leaves the phone). To get it onto your Mac:

1. Xcode → **Window → Devices and Simulators**.
2. Select your device → under **Installed Apps**, select **Snappet**.
3. Click the gear / "…" → **Download Container…** and save the `.xcappdata` bundle.
4. Right-click the `.xcappdata` → **Show Package Contents**, then open
   `AppData/Library/Application Support/` — `highlight-feedback.jsonl` is there.

Then feed it to the offline tuner:

```bash
cd experiments/feedback-replay
python3 run.py /path/to/highlight-feedback.jsonl
```

(Running `python3 run.py` with no path uses seeded synthetic data — handy to sanity-check the tool
before you have a real log. See [`experiments/feedback-replay/README.md`](../../experiments/feedback-replay/README.md).)

## 5. Troubleshooting

- **"No workouts" / empty list** — Record a workout on the Apple Watch and let it sync to the iPhone's
  Health app, then **pull to refresh**. Confirm Snappet has Health access under **Settings → Health →
  Data Access & Devices → Snappet** (workouts + heart rate).
- **"No clips for this workout"** — Auto-discovery only matches media whose timestamp falls inside the
  workout's window (with a small padding). The photos/videos must have been **shot during that
  workout**. If you granted **Limited** Photos access, auto-discovery can't scan — use **Select clips**
  to pick them manually.
- **Signing / "Failed to register bundle identifier"** — Set your Team under Signing & Capabilities;
  if `com.snappet.app` is taken, use a unique bundle id (step 2.3). On a free account, trust the
  developer profile on the phone (Settings → General → VPN & Device Management).
- **"iOS … is not installed" / no destination** — That's a *simulator* runtime error. This app must
  run on a **real device** — select your physical iPhone as the destination, not a simulator.
- **Export fails / black or empty reel** — The current exporter stitches **video segments only**
  (still photos are dropped; Ken-Burns is a known gap). Try a workout that has video clips, and check
  the on-screen error.

## 6. What's verified vs not

- ✅ **Engine**: `HighlightEngine` builds and **18 XCTest cases pass** (`cd ios/HighlightEngine &&
  swift test`) — selection pipeline, reel planning, pin/order, and feedback capture are proven.
- ✅ **App**: the whole app **type-checks against the iOS 18 SDK** (Swift 6, 0 errors / 0 warnings) —
  API usage and concurrency are correct.
- ⚠️ **On-device runtime is unproven** — permission flows, real HealthKit reads, Photos
  time-window discovery, and AVFoundation export have **never run on a device**. That's exactly what
  this runbook validates for the first time. Note anything surprising (do the HR picks look right? does
  media discovery work? is the `.mp4` shareable?) — it feeds the after-P1 decision gate in
  [`PLAN-ios-to-shippable.md`](../../pdd/prompts/features/PLAN-ios-to-shippable.md).
