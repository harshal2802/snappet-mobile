import XCTest
import SwiftData
@testable import Snappet

/// What each heart-rate surface gave for a fixed set of clips BEFORE prompt 309 moved them all onto
/// `ClipHeartRate` (the one resolver). The expected values were recorded from the code as it was on
/// `studio-v2` at `009e59ca` and are compared as exact strings (a `Double` prints its shortest
/// exact form), so "unchanged" means bit for bit.
///
/// A value that prompt 309 changed on purpose is listed in `changedBy309`, with the value it had
/// before; `decisions.md` (2026-11-26) says why. Everything else is as it was recorded: every
/// feed, share, `StudioHRPlacement` and Studio view-model record is unchanged.
final class ClipHRCharacterizationTests: XCTestCase {

    // MARK: Fixtures

    struct Case {
        var name: String
        var series: [HRPoint]
        var offsetSec: Double
        var durationSec: Double
        var timeMap: BakedTimeMap? = nil
        var edit: ClipStudioEdit? = nil
        var maxHR: Double = 190
        var restHR: Double? = 60

        var media: MediaInput {
            MediaInput(id: UUID(uuidString: "00000000-0000-0000-0000-000000000309")!, kind: "video",
                       offsetSec: offsetSec, durationSec: durationSec, exerciseId: nil, setIndex: nil,
                       climbUUID: nil, localIdentifier: name, edit: edit, timeMap: timeMap)
        }

        var activity: ActivityMediaInput {
            ActivityMediaInput(id: UUID(uuidString: "00000000-0000-0000-0000-000000000309")!,
                               sessionID: UUID(uuidString: "00000000-0000-0000-0000-00000000A309")!,
                               assignedExerciseID: nil, assignedSetIndex: nil, kindRaw: "video",
                               offsetSec: offsetSec, durationSec: durationSec, localIdentifier: name,
                               timeMap: timeMap)
        }

        /// The clip as the Studio has it on its timeline, with the same trim and HR window.
        var timelineClip: TimelineClip {
            var clip = TimelineClip(id: UUID(uuidString: "00000000-0000-0000-0000-0000000C0309")!,
                                    sessionMediaID: nil, localIdentifier: name, isPhoto: false, order: 0,
                                    trimStart: edit?.trimStart ?? 0, trimEnd: edit?.trimEnd)
            if let edit {
                clip.hrLeadSec = edit.hrLeadSec
                clip.hrTailSec = edit.hrTailSec
                clip.hrMetricsScope = edit.hrMetricsScope
            }
            return clip
        }
    }

    static let ramp = StudioHRTimingSeed.rampSeries()
    static let golden = StudioGoldenScene.heartRate
    static let sparse: [HRPoint] = [HRPoint(t: 0, bpm: 100), HRPoint(t: 48, bpm: 118), HRPoint(t: 61, bpm: 151),
                                    HRPoint(t: 75, bpm: 140), HRPoint(t: 110, bpm: 122), HRPoint(t: 200, bpm: 96)]

    static func timeMap(trimStart: Double = 0, recorded: Double, speed: Double = 1) -> BakedTimeMap? {
        let part = TimelineClip(sessionMediaID: nil, localIdentifier: "x", isPhoto: false, order: 0,
                                trimStart: trimStart, trimEnd: recorded, speed: speed)
        return ClipBakePlan.timeMap(parts: [part], sourceDurations: [part.id: recorded], transitions: [],
                                    existing: nil)
    }

    static let cases: [Case] = [
        Case(name: "unbaked", series: ramp, offsetSec: 60, durationSec: 10),
        Case(name: "bakedStartTrim", series: ramp, offsetSec: 200, durationSec: 10,
             timeMap: timeMap(trimStart: 20, recorded: 30)),
        Case(name: "baked2x", series: ramp, offsetSec: 120, durationSec: 10,
             timeMap: timeMap(recorded: 20, speed: 2)),
        Case(name: "sparse", series: sparse, offsetSec: 55, durationSec: 12),
        Case(name: "noneNearby", series: ramp, offsetSec: 600, durationSec: 10),
        Case(name: "edgeHold", series: ramp, offsetSec: 320, durationSec: 10),
        Case(name: "leadClamped", series: ramp, offsetSec: 2, durationSec: 5),
        Case(name: "goldenDefault", series: golden, offsetSec: 8.3, durationSec: 7.4, maxHR: 185, restHR: nil),
        Case(name: "goldenTrimmedClipScope", series: golden, offsetSec: 8.3, durationSec: 7.4,
             edit: ClipStudioEdit(trimStart: 1.2, trimEnd: 6.1, hrLeadSec: 3, hrTailSec: 4, hrMetricsScope: .clip),
             maxHR: 185, restHR: 52),
        Case(name: "unbakedNoLeadNoTail", series: ramp, offsetSec: 60, durationSec: 10,
             edit: ClipStudioEdit(hrLeadSec: 0, hrTailSec: 0)),
    ]

