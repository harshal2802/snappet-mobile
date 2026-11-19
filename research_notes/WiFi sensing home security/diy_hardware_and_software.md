# DIY WiFi-Sensing (CSI) Home Security / Presence Detection: Hardware and Open-Source Software (state as of Nov 2026)

Research-method note for the report writer: this session's network sandbox blocked direct fetches of community.home-assistant.io, hackaday.com, cnx-software.com, korben.info, iotforall.com and hackster.io. GitHub pages were fetched directly. Findings marked **[snippet]** come only from search-result summaries of those blocked pages (not full-page reads) and should be treated as lower confidence. Star counts are as displayed on GitHub on 2026-11-19.

---

## 1. What CSI-capable hardware exists and how do the options compare? Which are still practical in 2026?

### Takeaway
For a home builder the ESP32 family is the only genuinely low-cost, in-production, well-supported CSI platform (roughly $5-15 per node; Espressif itself ranks C5 > C6 > C3 ≈ S3 > classic ESP32 for CSI quality). Raspberry Pi + Nexmon (up to 80 MHz, 256 subcarriers) and Intel AX200/AX210 + PicoScenes/FeitCSI (up to 160 MHz, 6 GHz) are the practical "research-grade" step-ups; Intel 5300 and Atheros 802.11n tools are legacy, and SDRs are overkill for presence detection.

### Cited Findings

