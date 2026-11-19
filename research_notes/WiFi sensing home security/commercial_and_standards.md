# Commercial WiFi-sensing products and the standards landscape for home security (state as of Nov 2026)

> Method note for the report writer: the sandbox blocked direct page fetches for almost every host (pcworld.com, tomshardware.com, xfinity.com, parksassociates.com, cablelabs.com, arxiv.org all failed to resolve). Everything below therefore comes from web-search result summaries/snippets of the linked pages, not from full-page reads. Exact figures (prices, dates, weights) should be treated as "as reported in search snippets" and spot-checked before being quoted as hard fact. Where a claim could only be traced to a set of results rather than one page, that is flagged.

## 1. What do the main vendors offer, how do they work, and which products were discontinued?

### Takeaway
By late 2026 WiFi sensing for the home is delivered almost entirely as a software feature bundled by ISPs and lighting/router brands (Comcast Xfinity WiFi Motion, Verizon Home Awareness, Plume Sense, Signify WiZ SpaceSense / Hue MotionAware), using proprietary CSI/RSSI algorithms rather than the 802.11bf standard; all deliver coarse "motion yes/no in a zone" detection, not identification or location. The largest structural changes are ADT's February 2026 purchase of Origin AI (commercial ADT products expected 2027), Comcast's August 2026 mass rollout under "Xfinity Shield", and the disappearance of the early standalone consumer attempts (Linksys Aware discontinued mid-2024; Hex Home status unclear).

### Cited Findings