    // MARK: Digests

    static func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    static func digest(_ samples: [HRPoint]) -> String {
        guard let first = samples.first, let last = samples.last else { return "none" }
        let all = samples.map { "\($0.t):\($0.bpm)" }.joined(separator: ",")
        return "n\(samples.count) \(first.t):\(first.bpm)..\(last.t):\(last.bpm) #\(hash(all))"
    }

    static func digest(_ window: HRClipWindow?) -> String {
        window.map { "\($0.leadSec)/\($0.footageSec)/\($0.tailSec)" } ?? "nowindow"
    }

    static let fractions: [Double] = [0, 0.1, 0.25, 0.5, 0.75, 1]

    static func digest(_ values: HROverlayValues) -> String {
        let live = fractions.map { f -> String in
            let chart = values.chartFraction(forVideoFraction: f)
            let bpm = values.bpm(atFraction: chart).map { "\($0)" } ?? "nil"
            let text = values.live(.bpm, atFraction: chart, fallbackHex: "#FFFFFF")
            return "\(bpm)[\(text?.text ?? "nil") \(text?.hex ?? "")]"
        }.joined(separator: ";")
        let stat = [HROverlayMetric.avgHR, .maxHR, .zone, .hrr, .redline, .strain, .timeToPeak, .hrRise, .calories, .hrv]
            .map { values.staticValue($0, fallbackHex: "#FFFFFF")?.text ?? "nil" }.joined(separator: ";")
        return "w=\(digest(values.window)) s=\(digest(values.samples)) dur=\(values.durationSec) "
            + "sparse=\(values.isSparseChart) max=\(values.resolvedMaxHR) live=\(live) stat=\(stat)"
    }

    static func digest(_ tile: ResolvedHRTile?) -> String {
        tile.map { "tile#\(hash(String(describing: $0)))" } ?? "notile"
    }

    // MARK: Each surface

    static func feed(_ c: Case) -> String {
        guard let payload = ClipHROverlay.make(clip: c.media, hrSeries: c.series, maxHR: c.maxHR, restHR: c.restHR)
        else { return "nil" }
        return digest(payload.values) + " " + digest(payload.values.resolveTile(payload.tile))
            + " atEnd=\(ClipHROverlay.atEnd(for: payload))"
    }

    static func share(_ c: Case) -> String {
        let payload = ClipHROverlay.make(clip: c.media, hrSeries: c.series, maxHR: c.maxHR, restHR: c.restHR)
        guard let plan = ClipSharePlan.plan(clip: c.media, payload: payload, title: nil) else { return "nil" }
        return "start=\(plan.start) dur=\(plan.duration) slot=\(plan.hr.startSec)+\(plan.hr.durationSec) "
            + "s=\(digest(plan.hr.samples)) \(digest(plan.hr.tile))"
    }

    static func studio(_ c: Case) -> String {
        let clip = c.timelineClip
        let ext = StudioHRPlacement.extendedWindow(offset: c.offsetSec, trimStart: clip.trimStart,
                                                   trimEnd: clip.trimEnd, sourceDuration: c.durationSec,
                                                   leadSec: clip.hrWindowLeadSec, tailSec: clip.hrWindowTailSec,
                                                   timeMap: c.timeMap)
        let sampled = StudioHRPlacement.sampleExtended(
            clips: [clip], offsets: [clip.id: c.offsetSec], sourceDurations: [clip.id: c.durationSec],
            series: c.series, timeMaps: c.timeMap.map { [clip.id: $0] } ?? [:])
        let plain = StudioHRPlacement.sample(
            clips: [clip], offsets: [clip.id: c.offsetSec], sourceDurations: [clip.id: c.durationSec],
            series: c.series, timeMaps: c.timeMap.map { [clip.id: $0] } ?? [:])
        return "start=\(ext.start) w=\(digest(ext.window)) ext=\(digest(sampled[clip.id]?.samples ?? [])) "
            + "sw=\(digest(sampled[clip.id]?.window)) plain=\(digest(plain[clip.id] ?? []))"
    }

    static func chip(_ c: Case) -> String {
        let hr = FeedMedia.clipHR(for: c.media, hrSeries: c.series, maxHR: c.maxHR)
        return "peak=\(hr.peakBpm.map(String.init) ?? "nil") avg=\(hr.avgBpm.map(String.init) ?? "nil") "
            + "zone=\(hr.zoneRaw.map(String.init) ?? "nil")"
    }

