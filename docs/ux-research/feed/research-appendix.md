# Research Appendix — Best-in-Class Backing for the "Recap" Feed

This appendix collects the cited, best-in-class research behind the Snappet **"Recap"** feed: an
Instagram-style **personal** feed of the user's own climbing + gym + HR sessions (infinite scroll),
with cards exportable as artifacts to real social apps — built **personal-now, social-ready**, fully
on-device. It is synthesized from three research passes (feed UX, insight/recap formats, media +
architecture) and organized into five sections:

1. Personal-feed & shareable-card patterns (Instagram / Strava / BeReal / Pinterest / Apple Fitness)
2. Insight & recap/story formats (Spotify Wrapped, Strava Year-in-Sport, Whoop, Gentler Streak, Apple Fitness, 8a/KAYA, Hevy/Fitbod)
3. Auto-clip + on-device video/overlay best practices
4. Personal-now / social-ready architecture (AS2 / event-sourced / stable content IDs)
5. The condensed insight-card MENU table (with ✅/🟡/🔶 availability tags)

Each section ends with a **STEAL / AVOID** distillation. All source URLs from the underlying research
are preserved in the per-section citations and in the consolidated **Sources** list at the end.

---

## 1. Personal-feed & shareable-card patterns

The Recap feed is the user's *own* sessions, not a social network. The following apps supply concrete
patterns for the feed surface and for cards that travel to other apps.

### Strava — the gold standard for activity-feed cards + share images