**Common operating principle**
- Products watch for disruptions in the radio link between a router/AP (or bulb/pod) and a connected stationary device; a moving body perturbs the signal and software classifies that as motion. Comcast says its feature does not identify who is moving or their exact location — [TechSpot](https://www.techspot.com/news/113538-comcast-adds-home-motion-sensing-millions-xfinity-routers.html); [BleepingComputer](https://bleepingcomputer.com/news/security/comcast-turns-your-xfinity-wifi-into-a-home-motion-detector)
- ABI Research: "most Wi-Fi Sensing solutions on the market only provide simple presence detection", citing Verizon Home Awareness as the example — [ABI Research whitepaper](https://go.abiresearch.com/hubfs/Marketing/Whitepapers/The%20Commercial%20Market%20Value%20for%20Wi-Fi%20Sensing/ABi_Research_The_Commercial_Market_Value_for_WiFi_Sensing.pdf)

**Origin Wireless / Origin AI (now owned by ADT)**
- ADT announced on 24 Feb 2026 that it acquired Origin AI, "a privately held company specializing in AI-enabled Wi-Fi sensing", for $170 million in cash (subject to customary adjustments) — [ADT newsroom](https://newsroom.adt.com/corporate-news/adt-acquires-origin-ai-to-power-ai-sensing-and-ambient-intelligence-for-the-home); [ADT 8-K](https://www.sec.gov/Archives/edgar/data/1703056/000170305626000005/adt-20260224.htm)
- ADT's 10-K gives the acquisition date as 20 Feb 2026; its 2026 10-Qs report total consideration of $164 million (difference from the $170M headline not explained in the snippets) — [ADT 10-K FY2025](https://www.sec.gov/Archives/edgar/data/1703056/000170305626000022/adt-20251231.htm); [ADT 10-Q Q3 2026](https://www.sec.gov/Archives/edgar/data/0001703056/000170305626000116/adt-20260930.htm)
- ADT's stated uses: understand in-home motion and human presence without cameras, audio or wearables; reduce false alarms; improve coordination with responders. ADT expects to begin commercializing offerings using Origin's sensing in 2027 — [ADT newsroom](https://newsroom.adt.com/corporate-news/adt-acquires-origin-ai-to-power-ai-sensing-and-ambient-intelligence-for-the-home)
- Verisure (European alarm company) continues to license the technology: minimum $30 million over five years for development services plus a per-household activation fee — [ADT newsroom](https://newsroom.adt.com/corporate-news/adt-acquires-origin-ai-to-power-ai-sensing-and-ambient-intelligence-for-the-home)
- Parks Associates calls the deal a "pivotal shift" because it gives ADT control of a capability ISPs had used to differentiate broadband; ISPs named as Origin users include Verizon, Deutsche Telekom and Airties — [Parks Associates](https://www.parksassociates.com/blogs/ce-pr/adt-buys-origin-ai-what-it-means-for-isps-and-the-future-of-wi-fi-sensing); [Coverager](https://coverager.com/adt-acquires-origin-ai-for-170-million/)
- Origin's own positioning: turns standard wireless networks into a motion-sensing platform, "no cameras, microphones, or extra hardware" (vendor claim) — [Origin AI](https://www.originwirelessai.com/wifi-sensing/)

**Verizon Home Awareness (Origin-powered)**
- Launched October 2022 alongside "Device Identification"; lets select Fios router models detect disruptions in WiFi signals and alert on unexpected motion via the My Fios app; offered at no added cost. Origin Wireless is a Verizon Ventures portfolio company — [Verizon news](https://www.verizon.com/about/news/verizon-launches-new-tech-monitor-activity-home-wifi)

**Linksys Aware (Origin-powered) — DISCONTINUED**
- Launched Oct 2019 as a subscription on Velop tri-band mesh routers, $3/month or $25/year — [MacRumors](https://www.macrumors.com/2019/10/08/linksys-aware-motion-sensing); [Gizmodo 2019 review](https://gizmodo.com/motion-sensing-wifi-is-a-limited-but-fascinating-peek-a-1840373473)
- Kaspersky's blog states the service was discontinued in mid-2024 and that Linksys now says its routers have no proprietary app collecting such data. Not confirmed from an official Linksys source — [Kaspersky](https://kaspersky.com/blog/wifi-sensing-motion-detection-howto/53851); older article saying it is still offered (predates shutdown): [TechHive](https://www.techhive.com/article/579129/hex-home-security-monitors-your-wi-fi-network-to-detect-intruders.html)

**Hex Home (Origin's own consumer hardware, 2021) — status unclear, dated**
- Dedicated WiFi-sensing security kit; starter kit from $180 with one base ("Hex Command") and one WiFi sensor ("Hex Sense") — [Gizmodo](https://gizmodo.com/hex-home-security-is-a-supercharged-motion-detector-tha-1847495877); [TechHive](https://www.techhive.com/article/579129/hex-home-security-monitors-your-wi-fi-network-to-detect-intruders.html)

**Comcast Xfinity "WiFi Motion" (2025; mass rollout Aug 2026)**
- Comcast first offered WiFi Motion in 2025; on 18 Aug 2026 it began rolling it out/promoting it as part of the new "Xfinity Shield" platform across millions (one headline: "tens of millions") of gateways — [9to5Mac](https://9to5mac.com/2026/08/18/comcast-just-turned-millions-of-xfinity-routers-into-motion-sensors/); [The Next Web](https://thenextweb.com/news/comcast-xfinity-shield-wifi-motion-privacy); [Light Reading](https://www.lightreading.com/cable-technology/will-comcast-s-xfinity-shield-do-enough-to-protect-its-broadband-base-)
- Free, opt-in and off by default; low/medium/high sensitivity; requires certain DOCSIS 3.1 / DOCSIS 4.0 gateways, routers and mesh devices ("Advanced" Xfinity gateway); no extra hardware — [PCWorld](https://pcworld.com/article/3215845/xfinity-routers-can-now-sense-movement-in-your-home-without-cameras.html); [Tom's Hardware](https://tomshardware.com/networking/routers/comcast-turns-xfinity-routers-into-home-motion-detectors-free-wi-fi-sensing-feature-tracks-rf-interference-with-zero-extra-hardware-required); [CEPro](https://www.cepro.com/news/comcast-xfinity-shield-melds-the-digital-with-the-physical-using-wi-fi/628036/)
- "Exclude Small Pets" option filters motion from pets of about 40 lb or less; Comcast notes some stationary/always-on devices "still may not sense motion reliably" — [Xfinity support](https://www.xfinity.com/support/articles/wifi-motion)
- Comcast states WiFi Motion is not a replacement for a security system; with no visual data it may not distinguish a small pet from a similarly sized child — [TechRadar](https://www.techradar.com/computing/wi-fi-broadband/these-wi-fi-routers-can-help-detect-motion-in-your-home-but-are-also-sparking-privacy-worries-heres-why); [Techlicious](https://www.techlicious.com/blog/comcast-wifi-tell-when-someone-in-your-house/)
- Privacy terms: Comcast may disclose WiFi Motion information to third parties without further notice, including for law-enforcement matters; documentation does not say what is retained or for how long — [Cybernews](https://cybernews.com/privacy/comcast-xfinity-shield-routers-motion-sensors/); [Tom's Hardware (privacy)](https://www.tomshardware.com/networking/routers/new-xfinity-router-motion-detecting-feature-stokes-privacy-fears-feature-powered-by-wi-fi-signals)
- Technology supplier: secondary coverage reports that Comcast's patent cites earlier Cognitive Systems WiFi-motion patents (this came from the Aug 2026 coverage set — e.g. [The Register](https://www.theregister.com/a/5289572), [BleepingComputer](https://bleepingcomputer.com/news/security/comcast-turns-your-xfinity-wifi-into-a-home-motion-detector) — I could not pin it to a single page). No source confirmed that Comcast licenses a third-party engine.

**Cognitive Systems "WiFi Motion"**
- B2B licensing model to ISPs and health-tech partners; Plume and Airties named as partners — [CB Insights](https://www.cbinsights.com/company/cognitive-systems/customers)
- Integrated across Airties' Wi-Fi 6 portfolio (2021) — [Airties](https://www3.airties.com/?p=3637)
- Silicon integrations: Quantenna (2019), Broadcom Wi-Fi 6/6E AP chips, MaxLinear broadband SoCs (ISP products targeted H1 2023) — [Business Wire 2019](https://www.businesswire.com/news/home/20190221005529/en/Cognitive-Systems-Partners-Quantenna-Deliver-Smart-Home); [Broadband Technology Report](https://www.broadbandtechreport.com/wireless/article/14199143/cognitive-systems-brings-motion-sensing-to-broadcoms-wi-fi-6-6e-access-points); [Nasdaq/MaxLinear PR](https://www.nasdaq.com/press-release/cognitive-systems-and-maxlinear-partner-to-expand-wi-fi-sensing-accessibility-for)
- Wi-Fi NOW headline claims 37 service providers deploy Cognitive's WiFi Motion (vendor-sourced; date not visible in snippet) — [Wi-Fi NOW](https://wifinowglobal.com/news-and-blog/breakthrough-in-wi-fi-sensing-37-service-providers-deploy-cognitives-wi-fi-motion/)

**Plume Sense / Plume Motion (Cognitive-powered)**
- Offered since 2020 inside HomePass; detects disturbances between Plume pods or between a pod and a "motion-capable" WiFi device; resold by many small ISPs (Armstrong, HTC, Summit Broadband, SECV, Cablenet, Rebel Internet) — [SECV help](https://help.secv.com/help/how-does-plume-motion-work); [Armstrong](https://armstrongonewire.com/Support/Internet/Articles/PlumeMotion); [Plume blog](https://www.plume.com/homepass/blog/give-your-home-a-sixth-sense-with-plume-motion/)
- Pet mode / configurable sensitivity so pet movement can be ignored (vendor/ISP claim) — [HTC support](https://www.htcinc.net/support/internet/smart-wifi/plume-sense-features/); [Cablenet](https://cablenet.com.cy/en/internet/smart-wifi/sense/)
- One ISP support page says HomePass "will continue to function, but it will no longer receive any updates or maintenance or bug fixes from Plume" (undated; scope unclear — may apply to an older app/hardware generation only) — [Summit Broadband](https://support.summit-broadband.com/hc/en-us/articles/360055841033-What-is-Plume-Sense)

**Aerial Technologies (Aerial.ai)**
- Software agent on the home router, security and elder-care apps; reported in trials with "more than 25 Tier-1 ISPs" (c. 2023, vendor-sourced); runs on Broadcom residential 6 GHz AP/mesh platforms — [everything RF](https://everythingrf.com/news/details/13790-broadcom-s-wifi-6-6e-ap-and-mesh-solutions-now-support-wifi-sensing-applications); [WBA shortlist doc](https://wballiance.com/wp-content/uploads/2021/06/Best-Wi-Fi-Social-Impact_Shortlist_Aerial-Technologies-1.pdf)
- June 2025: nami.ai acquired a 47% equity stake in Aerial.ai, with a strategic cooperation for care-tech, prop-tech and telecom; new Aerial CEO appointed — [Newswire.ca](https://www.newswire.ca/news-releases/aerial-and-nami-announce-strategic-cooperation-to-deliver-wifi-sensing-solutions-for-the-caretech-proptech-and-telecom-industries-jean-eudes-leroy-appointed-ceo-of-aerial-ai-820439096.html)
- A 2025 arXiv "experience paper" on scaling WiFi sensing to millions of commodity devices claims "millions of deployments on home IoT devices" and that the technology "powers the home monitoring feature for the largest ISPs in the U.S. and Europe" (self-reported; authorship/company not confirmed from snippet) — [arXiv 2506.04322](https://arxiv.org/html/2506.04322v1)

**Signify: WiZ SpaceSense (WiFi) and Philips Hue MotionAware (Zigbee RF sensing)**
- WiZ SpaceSense announced Sept 2022: WiZ WiFi bulbs detect motion from WiFi signal disturbances; no exact location, no face recognition; omnidirectional, no line of sight needed; needs at least two WiZ lights in a room, ~2 m apart — [Signify PR](https://www.signify.com/en-us/our-company/news/press-releases/2022/20220916-surprisingly-thoughtful-lighting-for-everyone-signify-brings-to-light-motion-detection-technology-spacesense); [WiZ FAQ](https://faq.wizconnected.com/hc/cs/7-wiz-v2/faq/488-what-do-i-need-to-know-about-spacesense)
- WiZ later added home-monitoring use of its lights alongside an indoor camera — [Trusted Reviews](https://www.trustedreviews.com/news/wiz-adds-home-monitoring-to-its-lights-alongside-an-indoor-camera-4326357)
- Hue MotionAware (announced Sept 2025): detects motion from changes in Zigbee signals between lights; exclusive to the new Hue Bridge Pro; minimum three compatible lights per motion zone; up to 4 motion areas per Bridge Pro; not all Hue lights supported; outdoor use not recommended — [Philips Hue support](https://www.philips-hue.com/en-us/support/article/motionawaretm--transform-your-hue-lights-into-motion-sensors/000011)
- Pricing: MotionAware for lighting automation is free; security alerts require a paid Hue Secure plan. US figures relayed from The Verge: $1/month or $40/year; European figures from Hueblog: €39 basic and €99.99/year Plus (figures conflict/are region- and tier-dependent); 30-day trial — [Hueblog](https://hueblog.com/2025/09/06/do-you-have-to-pay-for-the-new-hue-motionaware/); [Gizmodo](https://gizmodo.com/oh-god-philips-hue-now-lets-you-turn-your-lights-into-surveillance-bulbs-2000653585)

**Deutsche Telekom**
- Showed WiFi sensing as a module for its concept router at MWC 2024 (door monitoring / burglary alert) and a WiFi-sensing zone for home security and health monitoring at MWC 2025 — [Telekom explainer](https://www.telekom.com/en/newsroom/latest-updates/erklaerstuecke/2025/02/wi-fi-sensing); [MWC 2025 factsheet](https://mwc.telekom.com/downloads/DT_MWC2025_Factsheet_WiFi-Sensing.pdf)
- Telekom said it plans to bring sensing to Speedport routers but had not named models or dates — [netzwelt](https://www.netzwelt.de/news/238828-vorbild-fritzbox-telekom-macht-wlan-router-einbrecher-alarmganz-ohne-kamera-0702.html)
- Speedport 7 (Wi-Fi 7, €229.99) launched Oct 2025; launch coverage does not mention sensing — [Telekom](https://www.telekom.com/en/newsroom/latest-updates/media-information/2025/10/speedport-7-devices-and-wi-fi-packages)

**Chipset level**
- Sensing engines have been ported to Broadcom Wi-Fi 6/6E AP/mesh silicon (Cognitive, Aerial), MaxLinear SoCs and Quantenna chips (see above) — [EE News Europe](https://www.eenewseurope.com/en/wifi-sensing-now-available-for-wifi-6-6e/)
- Secondary coverage of the Comcast launch says chipmakers including MediaTek and Qualcomm are working on embedding 802.11bf in Wi-Fi 7-and-later chips (unverified against vendor datasheets) — [The Next Web](https://thenextweb.com/news/comcast-xfinity-shield-wifi-motion-privacy)

**Espressif / DIY**
- ESPectre: open-source ESP32 CSI motion detector shipped as an ESPHome component; supports ESP32-C6, S3, C3, original ESP32 (C5 experimental); works against an existing 2.4 GHz router; no ML training, auto-calibration — [ESPHome](https://esphome.io/components/espectre/); [GitHub](https://github.com/sunbox/espectre); [Hackaday, Jan 2026](https://hackaday.com/2026/01/28/make-your-own-esp32-based-person-sensor-no-special-hardware-needed)

**Other**
- Threshold Care sells "Motion" AC plugs for 24/7 WiFi-signal motion detection aimed at caregiving — [Notebookcheck](https://www.notebookcheck.net/Threshold-Care-launches-Motion-AC-plugs-for-24-7-motion-detection-using-Wi-Fi-signals-for-caregiving-and-more.899983.0.html)
- Google's Nest Hub Sleep Sensing uses a radar chip (Soli), not WiFi — [MIT Technology Review](https://www.technologyreview.com/2024/02/27/1088154/wifi-sensing-tracking-movements/)

### Inferences
- The market has consolidated around two proprietary engines (Origin, Cognitive) plus in-house ISP work (Comcast) and Signify's lighting-mesh approach. Origin moving inside ADT plausibly removes the main independent supplier for ISPs other than Cognitive/Aerial, which is the point Parks Associates makes.
- Standalone consumer WiFi-sensing security products have failed commercially (Linksys Aware's paid subscription ended; Hex Home faded). The surviving model is "free feature bundled into something you already pay for", with paid tiers only for security alerting (Hue Secure) or professional monitoring (ADT/Verisure).
- Every vendor requires stationary, always-on WiFi client devices (or multiple bulbs/pods) as the "other end" of the sensing link; coverage is defined by where those devices sit, which the user cannot shape as precisely as placing a PIR sensor.

### Gaps
- No evidence found of a shipping WiFi-sensing feature from eero/Amazon, TP-Link or Google Nest Wifi as of Nov 2026. One developer blog asserts eero motion detection tied to Alexa routines and TP-Link "developing" features, but that is not a primary source ([dev.to](https://dev.to/techpulselab/wi-fi-sensing-your-smart-home-can-track-you-without-cameras-44m9)). Treat as unconfirmed.
- No vendor-by-vendor confirmation of 802.11bf support in Qualcomm, Broadcom, MediaTek or NXP parts; no datasheets found.
- Whether Verizon Home Awareness continues unchanged after ADT's purchase of Origin was not confirmed.
- Whether Deutsche Telekom has commercially launched sensing on Speedport routers by late 2026: not found.
- Hex Home's current sale/support status and the official reason for Linksys Aware's shutdown: not found (only Kaspersky's secondary statement).
- Which gateway models (XB7/XB8/XB10 etc.) and how many paired devices Xfinity WiFi Motion supports: could not read the Xfinity support page.
- No 2025-2026 Cognitive Systems press release found; its current partner count is vendor-reported and undated.

## 2. What do independent reviews say about reliability, false alarms, latency and usefulness as security versus PIR sensors and cameras?

### Takeaway
Independent hands-on testing is thin and mostly qualitative: reviewers find WiFi/RF sensing works for basic "someone is moving at home" detection and lighting automation, but describe it as rudimentary, inconsistent with mesh networks, and fiddly to tune; vendors themselves say it is not a security-system replacement. I found no independent quantitative false-alarm or detection-rate measurement for any current product.

### Cited Findings
- Linksys Aware (2019): Gizmodo called it a "limited but fascinating peek" — rudimentary, and "a little pricey given this technology's current limitations" at $3/month — [Gizmodo](https://gizmodo.com/motion-sensing-wifi-is-a-limited-but-fascinating-peek-a-1840373473). AppleInsider's hands-on was more positive ("a useful software feature") — [AppleInsider](https://appleinsider.com/articles/19/11/11/hands-on-linksys-aware-is-a-useful-software-feature-for-excellent-routers)
- Hex Home (2021): SafeWise reported it "caught all our motion throughout the testing process" without false alarms, but listed a quiet siren as a con — [SafeWise](https://www.safewise.com/hex-home-review). Gizmodo: "still feels like a concept rather than an ecosystem" — [Gizmodo](https://gizmodo.com/hex-home-security-is-a-supercharged-motion-detector-tha-1847495877)
- WiZ SpaceSense: Wired's review (headline: "These Motion-Sensing Smart Lights Aren't Worth Making the Switch") found it inconsistent and flawed and poor with mesh WiFi; results depend on router, home construction and light placement (URL is a mirror of the Wired story) — [Wired mirror](https://wirednews.pages.dev/story/wiz-spacesense-smart-lights). WiZ's own FAQ concedes that some mesh networks and repeaters degrade SpaceSense and that all participating lights should be on the same access point — [WiZ FAQ](https://faq.wizconnected.com/hc/cs/7-wiz-v2/faq/488-what-do-i-need-to-know-about-spacesense)
- Hue MotionAware: PCWorld hands-on (Nov 2025) — "magical but imperfect"; basic performance satisfactory but motion-zone settings "needlessly complicated and nitpicky" — [PCWorld](https://www.pcworld.com/article/2957900/philips-hue-turned-my-lights-into-motion-sensors-its-magical-but-imperfect.html)
- Hue MotionAware false-trigger causes listed by a third-party troubleshooting guide: fan/HVAC airflow, moving curtains, plants or hanging decor, pets; fix is to lower sensitivity stepwise (low-authority source) — [Trunetto](https://www.trunetto.com/troubleshooting/smart-lighting/philips-hue/philips-hue-motionaware-false-triggers-too-sensitive)
- Signify's own guidance: RF signals pass through objects (detects behind furniture); calibration must be done with no people or pets present; unreliable in large open/outdoor spaces — [Philips Hue support](https://www.philips-hue.com/en-us/support/article/motionawaretm--transform-your-hue-lights-into-motion-sensors/000011)
- Xfinity WiFi Motion: coverage in Aug 2026 was news/privacy reporting rather than performance testing. Comcast itself says it is not a security system replacement and cannot always tell a small pet from a similar-sized child; some devices do not sense reliably — [TechRadar](https://www.techradar.com/computing/wi-fi-broadband/these-wi-fi-routers-can-help-detect-motion-in-your-home-but-are-also-sparking-privacy-worries-heres-why); [Xfinity support](https://www.xfinity.com/support/articles/wifi-motion)
- DIY (ESPectre): detects movement, not static presence — a person sitting still eventually reads as "no motion", like PIR; needs ~10 s of stillness after boot to calibrate (user reports) — [Home Assistant community](https://community.home-assistant.io/t/espectre-wi-fi-motion-detection-for-home-assistant/961251)
- Privacy is the dominant critical theme in 2026 coverage (law-enforcement disclosure, undefined retention) — [Cybernews](https://cybernews.com/privacy/comcast-xfinity-shield-routers-motion-sensors/); [Gizmodo](https://gizmodo.com/millions-of-comcast-wifi-routers-can-now-tell-when-youre-moving-around-the-house-2000800324); [Kaspersky](https://kaspersky.com/blog/wifi-sensing-motion-detection-howto/53851)

### Inferences
- Relative to PIR: advantages claimed are no line-of-sight requirement, whole-room/through-furniture coverage and zero added hardware; disadvantages are fuzzy zone boundaries (signals pass through walls, so adjacent-room or possibly neighbor motion can register), sensitivity to airflow-moved objects and pets, dependence on network topology (mesh steering, device sleep), and a calibration step. PIR remains the more predictable, cheaper-to-reason-about trigger for alarms.
- Relative to cameras: WiFi sensing gives no verification evidence (who/what), which is why ADT frames it as a way to add context and reduce false alarms within a monitored system rather than as a standalone alarm sensor.
- The absence of rigorous third-party testing, combined with vendors' own disclaimers, means accuracy claims for security use should be treated as unverified marketing.

### Gaps
- No independent measurements of latency, detection probability or false-alarm rate (per day/week) for Xfinity WiFi Motion, Verizon Home Awareness, Plume Sense or Hue MotionAware were found.
- No documented evidence in sources found of neighbor-induced false alarms for a specific product (plausible physically; unverified).
- No reviews found from The Verge, Ars Technica, CNET, Tom's Guide or PCMag with hands-on performance testing of the 2026 Xfinity rollout (could not fetch those sites).
- The Wired SpaceSense review was only reachable via a mirror URL; original date/score not confirmed.

## 3. What is the status and content of IEEE 802.11bf, what is the Wi-Fi Alliance doing, and how do Wi-Fi 6/6E/7 features affect sensing?

### Takeaway
IEEE Std 802.11bf-2025 ("Enhancements for Wireless LAN Sensing", Amendment 4 to 802.11) was approved 28 May 2025 and published 26 September 2025, covering sub-7.125 GHz and >45 GHz (60 GHz DMG) bands; it standardizes how devices negotiate and exchange sensing measurements, not the detection algorithms. As of late 2026 I found no confirmed consumer product advertising 802.11bf compliance — deployed products are "legacy"/proprietary — and Wi-Fi Alliance certification for sensing is listed as a work area but its content and launch could not be verified.

### Cited Findings
- Publication: IEEE Std 802.11bf-2025, Amendment 4: Enhancements for Wireless LAN Sensing; approved by the IEEE SA Standards Board 28 May 2025; published 26 Sept 2025 (taken from a copy of the standard on a FreeBSD developer mirror; IEEE Xplore is the authoritative record) — [802.11bf-2025 copy](https://people.freebsd.org/~adrian/net80211/80211bf-2025.pdf)
- Scope: enhancements for WLAN sensing in license-exempt bands between 1 GHz and 7.125 GHz and above 45 GHz — [802.11bf-2025 copy](https://people.freebsd.org/~adrian/net80211/80211bf-2025.pdf)
- History: Task Group bf formed Sept 2020; draft D0.1 in April 2022; originally expected to complete late 2024 (slipped to 2025) — [IEEE SA Beyond Standards](https://standards.ieee.org/beyond-standards/ieee-802-11bf-aims-to-enable-a-new-application-of-wlan-technology-wlan-sensing); [arXiv overview 2207.04859](https://arxiv.org/pdf/2207.04859)
- Content: defines how stations advertise sensing capabilities and request/set up transmissions for sensing measurements; supports bistatic and multistatic sensing below 7 GHz (2.4, 5, 6 GHz) and a DMG/EDMG sensing procedure at 60 GHz for high-resolution mmWave sensing — [arXiv overview 2310.17661](https://arxiv.org/pdf/2310.17661); [NIST DMG sensing paper](https://www.nist.gov/publications/ieee-80211bf-dmg-sensing-enabling-high-resolution-mmwave-wi-fi-sensing)
- Sensing algorithms and applications are out of scope and left to vendors — [arXiv 2212.13930](https://arxiv.org/pdf/2212.13930)
- CableLabs (May 2026): the 802.11bf standard is complete, and "legacy" (pre-standard) sensing products are already available and being deployed — [CableLabs blog](https://www.cablelabs.com/blog/how-wireless-networks-are-learning-to-sense-the-world-around-them)
- Wi-Fi Alliance: its "Current Work Areas" page lists Sensing (search snippet shows "Certification available" next to it, but I could not read the page to confirm what that label attaches to) — [Wi-Fi Alliance](https://www.wi-fi.org/node/15523)
- Wireless Broadband Alliance (separate body): has advocated WiFi sensing since 2018, published guidelines/white papers that fed 802.11bf, and is developing a phased test plan intended as the basis of a compliance mechanism or certification program — [WBA Wi-Fi Sensing project](https://wballiance.com/wi-fi-sensing/); [Lightwave](https://www.lightwaveonline.com/broadband/article/55031593/wireless-broadband-alliance-issues-wi-fi-sensing-technology-guidelines)
- Cognitive Systems' view (vendor): after the written standard, a Wi-Fi Alliance certification program is needed for interoperability and would run as a parallel track — [WBA blog](https://wballiance.com/the-road-towards-standardization-expert-insights-on-the-future-of-wifi-sensing/)
- Device timing: chipmakers (MediaTek, Qualcomm named) reported to be working on 802.11bf in Wi-Fi 7-and-later chips (secondary press, no dates) — [The Next Web](https://thenextweb.com/news/comcast-xfinity-shield-wifi-motion-privacy)

### Inferences
- Because 802.11bf standardizes measurement exchange (so an AP can ask any compliant client to sound the channel and report CSI) rather than detection, its practical effect will be to remove today's dependence on vendor-specific device compatibility lists ("motion-capable devices"), not to guarantee accuracy.
- Standard published Sept 2025 plus typical silicon and certification lead times implies mainstream 802.11bf-compliant consumer gear is more likely a 2027+ (Wi-Fi 7 refresh / Wi-Fi 8 era) phenomenon; this is an inference, not a sourced date.
- Wider channels (160/320 MHz at 6 GHz) improve range resolution and more antennas/MIMO streams improve spatial diversity for sensing; 60 GHz gives fine resolution at short range. This is standard RF reasoning consistent with the 802.11bf overview papers, but I could not extract specific sourced figures.

### Gaps
- No sourced numbers for how bandwidth/MIMO in Wi-Fi 6/6E/7 quantitatively improves sensing (arXiv fetch blocked).
- Whether a "Wi-Fi CERTIFIED Sensing" program has formally launched, its name, date and test scope: not confirmed.
- No named product or chipset confirmed as 802.11bf-compliant as of Nov 2026.
- Details of 802.11bf mechanisms (trigger-based vs non-trigger-based measurement instances, sensing by proxy, privacy provisions) could not be verified from fetched text; they appear in the linked overview papers.

## 4. Market size estimates, trends, and smart-home platform integrations (Home Assistant, Matter, Alexa, HomeKit)

### Takeaway
Market-size figures vary by an order of magnitude with definition (2025 base roughly $0.4B-$2.3B; 2034 forecasts ~$5B-$15B) and come from low-transparency report vendors; the most credible single datapoint is ABI Research's forecast of 112 million sensing-capable WiFi CPE installed in North America by 2030. Platform integration is weak: ISP sensing lives in ISP apps, Hue MotionAware is exposed to Home Assistant via the Hue integration but has been flaky, and the only fully open path is DIY ESP32 CSI (ESPectre) through ESPHome.

### Cited Findings
- ABI Research: North American WiFi-sensing-capable CPE installations forecast to reach 112 million by 2030 — [ABI Research](https://abiresearch.com/press/north-american-wi-fi-sensing-cpe-installations-to-surge-to-112-million-by-2030-as-the-technologys-maturing-unleashes-new-business-and-service-models)
- Market Intelo: WiFi sensing market $1.2B (2025) to $9.8B (2034), 27.5% CAGR — [Market Intelo](https://marketintelo.com/report/wi-fi-sensing-market)
- Market Intelo: WiFi sensing device market $1.8B (2025) to $13.2B (2034), 27.3% CAGR — [Market Intelo](https://marketintelo.com/report/wi-fi-sensing-device-market)
- Market Intelo: "IEEE 802.11bf sensing market" $2.3B (2025) to $14.7B (2034), 22.8% CAGR — [Market Intelo](https://marketintelo.com/report/ieee-80211bf-sensing-market)
- Market Intelo: WiFi-sensing home health monitoring devices $0.75B (2025) to $5.0B (2034), 38.0% CAGR — [Market Intelo](https://marketintelo.com/report/wi-fi-sensing-home-health-monitoring-devices-market)
- Growth Market Reports: WiFi sensing chip market $1.32B in 2025; WiFi CSI sensing market $420M in 2025 — [GMR chips](https://growthmarketreports.com/report/wi-fi-sensing-chip-market); [GMR CSI](https://growthmarketreports.com/report/wi-fi-csi-sensing-market)
- Trend — security incumbents buying in: ADT/Origin ($170M, Feb 2026) and Verisure license; TechInsights frames it as "ambient sensing is the future of smart home" — [TechInsights](https://www.techinsights.com/ja/node/61165); [Parks Associates](https://www.parksassociates.com/blogs/home-systems-and-controls/adt-moves-to-enhance-its-tech-stack-and-value)
- Trend — ISPs using sensing for retention: Light Reading questions whether Comcast's Xfinity Shield will "do enough to protect its broadband base" — [Light Reading](https://www.lightreading.com/cable-technology/will-comcast-s-xfinity-shield-do-enough-to-protect-its-broadband-base-)
- Trend — analyst coverage: Counterpoint report "Wi-Fi Motion Sensing: Adding Value to Home Networks" — [Counterpoint](https://www.counterpointresearch.com/report/post-report-wifi-motion-sensing-adding-value-to-home-networks)
- Home Assistant + Hue MotionAware: users report MotionAware zones appear in Home Assistant via the Hue integration but stopped updating after a Bridge Pro software update on 9 April (2026), with aiohue parsing errors and new zones not exposed; later posts say it resumed, cause unidentified (anecdotal) — [Home Assistant community](https://community.home-assistant.io/t/hue-motionaware-stopped-working/1003387)
- Home Assistant + ESPectre: native ESPHome component with auto-discovery; exposes a binary motion sensor, a movement score sensor and an adjustable threshold entity — [ESPHome](https://esphome.io/components/espectre/); [Seeed Studio wiki](https://wiki.seeedstudio.com/xiao-esp32--series-espresense/)
- Origin Wireless is listed as a Connectivity Standards Alliance (Matter's parent body) member — [CSA](https://csa-iot.org/member/origin-wireless-inc/)
- Hue security alerts from MotionAware are gated behind the Hue Secure subscription, i.e. inside Hue's own app/cloud — [Hueblog](https://hueblog.com/2025/09/06/do-you-have-to-pay-for-the-new-hue-motionaware/)

### Inferences
- The dollar forecasts are not comparable to each other and the vendors (Market Intelo, Growth Market Reports) publish many near-identical niche reports; a report writer should present them as a range with low confidence and lean on ABI's unit forecast and on concrete events (Comcast's installed base, the $170M Origin price) as better indicators of scale.
- ISP-delivered sensing (Xfinity, Verizon, Plume) appears to be a closed silo: no evidence was found of motion events being exposed to Matter, HomeKit, Alexa routines or Home Assistant. Signify is the only mainstream vendor whose RF-sensing output demonstrably reaches a third-party platform.
- For a builder wanting local, platform-neutral WiFi sensing today, ESP32 CSI nodes via ESPHome are the practical route, with PIR-like motion (not static presence) capability.

### Gaps
- Whether Hue MotionAware zones are exposed over Matter (and thus to Apple Home / Alexa / Google Home) as occupancy sensors: not confirmed.
- Any Alexa, HomeKit or Matter integration for Xfinity WiFi Motion, Verizon Home Awareness or Plume Sense: none found.
- ABI Research's current installed-base number (pre-2030) and methodology: not visible in snippets.
- No global household-penetration or active-user figures (opt-in rates) for any ISP sensing feature were found.