    static func activity(_ c: Case) -> String {
        ActivityMediaIndex.averageBPM(for: c.activity, hrSeries: c.series).map(String.init) ?? "nil"
    }

    /// Photos have their own windows on the two surfaces that show a number for one.
    static func photo(offsetSec: Double, series: [HRPoint]) -> String {
        let input = ActivityMediaInput(id: UUID(), sessionID: UUID(), assignedExerciseID: nil,
                                       assignedSetIndex: nil, kindRaw: "photo", offsetSec: offsetSec,
                                       durationSec: nil, localIdentifier: "P")
        let hr = FeedMedia.clipHR(for: input.mediaInput, hrSeries: series, maxHR: 190)
        return "chip=\(hr.peakBpm.map(String.init) ?? "nil")/\(hr.avgBpm.map(String.init) ?? "nil") "
            + "activity=\(ActivityMediaIndex.averageBPM(for: input, hrSeries: series).map(String.init) ?? "nil")"
    }

    // MARK: The record

    static var actual: [String: String] {
        var out: [String: String] = [:]
        for c in cases {
            out["feed.\(c.name)"] = feed(c)
            out["share.\(c.name)"] = share(c)
            out["studio.\(c.name)"] = studio(c)
            out["chip.\(c.name)"] = chip(c)
            out["activity.\(c.name)"] = activity(c)
        }
        out["photo.ramp60"] = photo(offsetSec: 60, series: ramp)
        out["photo.sparse55"] = photo(offsetSec: 55, series: sparse)
        return out
    }

    func testEverySurfaceGivesWhatItGaveBeforeTheResolver() {
        let actual = Self.actual
        for key in actual.keys.sorted() {
            let value = actual[key] ?? ""
            guard let expected = Self.recorded[key] else {
                print("CHAR|\(key)|\(value)")
                XCTFail("no recorded value for \(key)")
                continue
            }
            XCTAssertEqual(value, expected, key)
        }
        XCTAssertEqual(Set(actual.keys), Set(Self.recorded.keys.filter { !$0.hasPrefix("studioVM.") }))
    }

    /// The running Studio: the preview tile at six playhead times, the HR-window sliders' numbers
    /// and the tile the export burns.
    @MainActor
    static func studioViewModel(_ c: Case) async throws -> String {
        let h = try await ClipHRStudioHarness.make(
            series: c.series, offsetSec: c.offsetSec, durationSec: c.durationSec, timeMap: c.timeMap,
            trimStart: c.edit?.trimStart ?? 0, trimEnd: c.edit?.trimEnd,
            leadSec: c.edit?.hrLeadSec, tailSec: c.edit?.hrTailSec, scope: c.edit?.hrMetricsScope,
            maxHR: c.maxHR, restHR: c.restHR)
        defer { withExtendedLifetime(h.container) {} }
        let total = h.vm.totalDuration
        let live = fractions.map { f -> String in
            h.preview(at: f * total).bpm.map { "\($0)" } ?? "nil"
        }.joined(separator: ";")
        let values = h.preview(at: 0).values
        let info = h.vm.hrWindowInfo
        let sliders = info.map {
            "\($0.lead)/\($0.tail) eff=\($0.effectiveLead)/\($0.effectiveTail) f=\($0.footageSec)"
        } ?? "nil"
        let placed = h.exported()
        let export = placed.map {
            "slot=\($0.startSec)+\($0.durationSec) s=\(digest($0.samples)) \(digest($0.tile))"
        } ?? "nil"
        return "total=\(total) live=\(live) \(digest(values)) sliders=\(sliders) export=\(export)"
    }

    @MainActor
    func testTheRunningStudioGivesWhatItGaveBeforeTheResolver() async throws {
        for c in Self.cases {
            let key = "studioVM.\(c.name)"
            let value = try await Self.studioViewModel(c)
            guard let expected = Self.recorded[key] else {
                print("CHAR|\(key)|\(value)")
                XCTFail("no recorded value for \(key)")
                continue
            }
            XCTAssertEqual(value, expected, key)
        }
    }