**ESP32 family (Espressif esp-csi)**
- Espressif states "All ESP32 series support CSI", listing ESP32, ESP32-S2, ESP32-C3, ESP32-S3, ESP32-C5, ESP32-C6, ESP32-C61. — [espressif/esp-csi](https://github.com/espressif/esp-csi)
- Espressif's CSI-quality ranking: ESP32-C5 > ESP32-C6 > ESP32-C3 ≈ ESP32-S3 > ESP32. **[snippet]** — [Espressif esp-csi docs/README](https://documentation.espressif.com/esp-csi/master/README.md); [ESP-Techpedia: Introduction to ESP-CSI Solution](https://docs.espressif.com/projects/esp-techpedia/en/latest/esp-friends/solution-introduction/esp-csi/esp-csi-solution.html)
- Subcarrier counts (from the third-party `esp-csi-rs` Rust crate docs, not from Espressif): ~53 subcarriers for legacy 20 MHz L-LTF, ~56 for HT20 HT-LTF, ~117-128 for HT40 on C5/C6 (csi_data_len / 2); a full HE20 (Wi-Fi 6) estimate on C5/C6 is ~242 subcarriers and requires HE-LTF acquisition. **[snippet]** — [esp-csi-rs on docs.rs](https://docs.rs/esp-csi-rs)
- Espressif notes an external IPEX antenna performs better than the on-board PCB antenna, which is directional. — [espressif/esp-csi](https://github.com/espressif/esp-csi)
- Espressif describes three ways to obtain CSI: (1) "router CSI" - one ESP32 pings the router and reads CSI from ping replies (simplest; depends on router placement and Wi-Fi protocol support); (2) between devices - ESP32s ping the router and one reads CSI from the other's traffic; (3) a dedicated broadcast sender on a fixed channel, which Espressif says gives the highest accuracy and reliability but needs extra hardware. — [espressif/esp-csi](https://github.com/espressif/esp-csi)
- Prices: Espressif's ESP32-C5-DevKitC-1 was listed at $15 plus shipping on Espressif's official AliExpress store; Waveshare lists an ESP32-C5-Pico at $8.99-9.99 and an ESP32-C5-MINI-KIT at $7.99-8.99. **[snippet; date of prices unverified]** — [Hackster news on ESP32-C5-DevKitC-1](https://www.hackster.io/news/espressif-s-dual-band-esp32-c5-finally-lands-on-the-15-esp32-c5-devkitc-1-development-board-549233d8db52); [Waveshare catalog](https://www.waveshare.com/product.htm?cat=340&dir=asc&p=5)
- The RuView README prices an ESP32-S3 node at "~$9" and an ESP32-C6 at "~$10", and a 3-6 node ESP32-S3 mesh plus router at "~$54". (Project's own figures.) — [RuView README](https://raw.githubusercontent.com/ruvnet/RuView/main/README.md)
- MicroPython gained direct CSI methods on `network.WLAN` via PR 18460 (credited by ESPectre), so CSI is reachable from MicroPython as well as ESP-IDF, ESPHome and Rust (`esp-csi-rs`). — [ESPectre README](https://raw.githubusercontent.com/francescopace/espectre/main/README.md); [esp-csi-rs](https://docs.rs/esp-csi-rs)

**Raspberry Pi / Broadcom + Nexmon CSI**
- Supported chips/devices: bcm4339 (Nexus 5), bcm43455c0 fw 7_45_189 (Raspberry Pi 3B+/4B/5), bcm4358 (Nexus 6P), bcm4366c0 (Asus RT-AC86U). — [seemoo-lab/nexmon_csi](https://github.com/seemoo-lab/nexmon_csi)
- Bandwidth up to 80 MHz; 64 / 128 / 256 CSI values per frame at 20 / 40 / 80 MHz (including guard and null carriers, which contain arbitrary values and must be removed/zeroed). — [seemoo-lab/nexmon_csi](https://github.com/seemoo-lab/nexmon_csi)
- Kernels 4.19, 5.4 and 5.10 need a modified brcmfmac driver; a separate `Makefile.rpi` supports recent Raspberry Pi OS kernels without a modified driver, and discussion #395 holds the Pi 5 / recent-kernel tutorial. — [seemoo-lab/nexmon_csi](https://github.com/seemoo-lab/nexmon_csi)
- Operational constraints: capture requires monitor mode; on bcm43455c0 wpa_supplicant must be stopped first (i.e. the Pi's Wi-Fi is not a normal client while capturing); CSI is per received frame so a traffic source is required and the extraction rate is controlled by the transmitter; 20 MHz frames inside a 40/80 MHz channel yield mostly empty CSI; CSI formats differ between chips. — [seemoo-lab/nexmon_csi](https://github.com/seemoo-lab/nexmon_csi)
- Maturity signal: 484 stars, 147 forks, 171 open issues, only 43 commits. — [seemoo-lab/nexmon_csi](https://github.com/seemoo-lab/nexmon_csi)
- A community fork (nexmonster/nexmon_csi) offers a kernel 5.10.92 branch for Pi 3B+/4 but does not mention Pi 5. **[snippet]** — [nexmonster/nexmon_csi](https://github.com/nexmonster/nexmon_csi)

**Intel 5300 (Linux 802.11n CSI Tool)**
- The IWL5300 chipset dates to 2008 and is no longer in production; a 2023 paper describes the tool's supported NIC as discontinued, though research still leans on it because of the open tooling. **[snippet]** — [Linux 802.11n CSI Tool](https://dhalperi.github.io/linux-80211n-csitool); [arXiv 2305.10554](https://arxiv.org/pdf/2305.10554)
- Intel 5300 setups need a host PC for the NIC and cannot do standalone collection, unlike ESP32. **[snippet]** — [Hernandez & Bulut, ESP32 CSI tool paper](https://ebulutvcu.github.io/wowmom20-WiFiSensing.pdf)
- RuView's README still prices "Research NIC (Intel 5300 / Atheros AR9580)" at ~$50-100 with 3x3 MIMO. (Project's own estimate.) — [RuView README](https://raw.githubusercontent.com/ruvnet/RuView/main/README.md)

**Atheros CSI Tool**
- Open-source 802.11n measurement tool built on the ath9k Linux driver for Atheros 802.11n PCI/PCIe chips; 802.11n only. **[snippet]** — [Tsinghua WiFi sensing tools tutorial](https://tns.thss.tsinghua.edu.cn/wst/docs/tools)
- RuView notes that Qualcomm's modern ath11k/ath12k do "not claim public CSI export". — [RuView README](https://raw.githubusercontent.com/ruvnet/RuView/main/README.md)

**Intel AX200 / AX210 (PicoScenes, FeitCSI)**
- PicoScenes supports Intel AX210, AX200, Qualcomm Atheros AR9300 (QCA9300), Intel 5300, plus SDRs (HackRF One and all USRP models). **[snippet]** — [PicoScenes](https://ps.zpj.io/)
- PicoScenes licensing: "the majority of features are available free of charge"; a license fee applies to certain advanced features, only for SDR frontends. **[snippet]** — [PicoScenes Features & License](https://ps.zpj.io/manual/features_pricing.html)
- PicoScenes requires amd64; its manual states ARM is unsupported (per a 2026 paper proposing an alternative, "VesperCSI", for edge devices). **[snippet]** — [VesperCSI, arXiv 2610.22581](https://arxiv.org/html/2610.22581)
- A PicoScenes issue-tracker report shows an AX210 user seeing certain subcarriers with no signal. **[snippet]** — [PicoScenes issue #213](https://gitlab.com/wifisensing/picoscenes-issue-tracker/-/issues/213)
- FeitCSI: GPL-3.0, fully open-source CSI extraction and frame injection for Intel AX200 and AX210; 802.11 a/g/n/ac/ax; 20/40/80/160 MHz; 6 GHz band (5945-7125 MHz) depending on NIC; PCI-connected NICs on any Linux architecture. Only 38 stars and 9 commits. — [KuskoSoft/FeitCSI](https://github.com/KuskoSoft/FeitCSI)

**SDRs and routers**
- PicoScenes drives HackRF One ("just over 100$") and USRPs; Wi-Fi 7 (802.11be) support is for SDR devices, not NICs. **[snippet]** — [PicoScenes tutorial slides](https://www.slideshare.net/ZhipingJiang1/picoscenes-tutorial-cpsiot-week2022); [PicoScenes](https://ps.zpj.io/)
- Commodity-router CSI: the Asus RT-AC86U (bcm4366c0) is the router supported by nexmon_csi. — [seemoo-lab/nexmon_csi](https://github.com/seemoo-lab/nexmon_csi)

### Comparison table (compiled from the findings above; blank = not sourced this session)

| Platform | Approx. cost | Bandwidth / subcarriers | Standalone? | 2026 practicality |
|---|---|---|---|---|
| ESP32-C5 / C6 | ~$8-15 board | 20 MHz ~53-56; HT40 ~117-128; HE20 ~242 | Yes | Best choice; in production; top of Espressif's ranking |
| ESP32-S3 / C3 | ~$5-10 board | 20/40 MHz 802.11n | Yes | Fine; mid-ranked |
| Classic ESP32 | cheapest | 20/40 MHz 802.11n | Yes | Works; lowest ranked for CSI |
| Raspberry Pi 3B+/4B/5 + nexmon_csi | Pi price | 20/40/80 MHz; 64/128/256 values | Yes (but Wi-Fi tied up in monitor mode) | Usable but fiddly; kernel/firmware-sensitive |
| Asus RT-AC86U + nexmon_csi | used router | up to 80 MHz, multi-antenna | Yes | Legacy router; niche |
| Intel AX200/AX210 + PicoScenes / FeitCSI | cheap M.2 card + x86 Linux host | up to 160 MHz, 6 GHz | No (PC host) | Best research-grade option that is still sold |
| Intel 5300 | ~$50-100 est. (used) + old host | 802.11n | No | Discontinued; legacy only |
| Atheros ath9k tool | used cards | 802.11n | No | Legacy only |
| SDR (HackRF/USRP) + PicoScenes | $100+ to thousands | arbitrary | No | Overkill for presence |

### Inferences
- ESP32-C6 is the pragmatic default in late 2026: second in Espressif's ranking, cheap, widely stocked and the first-listed chip for ESPectre. ESP32-C5 is the upgrade when 5 GHz is wanted (less congested band); note ESPectre itself requires a 2.4 GHz Wi-Fi 4 network, so the 5 GHz benefit only applies with esp-csi or custom firmware.
- Intel AX210 + FeitCSI (fully open) or PicoScenes (free for NICs, closed core, amd64-only) is the right tool only if the builder wants high-bandwidth data for ML experiments - not for a deployable alarm sensor, since it needs an always-on x86 Linux box per receiver.
- Nexmon on a Pi has a much worse issues-to-commits ratio (171 open issues / 43 commits) than esp-csi and takes over the Pi's Wi-Fi; a Pi is better used as the processing hub (MQTT broker / Home Assistant) for ESP32 nodes than as the CSI sensor.
- Background knowledge not verified this session (treat as unsourced): the Intel 5300 tool reports 30 subcarrier groups across up to 3 antennas, the Pi's bcm43455c0 is single-antenna (1x1), and openwifi is an FPGA/SDR full-stack Wi-Fi implementation whose boards cost far more than any option above.

### Gaps
- No source found this session for ESP32 maximum reliable CSI sampling rates per chip, or for exact current street prices of ESP32-C6/S3/C3 dev boards (commonly a few dollars on AliExpress - unverified).
- openwifi, ZTE and OpenWrt-based CSI extraction (other than the nexmon RT-AC86U path) were not covered by any source retrieved; nothing indicates a low-cost, maintained OpenWrt CSI route for current Wi-Fi 6/7 routers.
- Could not confirm Intel BE200 (Wi-Fi 7) CSI support in PicoScenes or FeitCSI; FeitCSI says only that newer Intel NICs have a "high possibility" of working.
- Current used-market price/availability of Intel 5300 cards not verified beyond RuView's estimate.
- Could not read nexmon_csi discussion #395 to confirm how smooth Pi 5 / Bookworm / Trixie setup actually is.

---

## 2. What open-source projects exist, how mature are they, and are the viral repos real?

### Takeaway
ESPectre (9.8k stars, ESPHome/Matter/MQTT, training-free motion detection) and Espressif's own esp-csi/esp-radar are the mature, functional choices for a home build; TOMMY is a working but partly closed/freemium alternative. RuView / "WiFi DensePose" (55k+ stars) is heavily overhyped: by the maintainer's own admissions its ESP32 detection is heuristic, its skeleton is synthesized rather than inferred, its live pose accuracy is PCK@20 ≈ 3%, and it shipped simulated-data fallbacks that misled users.

### Cited Findings

**Espressif esp-csi / esp-radar (official)**
- 1.8k stars, 277 forks, 91 open issues, 211 commits, Apache-2.0. — [espressif/esp-csi](https://github.com/espressif/esp-csi)
- Examples: `get-started/csi_recv`, `csi_send`, `csi_recv_router` (router sends, triggered by ESP32 ping) and Python parsing tools; `esp-radar/console_test` (interactive console to configure/capture CSI), `connect_rainmaker` (uploads to Espressif RainMaker cloud), and `wifi_sensing_demo` (motion and presence detection with on-site training, LED feedback, Web Serial monitor). — [espressif/esp-csi](https://github.com/espressif/esp-csi)
- esp-radar is published as an ESP Component Registry component; v0.3.0 added ESP32-C5/C6/C61 support and later releases changed the default LTF type to LLTF. **[snippet]** — [esp-radar changelog](https://components.espressif.com/components/espressif/esp-radar/versions/0.3.4/changelog?language=en)

**ESPectre (francescopace/espectre)**
- 9.8k stars, 740 forks, 917 commits, 88 watchers. GPLv3 with a separate commercial license for closed-source firmware (the ESPHome frontend is GPLv3-only). — [francescopace/espectre](https://github.com/francescopace/espectre)
- Supports ESP32-C6, C5, C3, S3, S2 and classic ESP32; requires a normal Wi-Fi 4 (802.11n) 2.4 GHz network; all processing on-device. — [ESPectre README](https://raw.githubusercontent.com/francescopace/espectre/main/README.md)
- Firmware paths: native, ESPHome, Matter, and "Micro-ESPectre" (MicroPython). Matter tested with Google Home, Apple Home and Home Assistant (Alexa/SmartThings untested). Integrates via ESPHome or MQTT (with MQTT Discovery). — [ESPectre README](https://raw.githubusercontent.com/francescopace/espectre/main/README.md)
- Stated limits: "ESPectre detects changes in the radio environment"; it "does not identify people, count them, prove that a room is empty, or replace a safety-certified security, medical, or emergency system." — [francescopace/espectre](https://github.com/francescopace/espectre)
- Publishes research assets: CSI dataset (empty room, static presence, motion), model weights in C++ and Python, a feature analysis including rejected experiments, generated performance reports and a literature review. — [ESPectre README](https://raw.githubusercontent.com/francescopace/espectre/main/README.md)
- Ecosystem adoption: an ESPHome component page exists, Seeed Studio publishes a XIAO ESP32 deployment guide, Adafruit maintains a fork with an Arduino port for Feather ESP32-S3, and it is in the ESP Component Registry (v3.2.0 seen). **[snippet]** — [ESPHome ESPectre component](https://esphome.io/components/espectre/); [Seeed wiki](https://wiki.seeedstudio.com/xiao-esp32--series-espresense/); [adafruit/espectre](https://github.com/adafruit/espectre); [ESP Component Registry](https://components.espressif.com/components/francescopace/espectre/versions/3.2.0/readme)
- Covered by Hackaday on 2026-01-28 ("Make your own ESP32-based person sensor, no special hardware needed"). **[snippet; article not readable]** — [Hackaday](https://hackaday.com/2026/01/28/make-your-own-esp32-based-person-sensor-no-special-hardware-needed)

**TOMMY (tommysense.com)**
- Wi-Fi sensing for Home Assistant, first released August 2025; runs as an HA add-on or Docker container; flash ESP32s with a browser flasher or add an external component to existing ESPHome devices; zones each need two devices and appear as motion sensor entities; integrates over MQTT and can expose zones to Matter. **[snippet]** — [tommysense.com](https://tommysense.com/); [tommysense llms.txt](https://www.tommysense.com/llms.txt)
- Free Community Edition and one-time-purchase Pro Edition; the HA integration and ESPHome component are open source (the core engine's openness was not confirmed). v1.2.0 added stationary presence detection. **[snippet]** — [HA forum: TOMMY v1.2.0](https://community.home-assistant.io/t/tommy-v1-2-0-now-with-stationary-presence-detection/974408); [HA forum: Through-wall motion sensor using Wi-Fi Sensing](https://community.home-assistant.io/t/through-wall-motion-sensor-using-wi-fi-sensing/928370)

**ESP32-CSI-Tool (Steven M. Hernandez)**
- 587 stars, 124 forks, 37 open issues, 85 commits, MIT. Requires ESP-IDF v4.3 (old). Modes: active station, active AP, passive. Only the classic ESP32 is named. Outputs CSV over serial (recommended 921600 baud or higher) or SD card. — [StevenMHernandez/ESP32-CSI-Tool](https://github.com/StevenMHernandez/ESP32-CSI-Tool)
- A third-party aggregator listed its last update as July 2024. **[snippet]** — [relatedrepos](https://relatedrepos.com/gh/StevenMHernandez/ESP32-CSI-Tool)

**Wi-ESP**
- ESP32-based CSI tool from WRL Lab, KIST (South Korea), described in a 2020 Journal of Computational Design and Engineering paper; project page still shows "Coming Soon" in a section and no recent release was found. **[snippet]** — [Wi-ESP](https://wrlab.github.io/Wi-ESP)

**CSIKit**
- Python CLI and library for parsing, processing and visualising CSI from multiple hardware formats, including ESP32 via ESP32-CSI-Tool. **[snippet]** — [Gi-z/CSIKit](https://www.github.com/Gi-z/CSIKit)

**SenseFi (WiFi-CSI-Sensing-Benchmark)**
- 648 stars, 113 forks, 61 commits, MIT; PyTorch benchmark/library accompanying a paper in Patterns (Cell Press). Models: MLP, LeNet, ResNet18/50/101, RNN, GRU, LSTM, BiLSTM, CNN+GRU, ViT. Datasets: UT-HAR (7 activity classes, 1x250x90), NTU-Fi HAR (6 classes, 3x114x500), NTU-Fi HumanID (14 subjects by gait), Widar (22 gestures). — [xyanchen/WiFi-CSI-Sensing-Benchmark](https://github.com/xyanchen/WiFi-CSI-Sensing-Benchmark)

**nexmon_csi, PicoScenes, FeitCSI** — see Section 1.

**RuView / "WiFi DensePose" (ruvnet/RuView, formerly ruvnet/wifi-densepose)**
- Claims: detect people, measure breathing and heart rate, track movement "through walls, in the dark, with no cameras or wearables", 17-keypoint pose, fall detection, multi-person counting. — [RuView README](https://raw.githubusercontent.com/ruvnet/RuView/main/README.md)
- Popularity: reported to have passed 55,000 GitHub stars by May 2026. **[snippet]** — [TechTimes, 2026-05-17](https://www.techtimes.com/articles/316748/20260517/ruview-passes-55000-github-stars-wifi-sensing-law-it-outran-has-not-arrived.htm)
- The README itself now concedes: "The Docker image runs with simulated data for evaluation"; "the older '100% presence' figure was measured on a single-class recording and has been retracted"; the 82.3% number is a label-free "held-out temporal-triplet accuracy"; the live single-ESP32 pose model scores "PCK@20 = 3.0% / PCK@50 = 18.5%" on a 217-sample holdout, "below the ADR-079 target of ≥ 35%"; the pose runtime path is "still a centred-skeleton stub returning confidence=0"; device vitals are "labelled as unvalidated". — [RuView README](https://raw.githubusercontent.com/ruvnet/RuView/main/README.md)
- The strong published number (82.69% torso-PCK@20) is an offline benchmark on the MM-Fi academic dataset, not a live ESP32 result. — [RuView README](https://raw.githubusercontent.com/ruvnet/RuView/main/README.md); [RuView user guide](https://github.com/ruvnet/RuView/blob/main/docs/user-guide.md)
- Maintainer statements in issue #299 (opened 2026-03-24 by a user with two ESP32 nodes who got no motion detection and no skeleton): "The current detection pipeline is heuristic-based (signal processing + thresholds), not a trained ML model"; skeleton keypoints are "synthesized from CSI signal features"; "the current pipeline does not generate full skeleton models from WiFi alone"; "The 3D skeleton you see in the UI is a visualization driven by CSI heuristics, not a true DensePose reconstruction." The neural pose crate is "not deployed in the default sensing server". — [RuView issue #299](https://github.com/ruvnet/RuView/issues/299)
- PR #1431 ("Remove all simulated-data fallback mechanisms") describes the fallback as having deceived users into thinking they had working hardware when no real ESP32 CSI was connected; merge status not confirmed. **[snippet]** — [RuView PR #1431](https://github.com/ruvnet/RuView/pull/1431)
- Open issues reported include the per-node presence classifier reporting "present" on 99.6% of an empty room (ESP32-C6) and demo-scenario captions appearing in LIVE mode. **[snippet]** — [RuView issues](https://github.com/ruvnet/wifi-densepose/issues)
- RuView says classic ESP32 and ESP32-C3 are unsupported ("single-core, insufficient for CSI DSP"), recommends 3+ nodes for skeleton modelling, and upsells an "ESP32 + Cognitum Seed" bundle at ~$140. — [RuView README](https://raw.githubusercontent.com/ruvnet/RuView/main/README.md); [RuView issue #299](https://github.com/ruvnet/RuView/issues/299)
- Outside criticism: Korben.info ran "WiFi DensePose: the fake GitHub project with 25,000 stars?", alleging the CSI parser generated random data and that the one user who connected a real ESP32 saw a frozen figure with fake measurements; a CNX Software commenter called the code "AI slop"; a Home Assistant forum thread asks "Has anyone actually gotten RuView (WiFi DensePose) to work in real world?"; the maintainer's rebuttal is issue #37, "No, this is not fake. Yes, it actually works. Read the docs." **[snippet; pages not readable]** — [Korben](https://korben.info/en/wifi-densepose-fake-github-project-25000-stars.html); [CNX Software, 2026-03-26](https://www.cnx-software.com/2026/03/26/ruview-project-leverages-esp32-nodes-for-presence-detection-pose-estimation-and-breathing-heart-rate-monitoring/); [HA forum thread](https://community.home-assistant.io/t/has-anyone-actually-gotten-ruview-wifi-densepose-to-work-in-real-world/1002053); [RuView issue #37](https://github.com/ruvnet/RuView/issues/37)
- The underlying academic idea is real: CMU's "DensePose From WiFi" used multi-antenna Wi-Fi arrays in a structured lab setting. **[snippet]** — [Gadgetbyte](https://www.gadgetbytenepal.com/pi-ruview)

### Maturity summary (compiled)

| Project | Stars | Role | Verdict for a home build |
|---|---|---|---|
| ESPectre | 9.8k | Turnkey motion sensor firmware (ESPHome/Matter/MQTT) | Recommended starting point |
| espressif/esp-csi + esp-radar | 1.8k | Official SDK, examples, on-device motion/presence demo | Recommended for custom firmware |
| TOMMY | n/a (partly closed) | HA add-on, 2-device zones, stationary detection in v1.2.0 | Works; freemium |
| ESP32-CSI-Tool | 587 | Data collection to CSV | Dated (ESP-IDF 4.3); data capture only |
| nexmon_csi | 484 | Broadcom CSI extraction | Research capture; fiddly |
| SenseFi | 648 | PyTorch model benchmark | Offline ML experiments only |
| FeitCSI | 38 | Open Intel AX200/AX210 CSI | Small but uniquely open for 160 MHz / 6 GHz |
| PicoScenes | n/a | Multi-hardware CSI platform | Mature, partly closed, amd64 only |
| Wi-ESP | n/a | 2020 academic tool | Appears stale |
| RuView | 55k+ | "Pose/vitals through walls" | Do not rely on; presence-level heuristics at best |

### Inferences
- GitHub stars are inversely useful here: the 55k-star repo delivers the least verified capability, while the functional building blocks have 0.5k-10k stars.
- RuView's own README is now the strongest evidence against its headline claims; a builder should expect at most ESPectre-class motion/presence output from it, with far more setup complexity, and should distrust its vitals and pose outputs.
- ESP32-CSI-Tool and Wi-ESP are effectively superseded by Espressif's maintained esp-csi; use ESP32-CSI-Tool only if following an older paper's exact workflow.
- The GPLv3 + commercial dual licence on ESPectre matters only if the builder intends to ship a closed product.

### Gaps
- Exact last-commit dates were not exposed in the fetched GitHub pages; activity is inferred from commit counts, release registries and 2026 coverage.
- Could not read the Hackaday comments, the CNX Software article/comments, the Korben article or the HA forum RuView thread directly, so independent hands-on verdicts on RuView are second-hand.
- CSIKit's star count/last activity and Wi-ESP's repository status were not directly verified.
- TOMMY's licence boundaries (which parts are closed) and Pro pricing were not verified against its docs.

---

## 3. What signal-processing / ML pipeline is typical? Packet rates, node placement, nodes per room?

### Takeaway
Working DIY motion detectors use a small classical pipeline - amplitude per subcarrier, outlier rejection, a "turbulence"/variance statistic over a sliding window, automatic subcarrier selection and an adaptive threshold calibrated on a quiet room - running on the microcontroller at roughly 20-100 packets/s, with one sensor per room. CNN/LSTM/ViT models exist (SenseFi) but are trained on research-NIC datasets and do not transfer between rooms without retraining.

### Cited Findings
- ESPectre's core detector (MVS): compute "spatial turbulence" as the standard deviation of amplitudes across subcarriers per packet, then a sliding-window (moving) variance of that signal with an adaptive threshold. **[snippet; developer's description]** — [Hacker News comment by the ESPectre developer](https://news.ycombinator.com/item?id=45958166)
- ESPectre calibration: at boot an "NBVI" band calibration (~7.5 s, 10 x window_size packets) selects an optimal 12-subcarrier band and computes the adaptive threshold; the room must be still for ~10 s after boot. The changelog gives NBVI = 0.3 x (σ/μ²) + 0.7 x (σ/μ). **[snippet]** — [ESPectre tuning guide](https://espectre.dev/documentation/tuning/); [ESPectre changelog](https://espectre.dev/changelog/); [adafruit/espectre](https://github.com/adafruit/espectre)
- ESPectre packet rate: a built-in traffic generator pings the gateway; defaults cited range from 20 pps (developer on HN) to 100 pps (config table), and v3.0.0 renamed the parameter `traffic_generator_rate` -> `csi_target_pps`. Window size defaults cited as 50 packets (Seeed wiki) or 75 packets, range 10-200 (setup guide). Sources conflict by version. **[snippet]** — [HN](https://news.ycombinator.com/item?id=45958166); [adafruit/espectre SETUP.md](https://github.com/adafruit/espectre/blob/main/SETUP.md); [Seeed wiki](https://wiki.seeedstudio.com/xiao-esp32--series-espresense/); [ESPectre changelog](https://espectre.dev/changelog/)
- ESPectre also publishes an ML detector (weights in C++ and Python with a training/export/validation workflow) alongside the training-free path. — [francescopace/espectre](https://github.com/francescopace/espectre)
- Node count/placement: ESPectre - "One board covers one area, so plan on one board per room." TOMMY - each zone requires two devices. RuView maintainer - 3+ nodes for skeleton work, nodes at different heights 2-4 m apart. — [ESPectre README](https://raw.githubusercontent.com/francescopace/espectre/main/README.md); [HA forum: TOMMY v1.2.0](https://community.home-assistant.io/t/tommy-v1-2-0-now-with-stationary-presence-detection/974408) **[snippet]**; [RuView issue #299](https://github.com/ruvnet/RuView/issues/299)
- Espressif: the dedicated-transmitter topology (a packet sender on a fixed channel plus receivers) gives the highest accuracy and reliability; router-based topologies depend on router location and protocol; test/calibrate in an unoccupied environment. — [espressif/esp-csi](https://github.com/espressif/esp-csi)
- Espressif's `wifi_sensing_demo` uses on-site training (calibration in the deployment room) to set motion and presence thresholds. — [espressif/esp-csi](https://github.com/espressif/esp-csi)
- Hampel filter: flags outliers by median absolute deviation in a sliding window, applied per subcarrier amplitude series; commonly followed by a low-pass Butterworth filter. **[snippet]** — [arXiv 2507.12854](https://arxiv.org/pdf/2507.12854)
- Butterworth: used for denoising after subcarrier selection; band-pass Butterworth filters separate breathing and heartbeat bands for vital signs. **[snippet]** — [BeSense, arXiv 1907.06005](https://arxiv.org/pdf/1907.06005); [arXiv 1908.05108](https://arxiv.org/pdf/1908.05108)
- PCA: mitigates burst noise by exploiting correlation across subcarrier streams, and reduces e.g. 30 subcarrier streams to one component. **[snippet]** — [DeepWiTraffic, arXiv 1812.08208](https://arxiv.org/pdf/1812.08208)
- Subcarrier selection: choose the highest-variance subcarrier (most motion-sensitive) or score subcarriers by first-lag autocorrelation of power response. **[snippet]** — [arXiv 1907.06005](https://arxiv.org/pdf/1907.06005); [FuseFi, arXiv 2512.22143](https://arxiv.org/pdf/2512.22143)
- Phase sanitization: raw commodity phase is corrupted by carrier and sampling frequency offsets; the standard fix is a linear fit across subcarriers subtracted from the measured phase; a 2026 paper averages phase across subcarriers instead. **[snippet]** — [arXiv 2507.12854](https://arxiv.org/pdf/2507.12854); [arXiv 2606.07347](https://arxiv.org/pdf/2606.07347)
- Motion statistic in the literature: variance or squared temporal differences of CSI, integrated across subcarriers. **[snippet]** — [arXiv 2606.07347](https://arxiv.org/pdf/2606.07347)
- Deep models benchmarked by SenseFi (MLP, LeNet, ResNet, RNN/GRU/LSTM/BiLSTM, CNN+GRU, ViT) target activity recognition, gait ID and gestures on fixed datasets with 90-342 input channels (e.g. 3x114 for NTU-Fi), i.e. multi-antenna research hardware. — [xyanchen/WiFi-CSI-Sensing-Benchmark](https://github.com/xyanchen/WiFi-CSI-Sensing-Benchmark)
- RuView's vitals path is an FFT pipeline; the maintainer says breathing estimation requires the person to be still and heart rate requires a quiet environment. — [RuView issue #299](https://github.com/ruvnet/RuView/issues/299)

### Reference pipeline for a DIY motion/intrusion detector (synthesis of the above)
1. Traffic: fixed-rate packets (ping to gateway or dedicated sender), ~20-100 pps.
2. Extract amplitude per subcarrier; drop null/guard carriers.
3. Outlier rejection (Hampel) and optional low-pass.
4. Subcarrier selection on a quiet baseline (ESPectre's NBVI picks 12).
5. Motion statistic: cross-subcarrier std ("turbulence") -> moving variance over a 50-75 packet window (about 0.5-4 s depending on rate).
6. Adaptive threshold from the quiet-room baseline; hysteresis/debounce before publishing a binary sensor.
7. Optional: small on-device ML classifier; phase only if a multi-antenna/research NIC is used.

### Inferences
- Amplitude-only, variance-based detection dominates on ESP32 because single-antenna ESP32 phase is hard to sanitize; phase-based methods (breathing, localization) are where research NICs earn their cost.
- At 20-100 pps with a 50-75 packet window, detection latency is on the order of 1-4 s - fine for alarms and lighting-off timers, slower than PIR for lights-on.
- Because the threshold is calibrated on boot against a quiet room, reboots while people or pets are moving, or furniture/router changes, will degrade accuracy; a security build should trigger recalibration deliberately (e.g. when the house is armed/empty).
- For whole-home coverage plan one node per room/area (ESPectre guidance) - e.g. 4-6 nodes for a small house - placed so the router-to-node link crosses the space to be monitored.
- CNN/LSTM approaches are a poor fit for a first prototype: they need labelled per-environment data and the public datasets were collected on Intel/Atheros-class NICs, not ESP32.

### Gaps
- No source retrieved gives a recommended node-to-router distance (a blog cites "3-8 m" for best ESPectre results, unverified), nor minimum packet rate for reliable detection.
- ESPectre's own published performance report (recall/precision/F1 per chip) could not be fetched (docs paths returned 404); a third-party blog cites "96%+ F1 under optimal conditions" and the developer's write-up cites 100% precision in his own tests - both self-reported. — [brightcoding blog](https://www.blog.brightcoding.dev/2026/04/18/espectre-the-revolutionary-wi-fi-motion-sensor-every-smart-home-needs); [IoT For All](https://www.iotforall.com/wifi-motion-sensor-iot) **[snippet]**
- esp-radar's internal algorithm (wander/jitter metrics) and its threshold semantics were not confirmed from Espressif docs this session.
- No independent measurement of how well mesh Wi-Fi / band steering / router channel changes affect these pipelines.

---

## 4. Home Assistant / MQTT / ESPHome integration and real-world builder results

### Takeaway
Integration is a solved problem - ESPectre exposes a motion binary sensor, a movement score and a tunable threshold through ESPHome, MQTT Discovery or Matter - but real-world evidence is thin and mostly self-reported: builders describe motion (not stillness) detection that can reach adjacent rooms, with fans, AC, curtains and pets acknowledged as false-positive sources.

### Cited Findings
- ESPectre in Home Assistant: each sensor is auto-discovered and exposes a binary sensor for motion, a movement score sensor and an adjustable threshold number entity. **[snippet]** — [HA forum: ESPectre thread](https://community.home-assistant.io/t/espectre-wi-fi-motion-detection-for-home-assistant/961251); [ESPHome ESPectre component](https://esphome.io/components/espectre/)
- ESPectre integration routes: ESPHome, MQTT with MQTT Discovery, or as a standard Matter occupancy sensor (tested with Google Home, Apple Home, Home Assistant); browser-based flashing and monitoring tools (desktop Chrome). — [ESPectre README](https://raw.githubusercontent.com/francescopace/espectre/main/README.md)
- Setup gotchas reported: keep the room still for 10 s after boot for self-calibration; a forum post says 64-bit Home Assistant OS and ESPectre 3.0 firmware are needed; Seeed's guide recommends Python 3.12 because Python 3.14 has known ESPHome issues. **[snippet]** — [HA forum: ESPectre thread](https://community.home-assistant.io/t/espectre-wi-fi-motion-detection-for-home-assistant/961251); [Seeed wiki](https://wiki.seeedstudio.com/xiao-esp32--series-espresense/)
- Stationary people: ESPectre "detects movement, not presence. If you sit perfectly still, it will eventually report 'no motion' (like a PIR sensor would)." **[snippet]** — [HA forum: ESPectre thread](https://community.home-assistant.io/t/espectre-wi-fi-motion-detection-for-home-assistant/961251)
- The official README says ESPectre cannot "prove that a room is empty" and does not replace a safety-certified security system. — [francescopace/espectre](https://github.com/francescopace/espectre)
- False positives: ESPectre's tuning guide lists fans, AC units and moving curtains as interference sources and pets moving in the room as a cause; fixes are a higher threshold, a larger window and enabling the Hampel filter; the auto threshold defaults to minimizing false positives. **[snippet]** — [ESPectre tuning guide](https://espectre.dev/documentation/tuning/)
- A blog claim that the adaptive threshold can be configured to ignore pets under 15 kg is not supported by the official docs found. **[snippet]** — [brightcoding blog](https://www.blog.brightcoding.dev/2026/04/18/espectre-the-revolutionary-wi-fi-motion-sensor-every-smart-home-needs)
- Through-wall: the ESPectre developer's write-up says a single ESP32 in the living room can detect movement in adjacent rooms; TOMMY markets "through-wall motion sensors" and warns a zone "may also detect presence outside the intended zone". **[snippet]** — [IoT For All](https://www.iotforall.com/wifi-motion-sensor-iot); [tommysense.com](https://tommysense.com/)
- TOMMY added stationary presence detection in v1.2.0 (2-device zones). **[snippet]** — [HA forum: TOMMY v1.2.0](https://community.home-assistant.io/t/tommy-v1-2-0-now-with-stationary-presence-detection/974408)
- A hobbyist esp-csi build reported about 80% accuracy relative to the builder's commercial 24 GHz mmWave radar, and noted that CSI sensing needs the Wi-Fi radio fully active, sending packets hundreds of times per second. **[snippet]** — [Hackster: ESP-CSI DIY WiFi human presence detection](https://www.hackster.io/limengdu0117/esp-csi-diy-wifi-human-presence-detection-f80508)
- Academic context: a multiband passive-sensing paper reports CSI-variation presence detection as highly reliable indoors with ~10-15 m range, and rates Wi-Fi vital-sign tracking as insufficient. **[snippet]** — [arXiv 2507.22591](https://arxiv.org/html/2507.22591v2)
- 2.4 GHz CSI motion detection suffers from 20 MHz bandwidth limits, interference and congestion. **[snippet]** — [USPTO patent 11894902](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11894902)
- RuView offers HA via an MQTT publisher (`--mqtt`), 21 entities per node and 3 blueprints, but with an open report of "present" on 99.6% of an empty room. — [RuView README](https://raw.githubusercontent.com/ruvnet/RuView/main/README.md); [RuView issues](https://github.com/ruvnet/wifi-densepose/issues) **[snippet]**

### Recommended architectures (synthesis)
- **A. Easiest (weekend prototype):** 1 x ESP32-C6 per room flashed with ESPectre via ESPHome -> Home Assistant binary_sensor -> automation (notify/siren when alarm is armed). Existing 2.4 GHz router is the transmitter. Cost roughly one dev board plus a USB supply per room.
- **B. More robust:** add a dedicated always-on transmitter (spare ESP32 or fixed-channel AP) so links do not depend on the main router's location/channel (Espressif's highest-reliability topology); external antennas on receivers; MQTT to HA.
- **C. Custom/learning build:** esp-csi `csi_recv_router` or esp-radar `wifi_sensing_demo` -> serial/UDP/MQTT -> Python (CSIKit for parsing) -> own variance/threshold or small classifier -> MQTT Discovery to HA.
- **D. Research rig (not for deployment):** Intel AX210 + FeitCSI/PicoScenes on a Linux PC, or Pi 4/5 + nexmon_csi, for 80-160 MHz data and SenseFi-style models.
- **For actual security use:** fuse CSI motion with a door contact or PIR/mmWave before sounding an alarm (two-sensor confirmation), and only arm CSI zones when the home is empty of people and pets.

### Inferences
- The through-wall sensitivity that makes CSI attractive for whole-home intrusion detection is the same property that causes bleed between rooms and false alarms from neighbours' or adjacent-room movement; zone boundaries are soft.
- CSI motion sensing is most defensible as an "armed-away, house should be empty" tripwire, where any motion is meaningful and stationary-person blindness does not matter - provided there are no pets, fans or robot vacuums running.
- Every sensing node keeps its radio busy pinging at 20-100 pps, so nodes must be mains-powered, and a multi-node deployment adds constant low-rate traffic to the 2.4 GHz network.

### Gaps
- Could not read the Home Assistant forum threads (ESPectre, TOMMY, "mmWave vs. Wi-Fi Sensing", "Wi-Fi sensing in Home Assistant"), Hackaday comments or Reddit, so long-term user reports (weeks of false-alarm rates, pet behaviour, mesh-router issues) are missing. community.home-assistant.io and hackaday.com would need to be allowed in the session network settings.
- No independent, quantified through-wall range or false-alarm-rate measurements for ESPectre/TOMMY were found; published numbers are self-reported by developers.
- No data on battery operation or on how many CSI nodes a typical home router tolerates.

---

## 5. Cost and reliability vs. PIR and 24/60 GHz mmWave (LD2410, LD2450) - when is WiFi sensing the better choice?

### Takeaway
On a per-room basis WiFi CSI is not cheaper or more reliable than the incumbents: an LD2410C is ~$3-4.50 and detects a motionless, breathing person, which ESP32 CSI motion detection generally cannot. CSI sensing wins only where its unique properties matter - no line of sight, coverage through walls/furniture, hidden or software-only deployment on ESP32s already installed, and no camera/privacy concerns.

### Cited Findings
- LD2410C-P pricing: LCSC reference price from about $3.12 at volume, ~$4.41 single unit. **[snippet]** — [LCSC HLK-LD2410C-P](https://www.lcsc.com/product-detail/C19723500.html)
- LD2450 (multi-target tracking radar): $6-10 on AliExpress per a July 2026 guide. **[snippet]** — [atomic14 Hi-Link radar decoder](https://www.atomic14.com/esp32/sensors/hlk-radar-decoder/)
- LD2410 is a 24 GHz radar that can detect still presence (e.g. someone breathing in a chair); the LD2410C is the typical low-cost starting point for room-level static presence; it reports one target and has 8 range gates (LD2420 has 20). **[snippet]** — [openelab: 24 GHz vs 60 GHz mmWave](https://openelab.io/blogs/learn/24ghz-vs-60ghz-mmwave-presence-sensors); [atomic14 HLK-LD2410](https://www.atomic14.com/esp32/sensors/hlk-ld2410/)
- "PIR sensors are designed to detect motion, but mmWave sensors are capable of detecting presence", including minimal movements such as breathing. **[snippet]** — [Yahoo Tech](https://tech.yahoo.com/home/articles/9-reasons-mmwave-sensors-smart-143016676.html)
- mmWave is not false-positive-free: an HA builder combining LD2410 + PIR cited false positives from micro-vibrations near the sensor and recommended using both sensors together; an LD2410 tuning guide notes a moving cat or dog generates real radar energy. **[snippet]** — [HA forum: low-latency mmWave + PIR](https://community.home-assistant.io/t/low-latency-presence-sensor-mmwave-pir-using-esphome/407553?page=5); [esp32.co.uk LD2410 tuning](https://esp32.co.uk/ld2410-tuning-false-presence-esphome-sensitivity-guide/)
- An HA forum comparison argues Wi-Fi sensing has the edge on range, price and ease of deployment (software-only add-on to existing Wi-Fi devices), while mmWave offers the best zoning. **[snippet; one poster's opinion]** — [HA forum: mmWave vs. Wi-Fi Sensing](https://community.home-assistant.io/t/mmwave-vs-wi-fi-sensing/1010785)
- ESPectre behaves like a PIR for still people: it "will eventually report 'no motion'". **[snippet]** — [HA forum: ESPectre thread](https://community.home-assistant.io/t/espectre-wi-fi-motion-detection-for-home-assistant/961251)
- A hobbyist CSI build achieved ~80% agreement with a commercial 24 GHz radar and needed the radio transmitting hundreds of packets per second. **[snippet]** — [Hackster](https://www.hackster.io/limengdu0117/esp-csi-diy-wifi-human-presence-detection-f80508)
- CSI presence detection range is cited as ~10-15 m indoors in academic work. **[snippet]** — [arXiv 2507.22591](https://arxiv.org/html/2507.22591v2)
- ESPectre needs "no camera, no microphone, no wearable, and no dedicated radar hardware." — [francescopace/espectre](https://github.com/francescopace/espectre)

### Comparison (compiled; cells without a citation above are inferences)

| | PIR | 24 GHz mmWave (LD2410C / LD2450) | ESP32 WiFi CSI (ESPectre-class) |
|---|---|---|---|
| Sensor cost | lowest | ~$3-4.50 / $6-10, plus an ESP32 host | one ESP32 board (~$5-15), no extra sensor |
| Still person | No | Yes (breathing-level) | Generally no (motion only); TOMMY claims yes |
| Line of sight | Required | Required (limited penetration) | Not required; sees through walls |
| Zoning | Sharp cone | Best (range gates / x-y targets) | Soft, bleeds across rooms |
| False positives | heat/sun/pets | micro-vibration, fans, pets | fans, AC, curtains, pets, RF changes |
| Power | battery-capable | mains | mains, radio always active |
| Maturity for alarms | decades | high in HA community | hobbyist; explicitly not safety-certified |

### Inferences
- WiFi sensing is the better choice when: (1) a whole-floor "anything moving while we're away" tripwire is wanted with few devices and no line of sight; (2) sensors must be hidden (inside cabinets, behind drywall) or the space has obstructions that defeat PIR/radar; (3) ESP32 devices are already deployed and can be reflashed/extended at zero hardware cost; (4) privacy rules out cameras; (5) the builder wants to learn RF sensing.
- It is the worse choice when: stationary occupancy matters (use LD2410), precise room/zone attribution matters (LD2450 or PIR), the home has pets/fans active while armed, battery power is required (PIR), or the outcome is safety-critical.
- Best practical design is hybrid: PIR/contact sensors at entry points, mmWave for occupied-room presence, CSI as a cheap extra whole-home layer whose alarms require confirmation from a second sensor.
- The "price edge" claimed for Wi-Fi sensing only holds if existing devices are reused; a new ESP32 + LD2410C costs only a few dollars more than a bare ESP32 and adds true static presence.

### Gaps
- No controlled head-to-head benchmark (CSI vs LD2410 vs PIR, same room, measured false-alarm and miss rates) was found; all comparisons are anecdotal or vendor/blog level.
- PIR unit prices and 60 GHz module prices were not sourced this session.
- No evidence found on long-term drift of CSI thresholds (seasonal, furniture changes) versus mmWave.
- TOMMY's stationary-detection reliability is unverified beyond its release announcement.