- **Card anatomy.** Each activity is a self-contained card: a hero (route map or photo), a title, and
  a compact stat row (distance / pace / time + elevation + contextual badges like segment
  achievements, PRs, the *Local Legend* laurel). Social affordances sit at the bottom.
  ([Activity Stats in the Feed](https://support.strava.com/hc/en-us/articles/15422373796493-Activity-Stats-in-the-Feed))
- **IA.** Feed → tap activity → detail (map, splits, segments, photos, social). Strava redesigned both
  the Record experience and the activity-viewing UI in 2025.
  ([Redesigned Record](https://press.strava.com/articles/strava-launches-redesigned-record-experience),
  [Accelerated Product Development](https://press.strava.com/articles/strava-unveils-new-chapter-of-accelerated-product-development-at-brands))
- **Feed engine is temporal, not ranked.** Strava's "Minifeed" runs on Kafka → Storm → Redis →
  WebSocket; Redis keeps the 25 most-recent events per athlete. The engineering write-up contains
  **no ranking logic** — a personal feed needs none.
  ([Minifeed Engineering](https://medium.com/strava-engineering/minifeed-engineering-5c2d122dbeed))
  The home feed soft-caps around 150–180 activities rather than true infinite scroll — use real
  pagination instead.
  ([Community: limited activities](https://communityhub.strava.com/archived-strava-features-chat-5/limited-number-of-activities-in-home-feed-10622))
- **Share images.** Share → "Share to Instagram Stories" generates a pre-styled card (distance/pace/
  time + mini route map) handed to Instagram as a positioned sticker; the user adds a photo behind it,
  and a story link deep-links back. **Hard limit: only GPS activities can be shared with map/stats —
  indoor, stationary, and manual activities cannot.**
  ([How to share to IG Stories](https://communityhub.strava.com/what-s-new-10/how-to-share-your-strava-activity-to-instagram-stories-9426),
  [5 Ways to Share](https://runflick.com/blog/share-strava-on-instagram))
- **Consistency over peak.** *Local Legends* rewards the most efforts on a segment over a rolling
  90 days, not the fastest time — a strong template for a personal app (reward showing up).
  ([Local Legends](https://support.strava.com/hc/en-us/articles/360043099552-Local-Legends),
  [Cycling Weekly](https://www.cyclingweekly.com/news/latest-news/strava-unveil-new-segment-feature-that-lets-you-a-top-leaderboards-without-being-fastest-457564))
- **Plain-language insights.** *Athlete Intelligence* turns raw data into personalized natural-language
  reads — a natural fit for an interleaved insight card.
  ([Athlete Intelligence](https://press.strava.com/articles/stravas-athlete-intelligence-translates-workout-data-into-simple-and),
  [Wareable](https://www.wareable.com/news/strava-athlete-intelligence-full-launch-flyover-sharing-progress-comparison))

### Instagram — card / grid / stories / reels structure

- **Surfaces & sizes (2025/26).** Profile grid moved to a taller **3:4 preview (1015×1350)**; Reels
  render **4:5** in-grid; feed posts default **1080×1350 (4:5)**; Stories/Reels are **1080×1920 (9:16)**.
  ([SocialBu grid update](https://socialbu.com/blog/instagram-new-grid-update),
  [trustypost sizes](https://trustypost.ai/blog/instagram-post-sizes-2026-the-exact-dimensions-i-use-feed-reels-stories/))
- **Three jobs, three surfaces.** Scrollable feed (immersive, one item at a time), grid (at-a-glance
  identity/portfolio), Stories/Reels (ephemeral + vertical motion). **Carousels and Reels generate
  ~44% more engagement than single images.**
  ([digitalstack](https://www.digitalstack.io/blog/instagrams-new-dimensions-in-2025-a-visual-guide))

### BeReal — authenticity mechanics (cautionary)

- **Design.** Random daily prompt + 2-minute window; dual front/back camera; no filters/editing;
  RealMojis (reactions are your own face-photo, not a like); friend counts hidden above 50; strictly
  chronological feed; "late" labels + retake counters.
  ([BeReal authenticity paper, arXiv](https://arxiv.org/html/2408.02883v1),
  [Contrary Research](https://research.contrary.com/company/bereal))
- **Documented harms.** The same paper reports coerced vulnerability, new toxicity vectors (judging
  "boring" posts / retake counts), limited self-expression, and a monotonous experience — i.e. the
  coercion mechanics backfire. A personal log should never punish editing or slowness.
  ([arXiv](https://arxiv.org/html/2408.02883v1))

### Pinterest — masonry & discovery

- **Layout & perf.** Masonry stacks items into columns by height for the "waterfall" effect; **images
  must load before position is computed** (else layout shift); relies on virtualization + lazy loading
  (`loading="lazy"`) + on-demand infinite scroll. Maps to `LazyVerticalStaggeredGrid` (Android Compose)
  and a custom waterfall `LazyVStack` (iOS).
  ([eBay Playbook: masonry](https://playbook.ebay.com/foundations/layout-in-product/masonry),
  [FrontendLead: design Pinterest](https://frontendlead.com/system-design/design-pintrest),
  [masonry + infinite scroll](https://javascript.plainenglish.io/masonry-layout-with-infinite-scroll-no-libraries-please-efbcb013bd37))

### Apple Fitness — activity sharing & awards (system-level model)

- **Sharing & awards.** Dedicated Sharing tab; awards/milestones fill a digital **trophy case**
  (streak awards, monthly goals, limited-edition seasonal badges). Workout Details → **Share →
  Post / Story / Message**. Known issue: shares can render cropped, so export at exact target sizes.
  ([Close Your Rings](https://www.apple.com/watch/close-your-rings/),
  [Share your activity](https://support.apple.com/guide/iphone/share-your-activity-iph0b826155d/ios),
  [iDropNews awards](https://www.idropnews.com/news/ios-16-introduces-activity-awards-for-fitness-workouts/191297/),
  [MacRumors: All Rings Closed](https://www.macrumors.com/2024/11/20/apple-watch-all-rings-closed-awards/),
  [Apple Community: cropped share](https://discussions.apple.com/thread/254759034))

### Nike Run Club — share card as a designed product

- A colorful run-map card is the explicit retention hook; **shareable achievements** are a cornerstone
  of the "running journey," with explicit user control over **what to share and with whom**. Design
  language: clean canvas, bold type, single neon accent, color-coded paces/levels.
  ([DesignRush: NRC](https://www.designrush.com/best-designs/apps/nike-run-club),
  [StriveCloud gamification](https://www.strivecloud.io/blog/gamification-examples-nike-run-club),
  [NRC achievements on Mobbin](https://mobbin.com/explore/screens/3caf6021-54b4-43d8-97ab-9214446be9e2),
  [AppSamurai](https://appsamurai.com/blog/mobile-app-success-story-nike-run-club/))

### Share-image template taxonomy (the most actionable card pattern)

Third-party fitness-card apps reveal the strongest pattern for *exportable* personal cards: **render
data as a familiar real-world object.** Forta ships named templates — **ID Badge, Boarding Pass,
Receipt, Ticket, Polaroid** — each showing sport metrics, with 50+ sport animations, multiple aspect
ratios, and direct Instagram sharing. Fitness Story and IronShare do the same for trophy cases and gym
metrics. These read as *artifacts*, not screenshots, and therefore travel further.
([Forta](https://apps.apple.com/us/app/-/id6748439776),
[Fitness Story](https://apps.apple.com/us/app/fitness-story/id6748090363),
[IronShare](https://apps.apple.com/app/id6751296554))

### Feed mechanics — freshness, pagination, perf (cross-cutting)

- Skeleton screens for perceived speed; optimistic insert of a just-logged session with visible
  rollback on write failure.
  ([UX Patterns: activity feed](https://uxpatterns.dev/patterns/social/activity-feed),
  [GetStream: feed ideas](https://getstream.io/blog/activity-feed-ideas/))
- "New sessions available" pill (don't yank scroll) + pull-to-refresh with clear feedback.
  ([Pull-to-Refresh pattern](https://uxplanet.org/pull-to-refresh-ui-pattern-42a85f671cdf),
  [Pull-to-refresh](https://en.wikipedia.org/wiki/Pull-to-refresh))
- Cursor-based pagination + infinite scroll (not page numbers); virtualized lists + lazy media decode.
  ([eBay masonry](https://playbook.ebay.com/foundations/layout-in-product/masonry),
  [News Feed system design](https://www.greatfrontend.com/questions/system-design/news-feed-facebook),
  [FrontendLead](https://frontendlead.com/system-design/design-pintrest))
- For a personal feed, reverse-chronological is sufficient and correct — Strava's own engine and
  BeReal both run on time order.
  ([Minifeed](https://medium.com/strava-engineering/minifeed-engineering-5c2d122dbeed),
  [arXiv: BeReal](https://arxiv.org/html/2408.02883v1))
  Because this is the user's own data, no Kafka/Storm/Redis fan-out is needed: page from the local
  store (SwiftData / Room) by a `startedAt` cursor; insert optimistically on save; interleave award /
  period-summary cards as locally-computed synthetic feed items.

> **STEAL:** one session = one rich card (hero + stat triad + contextual badges); a named "object"
> template library (Boarding Pass / Receipt / Ticket / Polaroid) rendered natively, full-bleed 9:16
> (Stories) and 4:5 (feed) with safe margins, handed to the OS share sheet / IG-Stories sticker with a
> deep link; both a scroll feed and a grid/masonry "send wall"; chronological feed (no ranking);
> milestone/award + period-summary cards interleaved; reactions-as-content + "on this day" memories;
> consistency-over-peak awards (Local Legend ethos); skeleton + optimistic insert + "new" pill +
> pull-to-refresh.
> **AVOID:** route-map-as-mandatory-hero (Strava itself can't share indoor/gym/climbing); social
> machinery you don't have (kudos, followers, comments, ranking); BeReal coercion (2-min timer, "late"
> labels, retake counters); heavy capture-time filters if authenticity is the pitch; export cropping
> (export at exact dimensions); cloud rendering.

---

## 2. Insight & recap/story formats

### Spotify Wrapped — the gold standard for the *story* format

A swipeable, full-screen, high-contrast, animated sequence of cards, each surfacing **one stat**, with
a per-user color palette that frames it as a "cultural report card" / identity artifact, and derivative
layouts generated specifically for sharing. Design grammar: one stat per card, bold type, motion, a
narrative arc that builds to a "top" reveal.
([Spotify Newsroom](https://newsroom.spotify.com/2024-12-04/10-years-spotify-wrapped/),
[DesignRight/Medium](https://medium.com/designright/three-design-elements-that-made-spotify-wrapped-2024-great-0a8e2b133b72))

### Strava "Year in Sport" — recap driven by *what data you actually have*

A highly personalized recap with shareable images per scene, where **"your scenes and stats are shown
based on the activities you upload, the amount of data on your profile, and what features and insights
best reflect your activities."** Scenes are **conditionally rendered** — streaks, top kudos, training
partner, etc. only appear if the data supports them. This *conditional-eligibility* model is the single
most reusable architectural pattern for the Recap: define each card with an eligibility predicate and
let the recap compose itself.
([Strava Support](https://support.strava.com/hc/en-us/articles/22067973274509-Your-Year-in-Sport),
[Strava Press](https://press.strava.com/articles/strava-releases-annual-year-in-sport-trend),
[Athletech](https://athletechnews.com/strava-2024-fitness-report-highlights-trends/))

### Whoop — trend views as the model for HR / effort / recovery

Weekly / monthly / 6-month trend views across three pillars: **Strain** (day strain, average HR,
calories, steps, **time in HR Zones 1–3 vs 4–5**, VO₂max), **Recovery** (recovery score, **resting
HR**, **HRV**, respiratory rate, color-banded green/yellow/red), and **Sleep**. Strain is HR-derived
and **individualized to fitness level**. The core narrative: see metrics together over months
(falling RHR / rising HRV = fitter; "as fitness improves, strain likely decreases"), and surface
weekly cyclical patterns. A **Monthly Performance Assessment** packages it. Caveat from the community:
don't dumb the summary down to vibes — keep real numbers.
([Trend Views](https://www.whoop.com/us/en/thelocker/track-progress-with-new-trend-views/),
[Strain 101](https://www.whoop.com/us/en/thelocker/how-does-whoop-strain-work-101/),
[Recovery Club](https://recoveryclub.fit/en/blog/what-whoop-actually-shows-who-it-fits/),
[Year on data](https://www.whoop.com/us/en/thelocker/podcast-54-year-on-whoop-data/),
[Monthly Performance Assessment](https://www.whoop.com/eu/en/thelocker/monthly-performance-assessment/),
[Community: MIR disappointment](https://www.community.whoop.com/t/new-month-in-review-is-a-huge-disappointment/9035))

### Gentler Streak — streaks reframed as *balance*, not grind

The **Activity Path** (a "green band" healthy zone with your load tracked as a dotted line) reframes
consistency as staying in-band; **"Go Gentler"** generates a personalized daily suggestion that
*includes rest* (rest / active recovery / strength / cooldown), and HR zones are monitored to warn
against overtraining. Lesson: reward consistency without punishing rest, using HR/load to nudge "go
gentler."
([Activity Path docs](https://docs.gentler.app/understanding-your-activity-path/interpret-the-activity-path),
[App Store](https://apps.apple.com/us/app/gentler-streak-workout-tracker/id1576857102),
[Neura Health review](https://neura.health/insight/gentler-streak-app-hands-on-review),
[MakeUseOf](https://www.makeuseof.com/gentler-streak-ios-app-help-improve-fitness/))

### Apple Fitness — awards, streaks, personalized challenges, trend arrows

The evergreen insight primitives: awards/badges (Perfect Month, Move-streak awards), personal records
(longest streak, most steps, longest distance/workout), personalized monthly challenges scaled to the
user's own recent activity, and **Fitness Trends** shown as up/down arrows comparing a **90-day rolling
average to the long-term baseline**.
([iPhoneLife trends/challenges](https://www.iphonelife.com/content/understanding-fitness-trends-apple-fitness-challenges),
[Macworld badges](https://www.macworld.com/article/231140/how-to-get-all-of-the-apple-watch-activity-challenge-badges.html),
[Apple Support](https://support.apple.com/guide/watch/track-daily-activity-apd3bf6d85a6/watchos))

### Climbing primitives — 8a.nu & KAYA

- **Grade pyramid** is *the* canonical climbing visualization: a histogram of sends per grade, widest
  at the base, narrowing toward your max.
  ([Power Company pyramids](https://www.powercompanyclimbing.com/blog/2010/08/great-pyramids.html),
  [Shashi Shanbhag](https://shashishanbhag.com/climb/trad-climbing-progression-using-grade-pyramid/))
- **Ascent-style taxonomy** (onsight / flash / redpoint / second-go) is first-class and color-coded
  (8a.nu: black=onsight, orange=flash, red=redpoint); style materially changes the achievement.
  Onsight/flash typically sit ~2–3 letter grades below max redpoint (widening to ~4 at elite level) —
  a quantifiable, narratable progression gap.
  ([8a.nu ranking](https://www.8a.nu/ranking/sportclimbing),
  [8a.nu onsight](https://www.8a.nu/news/onsight-49849),
  [Climbstat](http://climbstat.blogspot.com/2020/02/how-much-harder-is-onsighting-vs.html),
  [The Wandering Climber](https://www.thewanderingclimber.com/redpoint-climbing/))
- **KAYA**: tick-list + project tracking, ascent pyramid, session review, and HR-free "intensity zones"
  translating attempts/sends into 3 zones based on max grade. Redpoint literature treats
  attempts-per-send and flash-rate as core progress signals (balanced split ≈ 1/3 limit projecting,
  1/3 second-go, 1/3 onsightable).
  ([KAYA site](https://kayaclimb.com/),
  [GearJunkie KAYA](https://gearjunkie.com/climbing/kaya-climb-climbing-app),
  [Google Play](https://play.google.com/store/apps/details?id=com.project9a.redpoint),
  [Power Company redpoint](https://www.powercompanyclimbing.com/blog/2019/7/21/redpoint-tactics-applying-the-art-of-the-second-try-send))

### Gym primitives — Hevy & Fitbod

- **Hevy PR types** (each a distinct card): heaviest weight, best/estimated 1RM (with trend line),
  best set volume, best session volume; rep PRs for bodyweight; best time for duration; distance for
  cardio — fired as real-time in-workout notifications. The **Monthly Report** scenes: # workouts, time
  training, **volume load**, # sets, graphs vs prior months, PR overview, an **activity calendar**,
  **muscle-distribution vs last month**, and **top exercises**. A Strength Level benchmark places lifts
  Beginner→Elite vs peers.
  ([Hevy exercise perf](https://www.hevyapp.com/features/exercise-performance/),
  [Hevy monthly report](https://www.hevyapp.com/features/monthly-report/),
  [Hevy 2025 features](https://help.hevyapp.com/hc/en-us/articles/33106320824727-Everything-You-Need-to-Know-About-the-Hevy-App-2025-Features-Guide),
  [Hevy sets per muscle](https://www.hevyapp.com/features/sets-per-muscle-group-per-week/))
- **Fitbod**: per-muscle-group recovery % (0–100), fatigue indexing (performance drops across sets),
  and muscle-balance correction (shift volume off overworked groups, flag a lagging chain). Volume =
  sets × reps × weight.
  ([Fitbod recovery](https://fitbod.zendesk.com/hc/en-us/articles/360006269014-Muscle-Recovery),
  [Fitbod tracking](https://fitbod.me/blog/tracking-volume-intensity-and-recovery-with-fitbod/),
  [Fitbod AI](https://fitbod.me/blog/how-fitbods-ai-knows-exactly-when-you-should-lift-heavier-and-when-to-recover/))

### "On this day" / memory retrospectives

The Timehop / Day One / Facebook **"On This Day"** pattern resurfaces a past entry from the same
calendar date in prior years, often with a Then-&-Now comparison — directly applicable to "you sent
this climb 1 year ago today."
([Day One](https://dayoneapp.com/features/on-this-day/),
[Timehop](https://play.google.com/store/apps/details?id=com.timehop))

> **STEAL:** conditional-eligibility scene engine (only render a card when the data makes it true —
> Strava); one-stat-per-card story grammar building to a "top" reveal, with a shareable image per scene
> (Spotify); trends over single days + 90-day-vs-baseline arrows + weekly cyclical patterns
> (Whoop/Apple); reward consistency protectively, nudge rest via HR load (Gentler); evergreen
> primitives — PRs, streaks, personalized goals, trend arrows (Apple); climbing-native primitives —
> grade pyramid, ascent style, flash rate, onsight-vs-redpoint gap, projects/attempts-to-send (8a/KAYA);
> gym primitives — PR types, monthly report, volume load, muscle balance/recovery (Hevy/Fitbod);
> "on this day" / then-&-now memories. **HR effort-vs-grade efficiency** ("sending the same grade at a
> lower HR than 3 months ago") is the differentiator few climbing apps have.
> **AVOID:** a fixed dashboard instead of conditional scenes; vibes-only summaries that drop real
> numbers; a paywall feel on the personal review.

---

## 3. Auto-clip + on-device video / overlay best practices

### How the incumbents assemble clips

| App | Produces | Assembly | Overlay | Music | Export |
|---|---|---|---|---|---|
| **Strava** | A transparent **Stats Sticker** auto-built from an activity | Share → swipe sticker styles | Burns distance/pace/time into a sticker; user adds their own photo behind it | None (handoff) | IG Stories with sticker **pre-placed**, or save to camera roll; needs visibility = Everyone/Followers ([community](https://communityhub.strava.com/what-s-new-10/use-strava-stats-stickers-on-ig-stories-ios-android-9344), [runflick](https://runflick.com/blog/share-strava-on-instagram)) |
| **Whoop (Live / Snap+)** | Photo **or** video with live data overlay | Record live (data evolves) or overlay onto existing media | HR, Day Strain, Recovery, Sleep, calories; user picks a mode + metrics | None | Save → analyze → share ([support](https://support.whoop.com/hc/en-us/articles/360023429833-WHOOP-Live), [PRNewswire](https://www.prnewswire.com/news-releases/introducing-whoop-strap-3-0-featuring-whoop-live-300855111.html)) |
| **Apple Fitness** | Workout-summary card | Built-in, minimal | Stats only; known cropping limits | None | Native share sheet → Story/Post/Message ([support](https://support.apple.com/guide/iphone/share-your-activity-iph0b826155d/ios), [community](https://discussions.apple.com/thread/254759034)) |
| **Third-party** (Forta, STREIV, Insta360, GpxOverlay) | Animated cards / data-on-video | Named templates; animated route maps; PR-medal animations | Speed/HR/distance/altitude/cadence/slope, scalable + positionable; animated route reveal | Some libraries | Render to image/video → camera roll / socials ([Forta](https://apps.apple.com/us/app/-/id6748439776), [STREIV](https://www.streiv.app/), [Insta360](https://www.insta360.com/blog/news/insta360-supports-strava-data-in-videos.html), [GpxOverlay](https://gpxoverlay.com/)) |

**Patterns to steal:** (1) the **overlay sticker is a separate transparent layer** the user drops on
their own media — far simpler than full compositing and leans on Instagram's editor for free (ship
first); (2) a **mode + metric picker before render** (Whoop) — climbing modes: Send, Session, Grade PR;
(3) **animated data-on-video** where values evolve across the timeline (HR rising on the crux, "SENT"
badge on the topout frame) is the premium tier; (4) **templates as first-class named objects** beat
infinite customization.

### iOS — on-device composition (AVFoundation)

Canonical "burn animated stat overlays into a video and export" pipeline: `AVMutableComposition`
container → `AVMutableCompositionTrack` (insert source via `insertTimeRange(_:of:at:)`, copy
`preferredTransform` for orientation) → a `CALayer`/`CATextLayer` overlay hierarchy →
`AVVideoCompositionCoreAnimationTool` (wired via `postProcessingAsVideoLayer:inLayer:` into an
`AVMutableVideoComposition`) → `AVAssetExportSession.exportAsynchronously()` with progress polling.
([Kodeco](https://www.kodeco.com/6236502-avfoundation-tutorial-adding-overlays-and-animations-to-videos),
[Apple forum 107584](https://developer.apple.com/forums/thread/107584))

**Hard-won gotchas (cite to save the team time):**
- **Custom CALayer properties are ignored during export** — only standard animatable properties
  (`opacity`, `position`, `borderWidth`, …) render via `AVAssetExportSession`; drive animations off
  built-ins only. ([Apple forum 692858](https://developer.apple.com/forums/thread/692858))
- **Set the layer-instruction background to clear**, else it defaults to opaque black.
  ([creativeiphonecoding](http://creativeiphonecoding.blogspot.com/2014/10/how-to-add-overlay-to-video.html))
- `AVVideoCompositionCoreAnimationTool` + `AVAssetExportSession` can **intermittently freeze** — a
  known instability; fall back to `AVAssetReader`/`AVAssetWriter` + per-frame `CIImage`/Metal if hit,
  and always export off the main thread. ([Apple forum 726146](https://developer.apple.com/forums/thread/726146))
- For pure card → video (no background clip), still supply a synthesized solid/photo base layer.
  ([Apple forum 107584](https://developer.apple.com/forums/thread/107584))

### Android — on-device composition (Jetpack Media3 Transformer)

Transformer is the modern supported path, **built on `MediaCodec` (hardware decode/encode) + OpenGL**.
([Transformer overview](https://developer.android.com/media/media3/transformer),
[Android blog 2023](https://android-developers.googleblog.com/2023/05/media-transcoding-and-editing-transform-and-roll-out.html))

Overlay pipeline (verified class names): `MediaItem` → `EditedMediaItem.Builder` → `Effects(audioProcessors, videoEffects)`
with overlays in `videoEffects` as `OverlayEffect(overlays)`; overlay types `TextOverlay`, `BitmapOverlay`,
`TextureOverlay` (and `DrawableOverlay`). For **animated** data, subclass `BitmapOverlay` and override
`getBitmap(presentationTimeUs: Long)` to redraw the stat readout per timestamp. Sequence/trim/crop/scale
via `EditedMediaItemSequence`/`Composition`, `Presentation.createForHeight(...)`,
`ScaleAndRotateTransformation`. Export with `transformer.start(...)` and observe
`Transformer.Listener.onCompleted/onError`. **In-app preview uses the same effects through ExoPlayer**,
so preview matches export.
([AIBY/Medium](https://medium.com/aibygroup/create-an-animation-video-with-android-media-3-effects-adf4ef1e0c20),
[Transformations](https://developer.android.com/media/media3/transformer/transformations),
[Simakova/Medium](https://medium.com/google-exoplayer/trim-transcode-concatenate-your-guide-to-media3-editing-libraries-668b4e4c2f97))

**Performance (Pixel 9 Pro XL, official benchmarks)** — for progress UX:
10s 720p H264 → transcode ≈ **1.3s**; trim ≈ 2.3s; resize ≈ 1.2s; mute ≈ 0.2s.
`experimentalSetTrimOptimizationEnabled` makes trim latency near-constant regardless of source length;
Transformer prefers transmuxing (no re-encode) when possible. Caveat: stacking overlay/decoder effects
has known edge-case bugs on some devices — test on a device matrix.
([Android blog 2025](https://android-developers.googleblog.com/2025/03/media-processing-performance-jetpack-media3-transformer.html),
[androidx/media #810](https://github.com/androidx/media/issues/810))

### Music, tagging, and export

- **Music / licensing:** do **not** bundle commercial tracks into the export — the legally clean
  pattern is the Strava/Apple **handoff model**: export the muxed clip *without* music and let
  Instagram/TikTok/CapCut add pre-cleared music in their editor. For in-app music, use a sync-licensed
  royalty-free library (Epidemic Sound, Artlist, Soundstripe) and verify commercial-use terms.
  ([Splice](https://spliceapp.com/blog/best-apps-for-beat-driven-edits/),
  [Filmora](https://filmora.wondershare.com/video-editor/best-beat-sync-video-editing-apps.html))
- **Beat-sync** (align cuts and stat "pop-in" to detected beats) is a recognized premium feature —
  defer it; ship template-timed animations first.
  ([OpusClip](https://www.opus.pro/blog/best-ai-beat-sync),
  [Filmora](https://filmora.wondershare.com/video-editor/best-beat-sync-video-editing-apps.html))
- **People/name tagging** is modeled as **structured references**, not burned-in text, so they resolve
  to real accounts later (AS2 models this as an audience array + `@mention` objects). For now a tag =
  `{ displayName, localContactId?, futureUserId? }`; only the display name is burned into the visual.
  ([getstream W3C](https://getstream.io/blog/designing-activity-stream-newsfeed-w3c-spec/))
- **Export targets:** generate both a portrait/square **image card** (cheap sticker — ship first) and
  an optional **video render** (premium); always export off the main thread with a cancellable progress
  UI given multi-second render times.

**Recommended build order:** (1) transparent stat sticker (image) + share-sheet/IG handoff →
(2) template engine (3–5 named templates) → (3) data-on-video with static overlay → (4) animated
data-on-video → (5) beat-sync + music.

> **STEAL:** overlay-as-separate-transparent-layer first; mode+metric picker; named template objects;
> animated data-on-video as the premium tier; cite the iOS export gotchas and the Media3 perf numbers
> up front; structured (resolvable) people-tags with only display name burned in; export image first,
> video later, always off-main-thread with progress.
> **AVOID:** single generic stat overlay; bundling commercial music into exports; GPS/map dependence;
> cloud rendering; custom CALayer props on iOS export; un-cleared layer-instruction background;
> shipping beat-sync before the basics.

---

## 4. Personal-now / social-ready architecture

Goal: a **local FeedItem/activity model** that works fully offline today and can grow a follow/share/
backend layer later **without a redesign**. Four pillars:

### Adopt the Activity Streams shape now (actor / verb / object / target)

Model every feed-worthy event as a W3C **Activity Streams 2.0** quadruple — even with one actor (the
device owner). This is the exact vocabulary ActivityPub/social systems use, so the local model *is* the
future wire model.
([W3C AS2](https://www.w3.org/TR/activitystreams-core/),
[getstream W3C](https://getstream.io/blog/designing-activity-stream-newsfeed-w3c-spec/))

```
FeedItem (≈ AS2 Activity)
  id            : UUIDv5     // stable content identity (see below)
  actor         : ActorRef   // today = local "self"; later = a real user id
  verb          : enum       // sent | flashed | logged_session | created_climb | shared_clip ...
  object        : ObjectRef  // the climb / session / clip (its own UUIDv5)
  target        : ObjectRef? // board / gym / collection
  published     : ISO-8601   // ordering + dedup
  visibility    : enum       // private | followers | public  (defaults to private today)
  audience.to   : [TagRef]   // @mentions / people tagged (structured, not burned-in)
  attachments   : [MediaRef] // photos / clips / overlays
  schemaVersion : int
```

Going social later is *adding actors and an audience filter*, not reshaping records. Ship `visibility`
and `audience.to` **now** (defaulted to private) so the columns exist before the backend arrives —
adding columns to a populated table is the migration to avoid.

### Keep UUIDv5 content identity — it's already the right call

Deterministic and coordination-free: two devices (or device + future server) compute the **same** UUID
for the same climb/session/clip, enabling dedup with no central authority; deterministic ids also make
sync **idempotent** (re-import eliminates duplicates with no extra logic — the `foreign_id` + `time`
pattern feeds rely on).
([inventivehq](https://inventivehq.com/blog/when-to-use-uuid-v5-deterministic-id-generation),
[Salesforce IdeaExchange](https://ideas.salesforce.com/s/idea/a0B8W00000QcNkiUAF/deterministic-universal-identity-uuid-v5),
[getstream W3C](https://getstream.io/blog/designing-activity-stream-newsfeed-w3c-spec/))

Rules to lock in: (1) **pin namespaces forever** (`NS_CLIMB`, `NS_SESSION`, `NS_CLIP`, `NS_FEEDITEM`);
(2) **canonicalize inputs** before hashing (normalize unicode, trim, fixed field order/units) so iOS
and Android agree — keep the existing cross-platform golden-vector test; (3) **content id ≠ activity
id** — use UUIDv5 for content, but a non-deterministic v4/v7 for the *activity* row when the same
content can be acted on twice (two "share" events of one clip), and never use v5 for secrets.

### Local store = source of truth; build the sync seam now, fill it later

Follow the official offline-first architecture so the only thing a future backend changes is the
network data source:
- **Local DB is the canonical source of truth** the UI reads from; the repository interface already
  assumes a network source could exist (there is none today).
- **Three model layers** (local entity / network DTO / UI model) with mapping functions; on iOS:
  SwiftData/Core Data entity ↔ Codable DTO ↔ value type.
- **Observable reads** (Flow/StateFlow; `@Query`/Combine/observation) so synced rows appear reactively.
- **Lazy writes + an outbound queue**: write locally first, enqueue a sync intent, drain with
  WorkManager (`NetworkType.CONNECTED`, expedited, backoff) / `BGTaskScheduler`. **Add the outbox table
  now** even if nothing drains it.
- **Conflict policy = Last-Write-Wins** with `updatedAt` + `version` on every record; CRDTs are the
  later option for mergeable fields and pair naturally with deterministic ids + SQLite.

([Android offline-first](https://developer.android.com/topic/architecture/data-layer/offline-first),
[dev.to offline-first](https://dev.to/odunayo_dada/offline-first-mobile-app-architecture-syncing-caching-and-conflict-resolution-1j58),
[crdt-kit](https://github.com/crdt-kit/crdt-kit),
[sqlite-sync](https://github.com/sqliteai/sqlite-sync),
[jackson.dev](https://jackson.dev/post/crdts_as_database/))

### Make the feed append-only / event-sourced — so social fan-out is additive

Treat FeedItems as an **immutable, append-only log of events**; current state is derived, and
corrections are *new* events (`correctedSend`), never destructive edits. This lets a personal timeline
become a social one with zero remodeling — the same event stream is later fanned out to followers.
Design the seams now (don't build fan-out yet): today is fan-out-on-read over one actor; later add a
backend doing **hybrid fan-out** (push under ~10K followers, store-once-pull-on-read for high-follower
accounts, skip-push for inactive followers). **Bake in the fields fan-out needs now:** `foreign_id` +
`time` (idempotency), an aggregation key `(target, verb, object, time_bucket)` for "X and 3 others sent
V4" grouping, and **cursor/keyset pagination** `(published, id)` (offset pagination scales poorly).
([Microsoft — Event Sourcing](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing),
[Akka](https://doc.akka.io/libraries/guide/concepts/event-sourcing.html),
[getstream scalable feed](https://getstream.io/blog/scalable-activity-feed-architecture/),
[getstream W3C](https://getstream.io/blog/designing-activity-stream-newsfeed-w3c-spec/))

> **STEAL:** AS2 actor/verb/object/target FeedItem with `visibility`/`audience` defaulted to private;
> UUIDv5 content identity with pinned namespaces + canonical inputs + the golden-vector test, separate
> v4/v7 for activity rows; append-only event-sourced feed; offline-first repository seam (local source
> of truth, 3-layer models, observable reads, lazy writes, outbox table, `updatedAt`+`version`, LWW);
> pre-provision fan-out fields (`foreign_id`, aggregation key, cursor pagination); structured people-tags.
> **AVOID:** mutable feed rows / destructive edits; offset pagination; deferring the social columns
> until the backend exists (retrofitting onto populated tables); UUIDv5 for anything secret.

---

## 5. The condensed insight-card MENU

Mapped to the known Snappet schema (`KilterLogEntry`, `KilterSessionStats`, `KilterAllTimeStats`,
HR/zone data, gym `RoutineExercise`/discipline axis, the new "On the Board" lit-history).

**Availability legend:** ✅ data exists today · 🟡 partial / needs aggregation or a small field ·
🔶 needs new capture (HR detail, muscle tagging, or location).

| # | Card | Data needed | Available? |
|---|---|---|---|
| **A. Streaks & consistency** | | | |
| A1 | Session streak ("12 days in a row / 6 weeks unbroken") | Session dates | ✅ `KilterLogEntry` timestamps |
| A2 | Consistency calendar / heatmap (GitHub-style) | Per-day session counts | ✅ aggregate over dates (cf. Hevy calendar) |
| A3 | "Perfect week/month" (hit weekly goal every week) | Dates + a goal | 🟡 dates ✅, goal field needed |
| A4 | "Go Gentler" rest nudge (trained N hard days — rest) | Session load/HR + rest gaps | 🔶 needs HR-load model (Gentler/Whoop) |
| A5 | Longest-streak PR (beat previous best) | Streak history | ✅ derivable (Apple) |
| **B. Personal records** | | | |
| B1 | Hardest grade sent (by style) | Grade + style per send | ✅ `KilterLogEntry` |
| B2 | First send at grade X ("your first V6!") | Grade history | ✅ log + `KilterAllTimeStats` |
| B3 | Most climbs in a session | Per-session send count | ✅ `KilterSessionStats` |
| B4 | Most volume in a session (climbs×grade-weight / sets×reps×wt) | Per-session totals | climbing 🟡 / gym ✅ if logged |
| B5 | Gym lift PRs: heaviest, est. 1RM, best set/session volume, rep PRs | Per-set weight×reps | 🟡 depends on gym set granularity |
| B6 | Longest session / most active day | Session duration | ✅ if duration captured |
| **C. Grade pyramid & climbing progression** | | | |
| C1 | Grade pyramid (sends-per-grade histogram) | All sends with grade | ✅ `KilterAllTimeStats` / log |
| C2 | Pyramid health ("top-heavy — consolidate V5") | Pyramid shape vs ideal | 🟡 needs a shape heuristic on C1 |
| C3 | Flash rate (% sent first try) | Attempts + style per climb | 🟡 needs attempt/style fields |
| C4 | Onsight/flash gap ("redpoint V7 but flash V4") | Max-by-style comparison | 🟡 needs style on sends |
| C5 | Style mix donut (onsight/flash/redpoint share) | Style per send | 🟡 same as C3/C4 |
| C6 | Grade milestone timeline (first touch of each grade) | Dated sends by grade | ✅ from log |
| **D. Volume & training-load trends** | | | |
| D1 | Climbing volume trend (per week/month vs prior) | Per-period send counts | ✅ aggregate |
| D2 | Gym volume-load trend (sets/reps/wt vs last month) | Logged sets | 🟡 if gym sets logged (Hevy) |
| D3 | Sets-per-muscle-group / muscle balance | Exercise → muscle map | 🔶 needs muscle tagging (Hevy/Fitbod) |
| D4 | Muscle recovery / "what to train next" | Recent muscle load + recovery model | 🔶 needs D3 + recovery model (Fitbod) |
| D5 | Discipline split (climbing/strength/cardio share) | Session discipline axis | 🟡 `RoutineExercise` axis exists; needs roll-up |
| D6 | Trend arrows (90-day rolling avg vs baseline) | Any metric time-series | ✅ wherever a series exists (Apple/Whoop) |
| **E. HR / effort / zone trends (the differentiator)** | | | |
| E1 | Time in HR zones per session/week (Z1–Z5 stacked) | Per-session HR samples + zones | 🟡 HR captured; zone bucketing needed (Whoop) |
| E2 | Effort/strain score per session (individualized) | HR series + max/resting HR | 🔶 needs strain model (Whoop) |
| E3 | Avg & peak HR trend | Per-session HR summary | 🟡 if HR summary stored |
| E4 | Resting HR / HRV trend ("RHR ↓ = fitter") | RHR/HRV over time | 🔶 needs RHR/HRV capture |
| E5 | "Hardest-effort send" (highest HR while sending) | HR aligned to send timestamp | 🟡 HR + send-time alignment |
| E6 | Recovery-band nudge (green/yellow/red → train vs rest) | RHR/HRV/sleep blend | 🔶 needs recovery inputs (Whoop/Gentler) |
| E7 | Effort-vs-grade scatter ("V6 at lower HR than 3 months ago") | HR + grade + date | 🟡 HR + grade exist; alignment + trend needed |
| **F. Recaps & stories** | | | |
| F1 | Weekly recap (sessions, sends, hardest grade, volume, HR zones) | Weekly aggregate | ✅ mostly; HR cards 🟡 |
| F2 | Monthly report (Hevy-style: #sessions, volume vs last, PR list, calendar, top climbs) | Monthly + prior month | ✅ counts/volume; muscle dist 🔶 |
| F3 | Seasonal / "Year in Climb" Wrapped-style swipeable story | All-time + year aggregates | ✅ stats exist; needs story UI + scene engine (Spotify/Strava) |
| F4 | Conditional scene engine (render a card only when data makes it true) | Eligibility rules per card | 🔶 architecture to build (Strava's core idea) |
| F5 | Shareable card export (image per scene) | Rendered card → image | 🔶 share-image renderer (Spotify/Strava) |
| **G. Projects & tick lists (climbing-native)** | | | |
| G1 | Project tracker ("V8 project — 14 attempts over 5 sessions") | Project flag + attempt log | 🟡 needs project flag + attempt counts (KAYA) |
| G2 | Attempts-to-send / efficiency ("avg 3 tries, down from 6") | Attempts per send | 🟡 needs attempt count per climb |
| G3 | Project-send celebration ("PROJECT SENT after 23 tries") | Project flag + send event | 🟡 G1 + send |
| G4 | "On the Board" lit-history surfaced as a card | Lit-history (P5) | ✅ new On-the-Board lit history exists |
| **H. Comparisons & "on this day"** | | | |
| H1 | This period vs last (week/month/year deltas) | Two-period aggregates | ✅ (Hevy/Apple) |
| H2 | "On this day" ("1 year ago you sent your first V5 here") | Dated history | ✅ from log (Timehop/Day One) |
| H3 | Then & Now (grade/volume/HR start vs now) | First vs latest snapshot | ✅ derivable |
| H4 | Strength-level / percentile benchmark (vs peers) | Anonymized cohort data | 🔶 needs community dataset (Hevy/8a) |
| H5 | Personalized next goal ("2 sends from a clean V6 pyramid row") | Current state + target heuristic | 🟡 derivable from pyramid (Apple challenges) |

**Lowest-effort, highest-impact first wave** (already-supported data): A1/A2 streaks+calendar,
B1/B2/B3 PRs, C1/C6 pyramid+milestones, D1/D5/D6 volume+discipline+trend arrows, F1/F2 weekly+monthly
recap, G4 On-the-Board, H1/H2/H3 comparisons + on-this-day. **HR cards (E*) and projects/flash-rate
(C3–C5, G1–G3) are the next wave**, once attempt/style fields and HR zone bucketing are added.

---

## Sources

**Personal feeds & shareable cards**
- Strava: [Minifeed Engineering](https://medium.com/strava-engineering/minifeed-engineering-5c2d122dbeed) ·
  [Activity Stats in the Feed](https://support.strava.com/hc/en-us/articles/15422373796493-Activity-Stats-in-the-Feed) ·
  [Redesigned Record](https://press.strava.com/articles/strava-launches-redesigned-record-experience) ·
  [Accelerated Product Development](https://press.strava.com/articles/strava-unveils-new-chapter-of-accelerated-product-development-at-brands) ·
  [Home-feed limit](https://communityhub.strava.com/archived-strava-features-chat-5/limited-number-of-activities-in-home-feed-10622) ·
  [→ IG Stories how-to](https://communityhub.strava.com/what-s-new-10/how-to-share-your-strava-activity-to-instagram-stories-9426) ·
  [5 Ways to Share](https://runflick.com/blog/share-strava-on-instagram) ·
  [Snapchat × Strava](https://www.aol.com/news/snapchat-now-lets-share-strava-130048870.html) ·
  [Local Legends (support)](https://support.strava.com/hc/en-us/articles/360043099552-Local-Legends) ·
  [Local Legends (Cycling Weekly)](https://www.cyclingweekly.com/news/latest-news/strava-unveil-new-segment-feature-that-lets-you-a-top-leaderboards-without-being-fastest-457564) ·
  [Athlete Intelligence](https://press.strava.com/articles/stravas-athlete-intelligence-translates-workout-data-into-simple-and) ·
  [Athlete Intelligence (Wareable)](https://www.wareable.com/news/strava-athlete-intelligence-full-launch-flyover-sharing-progress-comparison)
- Instagram: [grid update 2025](https://socialbu.com/blog/instagram-new-grid-update) ·
  [dimensions 2025](https://www.digitalstack.io/blog/instagrams-new-dimensions-in-2025-a-visual-guide) ·
  [post sizes 2026](https://trustypost.ai/blog/instagram-post-sizes-2026-the-exact-dimensions-i-use-feed-reels-stories/)
- BeReal: [authentic self-presentation (arXiv 2408.02883)](https://arxiv.org/html/2408.02883v1) ·
  [Contrary Research](https://research.contrary.com/company/bereal)
- Pinterest / masonry: [eBay Playbook](https://playbook.ebay.com/foundations/layout-in-product/masonry) ·
  [FrontendLead](https://frontendlead.com/system-design/design-pintrest) ·
  [Masonry + Infinite Scroll](https://javascript.plainenglish.io/masonry-layout-with-infinite-scroll-no-libraries-please-efbcb013bd37)
- Apple Fitness: [Close Your Rings](https://www.apple.com/watch/close-your-rings/) ·
  [Share your activity](https://support.apple.com/guide/iphone/share-your-activity-iph0b826155d/ios) ·
  [Activity Awards](https://www.idropnews.com/news/ios-16-introduces-activity-awards-for-fitness-workouts/191297/) ·
  [All Rings Closed](https://www.macrumors.com/2024/11/20/apple-watch-all-rings-closed-awards/) ·
  [cropped share](https://discussions.apple.com/thread/254759034)
- Nike Run Club: [DesignRush](https://www.designrush.com/best-designs/apps/nike-run-club) ·
  [StriveCloud](https://www.strivecloud.io/blog/gamification-examples-nike-run-club) ·
  [Mobbin achievements](https://mobbin.com/explore/screens/3caf6021-54b4-43d8-97ab-9214446be9e2) ·
  [AppSamurai](https://appsamurai.com/blog/mobile-app-success-story-nike-run-club/)
- Share tooling: [Forta](https://apps.apple.com/us/app/-/id6748439776) ·
  [Fitness Story](https://apps.apple.com/us/app/fitness-story/id6748090363) ·
  [IronShare](https://apps.apple.com/app/id6751296554)
- Feed mechanics: [UX Patterns: Activity Feed](https://uxpatterns.dev/patterns/social/activity-feed) ·
  [GetStream: feed ideas](https://getstream.io/blog/activity-feed-ideas/) ·
  [Pull-to-Refresh pattern](https://uxplanet.org/pull-to-refresh-ui-pattern-42a85f671cdf) ·
  [Pull-to-refresh](https://en.wikipedia.org/wiki/Pull-to-refresh) ·
  [News Feed system design](https://www.greatfrontend.com/questions/system-design/news-feed-facebook)

**Insight & recap formats**
- Spotify Wrapped: [Newsroom](https://newsroom.spotify.com/2024-12-04/10-years-spotify-wrapped/) ·
  [DesignRight](https://medium.com/designright/three-design-elements-that-made-spotify-wrapped-2024-great-0a8e2b133b72)
- Strava Year in Sport: [Support](https://support.strava.com/hc/en-us/articles/22067973274509-Your-Year-in-Sport) ·
  [Press](https://press.strava.com/articles/strava-releases-annual-year-in-sport-trend) ·
  [Year in Sport 2025](https://press.strava.com/articles/strava-releases-12th-annual-year-in-sport-trend-report-2025) ·
  [Athletech](https://athletechnews.com/strava-2024-fitness-report-highlights-trends/)
- Whoop: [Trend Views](https://www.whoop.com/us/en/thelocker/track-progress-with-new-trend-views/) ·
  [Strain 101](https://www.whoop.com/us/en/thelocker/how-does-whoop-strain-work-101/) ·
  [year-of-data podcast](https://www.whoop.com/us/en/thelocker/podcast-54-year-on-whoop-data/) ·
  [Monthly Performance Assessment](https://www.whoop.com/eu/en/thelocker/monthly-performance-assessment/) ·
  [Recovery Club](https://recoveryclub.fit/en/blog/what-whoop-actually-shows-who-it-fits/) ·
  [Month in Review feedback](https://www.community.whoop.com/t/new-month-in-review-is-a-huge-disappointment/9035)
- Gentler Streak: [Activity Path docs](https://docs.gentler.app/understanding-your-activity-path/interpret-the-activity-path) ·
  [App Store](https://apps.apple.com/us/app/gentler-streak-workout-tracker/id1576857102) ·
  [Neura Health](https://neura.health/insight/gentler-streak-app-hands-on-review) ·
  [MakeUseOf](https://www.makeuseof.com/gentler-streak-ios-app-help-improve-fitness/)
- Apple Fitness: [trends/challenges](https://www.iphonelife.com/content/understanding-fitness-trends-apple-fitness-challenges) ·
  [Macworld badges](https://www.macworld.com/article/231140/how-to-get-all-of-the-apple-watch-activity-challenge-badges.html) ·
  [Apple Support](https://support.apple.com/guide/watch/track-daily-activity-apd3bf6d85a6/watchos)
- 8a.nu / climbing: [Ranking system](https://www.8a.nu/ranking/sportclimbing) ·
  [Onsight vs redpoint](https://www.8a.nu/news/onsight-49849) ·
  [Climbstat](http://climbstat.blogspot.com/2020/02/how-much-harder-is-onsighting-vs.html) ·
  [Power Company pyramids](https://www.powercompanyclimbing.com/blog/2010/08/great-pyramids.html) ·
  [Redpoint tactics](https://www.powercompanyclimbing.com/blog/2019/7/21/redpoint-tactics-applying-the-art-of-the-second-try-send) ·
  [The Wandering Climber](https://www.thewanderingclimber.com/redpoint-climbing/) ·
  [Shashi Shanbhag](https://shashishanbhag.com/climb/trad-climbing-progression-using-grade-pyramid/)
- KAYA: [Site](https://kayaclimb.com/) · [GearJunkie](https://gearjunkie.com/climbing/kaya-climb-climbing-app) ·
  [Google Play](https://play.google.com/store/apps/details?id=com.project9a.redpoint)
- Hevy: [Exercise performance](https://www.hevyapp.com/features/exercise-performance/) ·
  [Monthly report](https://www.hevyapp.com/features/monthly-report/) ·
  [2025 features guide](https://help.hevyapp.com/hc/en-us/articles/33106320824727-Everything-You-Need-to-Know-About-the-Hevy-App-2025-Features-Guide) ·
  [Sets per muscle group](https://www.hevyapp.com/features/sets-per-muscle-group-per-week/)
- Fitbod: [Muscle recovery](https://fitbod.zendesk.com/hc/en-us/articles/360006269014-Muscle-Recovery) ·
  [Volume/intensity/recovery](https://fitbod.me/blog/tracking-volume-intensity-and-recovery-with-fitbod/) ·
  [Adaptive AI](https://fitbod.me/blog/how-fitbods-ai-knows-exactly-when-you-should-lift-heavier-and-when-to-recover/)
- "On this day" memories: [Day One](https://dayoneapp.com/features/on-this-day/) ·
  [Timehop](https://play.google.com/store/apps/details?id=com.timehop)

**Auto-clip / on-device video & overlays**
- Strava stickers: [community](https://communityhub.strava.com/what-s-new-10/use-strava-stats-stickers-on-ig-stories-ios-android-9344) ·
  [runflick](https://runflick.com/blog/share-strava-on-instagram)
- Whoop Live: [support](https://support.whoop.com/hc/en-us/articles/360023429833-WHOOP-Live) ·
  [Strap 3.0 (PRNewswire)](https://www.prnewswire.com/news-releases/introducing-whoop-strap-3-0-featuring-whoop-live-300855111.html)
- Third-party tooling: [Forta](https://apps.apple.com/us/app/-/id6748439776) ·
  [STREIV](https://www.streiv.app/) ·
  [Insta360 Strava-in-video](https://www.insta360.com/blog/news/insta360-supports-strava-data-in-videos.html) ·
  [GpxOverlay](https://gpxoverlay.com/)
- iOS AVFoundation: [Kodeco overlays & animations](https://www.kodeco.com/6236502-avfoundation-tutorial-adding-overlays-and-animations-to-videos) ·
  [CoreAnimationTool without background video](https://developer.apple.com/forums/thread/107584) ·
  [custom CALayer props not animating](https://developer.apple.com/forums/thread/692858) ·
  [CoreAnimationTool + Export freezes](https://developer.apple.com/forums/thread/726146) ·
  [clear layer-instruction background](http://creativeiphonecoding.blogspot.com/2014/10/how-to-add-overlay-to-video.html)
- Android Media3 Transformer: [overview](https://developer.android.com/media/media3/transformer) ·
  [transformations](https://developer.android.com/media/media3/transformer/transformations) ·
  [Transform and roll out (2023)](https://android-developers.googleblog.com/2023/05/media-transcoding-and-editing-transform-and-roll-out.html) ·
  [performance (2025)](https://android-developers.googleblog.com/2025/03/media-processing-performance-jetpack-media3-transformer.html) ·
  [Animation with Media3 Effects](https://medium.com/aibygroup/create-an-animation-video-with-android-media-3-effects-adf4ef1e0c20) ·
  [Trim/transcode/concatenate](https://medium.com/google-exoplayer/trim-transcode-concatenate-your-guide-to-media3-editing-libraries-668b4e4c2f97) ·
  [androidx/media #810](https://github.com/androidx/media/issues/810)
- Music / beat-sync: [Splice](https://spliceapp.com/blog/best-apps-for-beat-driven-edits/) ·
  [OpusClip](https://www.opus.pro/blog/best-ai-beat-sync) ·
  [Filmora](https://filmora.wondershare.com/video-editor/best-beat-sync-video-editing-apps.html)

**Personal-now / social-ready architecture**
- [W3C — Activity Streams 2.0 Core](https://www.w3.org/TR/activitystreams-core/)
- [GetStream — Designing an activity stream/newsfeed (W3C spec)](https://getstream.io/blog/designing-activity-stream-newsfeed-w3c-spec/)
- [GetStream — Scalable activity feed architecture](https://getstream.io/blog/scalable-activity-feed-architecture/)
- [Microsoft — Event Sourcing pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing)
- [Akka — Event sourcing concepts](https://doc.akka.io/libraries/guide/concepts/event-sourcing.html)
- [Android — Build an offline-first app](https://developer.android.com/topic/architecture/data-layer/offline-first)
- [dev.to — Offline-first mobile architecture](https://dev.to/odunayo_dada/offline-first-mobile-app-architecture-syncing-caching-and-conflict-resolution-1j58)
- [inventivehq — When to use UUIDv5 deterministic IDs](https://inventivehq.com/blog/when-to-use-uuid-v5-deterministic-id-generation)
- [Salesforce IdeaExchange — Deterministic Universal Identity (UUIDv5)](https://ideas.salesforce.com/s/idea/a0B8W00000QcNkiUAF/deterministic-universal-identity-uuid-v5)
- [crdt-kit — CRDTs for local-first apps](https://github.com/crdt-kit/crdt-kit)
- [sqlite-sync — CRDT-based offline-first SQLite sync](https://github.com/sqliteai/sqlite-sync)
- [Patrick Jackson — CRDTs as a database](https://jackson.dev/post/crdts_as_database/)