    /// What prompt 309 changed on purpose, with the value BEFORE it (`recorded` holds the value
    /// now). The poster chip and the activity average show the overlay's PEAK and AVG (the clip's
    /// own HR window, its trim and its scope); a photo is read 10 s either side of its moment.
    /// No feed, share or Studio record is in this list.
    static let changedBy309: [String: String] = [
        "activity.baked2x": "125",
        "activity.bakedStartTrim": "173",
        "activity.edgeHold": "nil",
        "activity.goldenDefault": "151",
        "activity.goldenTrimmedClipScope": "151",
        "activity.leadClamped": "62",
        "activity.sparse": "151",
        "activity.unbaked": "93",
        "activity.unbakedNoLeadNoTail": "93",
        "chip.baked2x": "peak=130 avg=125 zone=2",
        "chip.bakedStartTrim": "peak=175 avg=173 zone=5",
        "chip.goldenDefault": "peak=162 avg=151 zone=4",
        "chip.goldenTrimmedClipScope": "peak=162 avg=151 zone=4",
        "chip.leadClamped": "peak=64 avg=62 zone=1",
        "chip.sparse": "peak=151 avg=144 zone=3",
        "chip.unbaked": "peak=95 avg=93 zone=1",
        "photo.ramp60": "chip=93/92 activity=90",
        "photo.sparse55": "chip=151/143 activity=135",
    ]

    func testOnlyTheChipTheActivityAverageAndPhotosChanged() {
        for (key, before) in Self.changedBy309 {
            XCTAssertTrue(key.hasPrefix("chip.") || key.hasPrefix("activity.") || key.hasPrefix("photo."), key)
            XCTAssertNotEqual(Self.recorded[key], before, key)
        }
        // The chip and the activity average are the feed's PEAK and AVG for the same clip.
        for c in Self.cases {
            let payload = ClipHROverlay.make(clip: c.media, hrSeries: c.series, maxHR: c.maxHR, restHR: c.restHR)
            let chip = FeedMedia.clipHR(for: c.media, hrSeries: c.series, maxHR: c.maxHR)
            XCTAssertEqual(chip.peakBpm.map(String.init),
                           payload?.values.staticValue(.maxHR, fallbackHex: "")?.value, c.name)
            XCTAssertEqual(chip.avgBpm.map(String.init),
                           payload?.values.staticValue(.avgHR, fallbackHex: "")?.value, c.name)
        }
    }

    static let recorded: [String: String] = [
        "activity.baked2x":
            "131",
        "activity.bakedStartTrim":
            "179",
        "activity.edgeHold":
            "210",
        "activity.goldenDefault":
            "145",
        "activity.goldenTrimmedClipScope":
            "145",
        "activity.leadClamped":
            "69",
        "activity.noneNearby":
            "nil",
        "activity.sparse":
            "136",
        "activity.unbaked":
            "99",
        "activity.unbakedNoLeadNoTail":
            "99",
        "chip.baked2x":
            "peak=145 avg=131 zone=3",
        "chip.bakedStartTrim":
            "peak=190 avg=179 zone=5",
        "chip.edgeHold":
            "peak=210 avg=210 zone=5",
        "chip.goldenDefault":
            "peak=172 avg=145 zone=5",
        "chip.goldenTrimmedClipScope":
            "peak=159 avg=151 zone=4",
        "chip.leadClamped":
            "peak=79 avg=69 zone=1",
        "chip.noneNearby":
            "peak=nil avg=nil zone=nil",
        "chip.sparse":
            "peak=151 avg=136 zone=3",
        "chip.unbaked":
            "peak=110 avg=99 zone=1",
        "chip.unbakedNoLeadNoTail":
            "peak=95 avg=93 zone=1",
        "feed.baked2x":
            "w=5.0/20.0/30.0 s=n56 0.0:117.5..55.0:145.0 #81658379fc627238 dur=55.0 sparse=false max=190.0 live=120.0[120 bpm #30B0C7];121.0[121 bpm #30B0C7];122.5[123 bpm #30B0C7];125.0[125 bpm #30B0C7];127.5[128 bpm #30B0C7];130.0[130 bpm #30B0C7] stat=131 avg bpm;145 max bpm;Z2 · Easy;65% peak;0% redline;Strain 2;54s to peak;+26 bpm rise;nil;nil tile#19f442d805b97ae2 atEnd=0.45454545454545453",
        "feed.bakedStartTrim":
            "w=5.0/10.0/30.0 s=n46 0.0:167.5..45.0:190.0 #317b25bb1e33056f dur=45.0 sparse=false max=190.0 live=170.0[170 bpm #FF9500];170.5[171 bpm #FF9500];171.25[171 bpm #FF3B30];172.5[173 bpm #FF3B30];173.75[174 bpm #FF3B30];175.0[175 bpm #FF3B30] stat=179 avg bpm;190 max bpm;Z5 · Max;100% peak;100% redline;Strain 4;44s to peak;+21 bpm rise;nil;nil tile#e99519f82bfcf008 atEnd=0.3333333333333333",
        "feed.edgeHold":
            "w=5.0/10.0/30.0 s=n2 0.0:210.0..45.0:210.0 #23f69d8b8af20d48 dur=45.0 sparse=true max=190.0 live=210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30] stat=210 avg bpm;210 max bpm;Z5 · Max;100% peak;100% redline;Strain 4;nil;nil;nil;nil tile#749ae8de9d5a2026 atEnd=0.3333333333333333",
        "feed.goldenDefault":
            "w=5.0/7.4/30.0 s=n38 0.0:106.5..35.7:112.0 #7bc7f2b7fbe5e766 dur=35.7 sparse=false max=185.0 live=135.16649859943976[135 bpm #34C759];138.9909019607843[139 bpm #34C759];144.1760784313726[144 bpm #34C759];151.50638655462186[152 bpm #FF9500];157.37268907563035[157 bpm #FF9500];162.17361344537812[162 bpm #FF9500] stat=145 avg bpm;172 max bpm;Z3 · Aerobic;nil;56% redline;Strain 2;19s to peak;+59 bpm rise;nil;nil tile#ef5091b84289f4d2 atEnd=0.3473389355742297",
        "feed.goldenTrimmedClipScope":
            "w=3.0/4.8999999999999995/4.0 s=n14 0.0:125.0..11.899999999999999:167.8 #2dfacc64cf55402c dur=11.899999999999999 sparse=false max=185.0 live=141.51596638655462[142 bpm #34C759];143.78504201680673[144 bpm #34C759];146.99411764705883[147 bpm #34C759];151.6848739495798[152 bpm #FF9500];155.69327731092437[156 bpm #FF9500];159.30588235294118[159 bpm #FF9500] stat=151 avg bpm;159 max bpm;Z4 · Threshold;81% peak;69% redline;Strain 0;4s to peak;+8 bpm rise;nil;nil tile#8b6c373ac1bc8c97 atEnd=0.6638655462184875",
        "feed.leadClamped":
            "w=2.0/5.0/30.0 s=n38 0.0:60.0..37.0:78.5 #2c6393d0e9a168ad dur=37.0 sparse=false max=190.0 live=61.0[61 bpm #007AFF];61.25[61 bpm #007AFF];61.625[62 bpm #007AFF];62.25[62 bpm #007AFF];62.875[63 bpm #007AFF];63.5[64 bpm #007AFF] stat=69 avg bpm;79 max bpm;Z1 · Recovery;14% peak;0% redline;Strain 1;36s to peak;+17 bpm rise;nil;nil tile#382593c083517f62 atEnd=0.1891891891891892",
        "feed.noneNearby":
            "nil",
        "feed.sparse":
            "w=5.0/12.0/30.0 s=n4 0.0:123.07692307692308..47.0:128.68571428571428 #452e5e6699e2fe4c dur=47.0 sparse=true max=190.0 live=135.76923076923077[136 bpm #34C759];138.8153846153846[139 bpm #34C759];143.3846153846154[143 bpm #34C759];150.0027472527472[150 bpm #34C759];148.64285714285725[149 bpm #34C759];146.2857142857143[146 bpm #34C759] stat=136 avg bpm;151 max bpm;Z3 · Aerobic;70% peak;0% redline;Strain 2;nil;nil;nil;nil tile#5e3bbaea358f8d47 atEnd=0.3617021276595745",
        "feed.unbaked":
            "w=5.0/10.0/30.0 s=n46 0.0:87.5..45.0:110.0 #c9c95c087bfcaf96 dur=45.0 sparse=false max=190.0 live=90.0[90 bpm #007AFF];90.5[91 bpm #007AFF];91.25[91 bpm #007AFF];92.5[93 bpm #007AFF];93.75[94 bpm #007AFF];95.0[95 bpm #007AFF] stat=99 avg bpm;110 max bpm;Z1 · Recovery;38% peak;0% redline;Strain 1;44s to peak;+21 bpm rise;nil;nil tile#18d080181ce77594 atEnd=0.3333333333333333",
        "feed.unbakedNoLeadNoTail":
            "w=0.0/10.0/0.0 s=n11 0.0:90.0..10.0:95.0 #31db7181a3380714 dur=10.0 sparse=false max=190.0 live=90.25[90 bpm #007AFF];90.5[91 bpm #007AFF];91.25[91 bpm #007AFF];92.5[93 bpm #007AFF];93.75[94 bpm #007AFF];94.5[95 bpm #007AFF] stat=93 avg bpm;95 max bpm;Z1 · Recovery;27% peak;0% redline;Strain 0;9s to peak;+4 bpm rise;nil;nil tile#b059f1401bf57951 atEnd=1.0",
        "photo.ramp60":
            "chip=95/90 activity=90",
        "photo.sparse55":
            "chip=151/133 activity=133",
        "share.baked2x":
            "start=0.0 dur=10.0 slot=0.0+10.0 s=n56 0.0:117.5..55.0:145.0 #81658379fc627238 tile#19f442d805b97ae2",
        "share.bakedStartTrim":
            "start=0.0 dur=10.0 slot=0.0+10.0 s=n46 0.0:167.5..45.0:190.0 #317b25bb1e33056f tile#e99519f82bfcf008",
        "share.edgeHold":
            "start=0.0 dur=10.0 slot=0.0+10.0 s=n2 0.0:210.0..45.0:210.0 #23f69d8b8af20d48 tile#749ae8de9d5a2026",
        "share.goldenDefault":
            "start=0.0 dur=7.4 slot=0.0+7.4 s=n38 0.0:106.5..35.7:112.0 #7bc7f2b7fbe5e766 tile#ef5091b84289f4d2",
        "share.goldenTrimmedClipScope":
            "start=1.2 dur=4.8999999999999995 slot=0.0+4.8999999999999995 s=n14 0.0:125.0..11.899999999999999:167.8 #2dfacc64cf55402c tile#8b6c373ac1bc8c97",
        "share.leadClamped":
            "start=0.0 dur=5.0 slot=0.0+5.0 s=n38 0.0:60.0..37.0:78.5 #2c6393d0e9a168ad tile#382593c083517f62",
        "share.noneNearby":
            "nil",
        "share.sparse":
            "start=0.0 dur=12.0 slot=0.0+12.0 s=n4 0.0:123.07692307692308..47.0:128.68571428571428 #452e5e6699e2fe4c tile#5e3bbaea358f8d47",
        "share.unbaked":
            "start=0.0 dur=10.0 slot=0.0+10.0 s=n46 0.0:87.5..45.0:110.0 #c9c95c087bfcaf96 tile#18d080181ce77594",
        "share.unbakedNoLeadNoTail":
            "start=0.0 dur=10.0 slot=0.0+10.0 s=n11 0.0:90.0..10.0:95.0 #31db7181a3380714 tile#b059f1401bf57951",
        "studio.baked2x":
            "start=115.0 w=5.0/20.0/30.0 ext=n56 0.0:117.5..55.0:145.0 #81658379fc627238 sw=5.0/20.0/30.0 plain=n21 0.0:120.0..20.0:130.0 #b30fd7ccec578263",
        "studio.bakedStartTrim":
            "start=215.0 w=5.0/10.0/30.0 ext=n46 0.0:167.5..45.0:190.0 #317b25bb1e33056f sw=5.0/10.0/30.0 plain=n11 0.0:170.0..10.0:175.0 #b57c3acd15d83849",
        "studio.edgeHold":
            "start=315.0 w=5.0/10.0/30.0 ext=n2 0.0:210.0..45.0:210.0 #23f69d8b8af20d48 sw=5.0/10.0/30.0 plain=n2 0.0:210.0..10.0:210.0 #a3f366474f49921e",
        "studio.goldenDefault":
            "start=3.3000000000000007 w=5.0/7.4/30.0 ext=n38 0.0:106.5..35.7:112.0 #7bc7f2b7fbe5e766 sw=5.0/7.4/30.0 plain=n9 0.0:135.5..7.4:162.4 #a505258e5b7a1efc",
        "studio.goldenTrimmedClipScope":
            "start=6.5 w=3.0/4.8999999999999995/4.0 ext=n14 0.0:125.0..11.899999999999999:167.8 #2dfacc64cf55402c sw=3.0/4.8999999999999995/4.0 plain=n7 0.0:141.5..4.899999999999999:159.2 #79013ada3c19328f",
        "studio.leadClamped":
            "start=0.0 w=2.0/5.0/30.0 ext=n38 0.0:60.0..37.0:78.5 #2c6393d0e9a168ad sw=2.0/5.0/30.0 plain=n6 0.0:61.0..5.0:63.5 #4f855fecd4e94c95",
        "studio.noneNearby":
            "start=595.0 w=5.0/10.0/30.0 ext=none sw=nowindow plain=none",
        "studio.sparse":
            "start=50.0 w=5.0/12.0/30.0 ext=n4 0.0:123.07692307692308..47.0:128.68571428571428 #452e5e6699e2fe4c sw=5.0/12.0/30.0 plain=n3 0.0:135.76923076923077..12.0:146.28571428571428 #8c0252eb021b10a7",
        "studio.unbaked":
            "start=55.0 w=5.0/10.0/30.0 ext=n46 0.0:87.5..45.0:110.0 #c9c95c087bfcaf96 sw=5.0/10.0/30.0 plain=n11 0.0:90.0..10.0:95.0 #31db7181a3380714",
        "studio.unbakedNoLeadNoTail":
            "start=60.0 w=0.0/10.0/0.0 ext=n11 0.0:90.0..10.0:95.0 #31db7181a3380714 sw=0.0/10.0/0.0 plain=n11 0.0:90.0..10.0:95.0 #31db7181a3380714",
        "studioVM.baked2x":
            "total=10.0 live=120.0;121.0;122.5;125.0;127.5;130.0 w=5.0/20.0/30.0 s=n56 0.0:117.5..55.0:145.0 #81658379fc627238 dur=55.0 sparse=false max=190.0 live=120.0[120 bpm #30B0C7];121.0[121 bpm #30B0C7];122.5[123 bpm #30B0C7];125.0[125 bpm #30B0C7];127.5[128 bpm #30B0C7];130.0[130 bpm #30B0C7] stat=131 avg bpm;145 max bpm;Z2 · Easy;65% peak;0% redline;Strain 2;54s to peak;+26 bpm rise;nil;nil sliders=5.0/30.0 eff=5.0/30.0 f=20.0 export=slot=0.0+10.0 s=n56 0.0:117.5..55.0:145.0 #81658379fc627238 tile#7281208df7b7ccb2",
        "studioVM.bakedStartTrim":
            "total=10.0 live=170.0;170.5;171.25;172.5;173.75;175.0 w=5.0/10.0/30.0 s=n46 0.0:167.5..45.0:190.0 #317b25bb1e33056f dur=45.0 sparse=false max=190.0 live=170.0[170 bpm #FF9500];170.5[171 bpm #FF9500];171.25[171 bpm #FF3B30];172.5[173 bpm #FF3B30];173.75[174 bpm #FF3B30];175.0[175 bpm #FF3B30] stat=179 avg bpm;190 max bpm;Z5 · Max;100% peak;100% redline;Strain 4;44s to peak;+21 bpm rise;nil;nil sliders=5.0/30.0 eff=5.0/30.0 f=10.0 export=slot=0.0+10.0 s=n46 0.0:167.5..45.0:190.0 #317b25bb1e33056f tile#606a1d3fcce4ea41",
        "studioVM.edgeHold":
            "total=10.0 live=210.0;210.0;210.0;210.0;210.0;210.0 w=5.0/10.0/30.0 s=n2 0.0:210.0..45.0:210.0 #23f69d8b8af20d48 dur=45.0 sparse=true max=190.0 live=210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30];210.0[210 bpm #FF3B30] stat=210 avg bpm;210 max bpm;Z5 · Max;100% peak;100% redline;Strain 4;nil;nil;nil;nil sliders=5.0/30.0 eff=5.0/0.0 f=10.0 export=slot=0.0+10.0 s=n2 0.0:210.0..45.0:210.0 #23f69d8b8af20d48 tile#fc7bc4df54991267",
        "studioVM.goldenDefault":
            "total=7.4 live=135.16649859943976;138.9909019607843;144.1760784313726;151.50638655462186;157.37268907563035;162.17361344537812 w=5.0/7.4/30.0 s=n38 0.0:106.5..35.7:112.0 #7bc7f2b7fbe5e766 dur=35.7 sparse=false max=185.0 live=135.16649859943976[135 bpm #34C759];138.9909019607843[139 bpm #34C759];144.1760784313726[144 bpm #34C759];151.50638655462186[152 bpm #FF9500];157.37268907563035[157 bpm #FF9500];162.17361344537812[162 bpm #FF9500] stat=145 avg bpm;172 max bpm;Z3 · Aerobic;nil;56% redline;Strain 2;19s to peak;+59 bpm rise;nil;nil sliders=5.0/30.0 eff=5.0/23.299999999999997 f=7.4 export=slot=0.0+7.4 s=n38 0.0:106.5..35.7:112.0 #7bc7f2b7fbe5e766 tile#fe8bcdb9244f0f2d",
        "studioVM.goldenTrimmedClipScope":
            "total=4.8999999999999995 live=141.51596638655462;143.78504201680673;146.99411764705883;151.6848739495798;155.69327731092437;159.30588235294118 w=3.0/4.8999999999999995/4.0 s=n14 0.0:125.0..11.899999999999999:167.8 #2dfacc64cf55402c dur=11.899999999999999 sparse=false max=185.0 live=141.51596638655462[142 bpm #34C759];143.78504201680673[144 bpm #34C759];146.99411764705883[147 bpm #34C759];151.6848739495798[152 bpm #FF9500];155.69327731092437[156 bpm #FF9500];159.30588235294118[159 bpm #FF9500] stat=151 avg bpm;159 max bpm;Z4 · Threshold;81% peak;69% redline;Strain 0;4s to peak;+8 bpm rise;nil;nil sliders=3.0/4.0 eff=3.0/4.0 f=4.8999999999999995 export=slot=0.0+4.8999999999999995 s=n14 0.0:125.0..11.899999999999999:167.8 #2dfacc64cf55402c tile#8fd6a218437bffe8",
        "studioVM.leadClamped":
            "total=5.0 live=61.0;61.25;61.625;62.25;62.875;63.5 w=2.0/5.0/30.0 s=n38 0.0:60.0..37.0:78.5 #2c6393d0e9a168ad dur=37.0 sparse=false max=190.0 live=61.0[61 bpm #007AFF];61.25[61 bpm #007AFF];61.625[62 bpm #007AFF];62.25[62 bpm #007AFF];62.875[63 bpm #007AFF];63.5[64 bpm #007AFF] stat=69 avg bpm;79 max bpm;Z1 · Recovery;14% peak;0% redline;Strain 1;36s to peak;+17 bpm rise;nil;nil sliders=5.0/30.0 eff=2.0/30.0 f=5.0 export=slot=0.0+5.0 s=n38 0.0:60.0..37.0:78.5 #2c6393d0e9a168ad tile#87f87d2463712270",
        "studioVM.noneNearby":
            "total=10.0 live=nil;nil;nil;nil;nil;nil w=5.0/10.0/30.0 s=none dur=0.0 sparse=true max=190.0 live=nil[nil ];nil[nil ];nil[nil ];nil[nil ];nil[nil ];nil[nil ] stat=nil;nil;nil;nil;nil;nil;nil;nil;nil;nil sliders=5.0/30.0 eff=5.0/0.0 f=10.0 export=nil",
        "studioVM.sparse":
            "total=12.0 live=135.76923076923077;138.8153846153846;143.3846153846154;150.0027472527472;148.64285714285725;146.2857142857143 w=5.0/12.0/30.0 s=n4 0.0:123.07692307692308..47.0:128.68571428571428 #452e5e6699e2fe4c dur=47.0 sparse=true max=190.0 live=135.76923076923077[136 bpm #34C759];138.8153846153846[139 bpm #34C759];143.3846153846154[143 bpm #34C759];150.0027472527472[150 bpm #34C759];148.64285714285725[149 bpm #34C759];146.2857142857143[146 bpm #34C759] stat=136 avg bpm;151 max bpm;Z3 · Aerobic;70% peak;0% redline;Strain 2;nil;nil;nil;nil sliders=5.0/30.0 eff=5.0/30.0 f=12.0 export=slot=0.0+12.0 s=n4 0.0:123.07692307692308..47.0:128.68571428571428 #452e5e6699e2fe4c tile#6c9f0474da38d8ed",
        "studioVM.unbaked":
            "total=10.0 live=90.0;90.5;91.25;92.5;93.75;95.0 w=5.0/10.0/30.0 s=n46 0.0:87.5..45.0:110.0 #c9c95c087bfcaf96 dur=45.0 sparse=false max=190.0 live=90.0[90 bpm #007AFF];90.5[91 bpm #007AFF];91.25[91 bpm #007AFF];92.5[93 bpm #007AFF];93.75[94 bpm #007AFF];95.0[95 bpm #007AFF] stat=99 avg bpm;110 max bpm;Z1 · Recovery;38% peak;0% redline;Strain 1;44s to peak;+21 bpm rise;nil;nil sliders=5.0/30.0 eff=5.0/30.0 f=10.0 export=slot=0.0+10.0 s=n46 0.0:87.5..45.0:110.0 #c9c95c087bfcaf96 tile#40bdb3cf86283b11",
        "studioVM.unbakedNoLeadNoTail":
            "total=10.0 live=90.25;90.5;91.25;92.5;93.75;94.5 w=0.0/10.0/0.0 s=n11 0.0:90.0..10.0:95.0 #31db7181a3380714 dur=10.0 sparse=false max=190.0 live=90.25[90 bpm #007AFF];90.5[91 bpm #007AFF];91.25[91 bpm #007AFF];92.5[93 bpm #007AFF];93.75[94 bpm #007AFF];94.5[95 bpm #007AFF] stat=93 avg bpm;95 max bpm;Z1 · Recovery;27% peak;0% redline;Strain 0;9s to peak;+4 bpm rise;nil;nil sliders=0.0/0.0 eff=0.0/0.0 f=10.0 export=slot=0.0+10.0 s=n11 0.0:90.0..10.0:95.0 #31db7181a3380714 tile#4144c0af9f037889",
    ]
}
