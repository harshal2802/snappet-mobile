import XCTest
@testable import Snappet

/// Unit tests for the **pure** round trip with another AI app (prompt 247, issue #438 step 4): the clip map, the prompt
/// builder, tolerant reply parsing (many malformed replies), validation with reasons, the unknown-ending mapping, the
/// import builder (sides, provenance), compare / merge against your tags, and provenance in "From your tags" and
/// history. No device.
final class RacketAIRoundTripTests: XCTestCase {

    private func report(_ text: String, sport: RacketSport = .tableTennis, length: Double = 600,
                        file: StaticString = #filePath, line: UInt = #line) -> RacketAIParseReport? {
        switch RacketAIParser.parse(text, sport: sport, clipLengthSec: length) {
        case .success(let r): return r
        case .failure(let e): XCTFail("expected a report, got \(e)", file: file, line: line); return nil
        }
    }

    private func failure(_ text: String, sport: RacketSport = .tableTennis) -> RacketAIParseError? {
        if case .failure(let e) = RacketAIParser.parse(text, sport: sport, clipLengthSec: 600) { return e }
        return nil
    }

    // MARK: Clip map

    func testWholeClipMapsByOffset() {
        let clip = RacketAIClip.whole(385, 1480)
        XCTAssertEqual(clip.lengthSec, 1095)
        XCTAssertEqual(clip.locate(10)?.recSec, 395)
        XCTAssertEqual(clip.locate(-5)?.recSec, 385, "clamped to the start")
        XCTAssertEqual(clip.locate(5000)?.recSec, 1480, "clamped to the end")
        XCTAssertEqual(clip.recordingRange(10, 20).map { [$0.start, $0.end] }, [395, 405])
    }

    func testRalliesOnlyClipSkipsDeadTime() {
        let rs = [RacketRally(startSec: 100, endSec: 108), RacketRally(startSec: 200, endSec: 210)]
        let clip = RacketAIClip.rallies(rs, within: 0, 600)
        // Padded 1 s each side: 99–109 and 199–211.
        XCTAssertEqual(clip.pieces.map { [$0.startSec, $0.endSec] }, [[99, 109], [199, 211]])
        XCTAssertEqual(clip.lengthSec, 22)
        XCTAssertEqual(clip.locate(5)?.recSec, 104)
        XCTAssertEqual(clip.locate(12)?.recSec, 201, "the second piece starts at clip 10")
        // A range across the cut ends where its first piece ends.
        XCTAssertEqual(clip.recordingRange(8, 14).map { [$0.start, $0.end] }, [107, 109])
        XCTAssertTrue(RacketAIClip.rallies([], within: 0, 600).pieces.isEmpty)
    }

    func testFrameTimesAreEvenAndCapped() {
        let short = RacketAIFrames.times(.whole(100, 110))
        XCTAssertEqual(short.map(\.clipSec), [1, 3, 5, 7, 9])
        XCTAssertEqual(short.first?.recSec, 101)
        let long = RacketAIFrames.times(.whole(0, 3600))
        XCTAssertEqual(long.count, RacketAIFrames.maxFrames)
        XCTAssertEqual(long.first?.clipSec, 45)
        XCTAssertTrue(RacketAIFrames.times(RacketAIClip(pieces: [])).isEmpty)
    }

    // MARK: Prompt

    func testPromptIsDeterministicAndCarriesTheSchemaAndRange() {
        let clip = RacketAIClip.whole(385, 1480)
        let a = RacketAIPrompt.build(sport: .tableTennis, clip: clip, title: "Game 1 of match vs Alex")
        let b = RacketAIPrompt.build(sport: .tableTennis, clip: clip, title: "Game 1 of match vs Alex")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("You are analyzing a table tennis video from Snappet."))
        XCTAssertTrue(a.contains("This video is 18:15 long (1095 seconds): Game 1 of match vs Alex, 6:25–24:40 of the recording."), a)
        XCTAssertTrue(a.contains("between 0 and 1095"))
        XCTAssertTrue(a.contains("Use only these endings: out, net, double_bounce, serve_fault, let_replay, edge_ball, missed_swing, interrupted."))
        XCTAssertTrue(a.contains("Reply with JSON only, using schema snappet.racket-analysis/1:"))
        XCTAssertTrue(a.contains(#"{"sport":"table_tennis","analyzer":{"app":"","model":""},"rallies":[{"start_s":0,"end_s":0,"winner":"near","ending":"net""#))
        XCTAssertFalse(a.contains("still frames"))
    }

    func testPromptPerSportMatchesTheBoards() {
        XCTAssertEqual(RacketAIWire.endings(.badminton), ["landed_in", "out", "net", "service_fault", "missed_shot", "hit_player", "let_replay", "interrupted"])
        XCTAssertEqual(RacketAIWire.endings(.tennis), ["winner", "out", "net", "double_bounce", "double_fault", "missed_shot", "let_replay", "interrupted"])
        XCTAssertEqual(RacketAIWire.endings(.pickleball), ["winner", "out", "net", "double_bounce", "kitchen_fault", "two_bounce_fault", "service_fault", "interrupted"])
        XCTAssertEqual(RacketAIWire.endings(.padel), ["winner", "out", "net", "double_bounce", "hit_wall_first", "double_fault", "let_replay", "interrupted"])
        XCTAssertEqual(RacketAIWire.endings(.squash), ["winner", "tin", "out", "not_up", "service_fault", "let_replay", "stroke", "no_let"])
        XCTAssertTrue(RacketAIPrompt.exampleJSON(.squash).contains(#""ending":"tin""#))
        XCTAssertTrue(RacketAIPrompt.exampleJSON(.badminton).contains(#""sport":"badminton""#))
    }

    func testPromptEditsKeepTheFixedTail() {
        let clip = RacketAIClip.rallies([RacketRally(startSec: 10, endSec: 20), RacketRally(startSec: 50, endSec: 60)], within: 0, 100)
        let p = RacketAIPrompt.build(sport: .squash, clip: clip, title: "Game 2", framesOnly: true, customBody: "  Be brief.  ")
        XCTAssertTrue(p.hasPrefix("Be brief.\n\n"))
        XCTAssertTrue(p.contains("It joins 2 stretches of play"))
        XCTAssertTrue(p.contains("still frames"))
        XCTAssertTrue(p.contains("snappet.racket-analysis/1"))
        let blank = RacketAIPrompt.build(sport: .squash, clip: clip, title: "Game 2", customBody: "   ")
        XCTAssertTrue(blank.hasPrefix(RacketAIPrompt.defaultBody(.squash)), "an emptied body falls back to the default")
    }

    // MARK: Times

    func testTimeFormats() {
        XCTAssertEqual(RacketAITime.seconds("75"), 75)
        XCTAssertEqual(RacketAITime.seconds("75s"), 75)
        XCTAssertEqual(RacketAITime.seconds("75.5 sec"), 75.5)
        XCTAssertEqual(RacketAITime.seconds("1:15"), 75)
        XCTAssertEqual(RacketAITime.seconds("01:02.5"), 62.5)
        XCTAssertEqual(RacketAITime.seconds("1:01:15"), 3675)
        XCTAssertEqual(RacketAITime.seconds("75:30"), 4530, "minutes past an hour in mm:ss")
        XCTAssertEqual(RacketAITime.seconds("1m 05s"), 65)
        XCTAssertEqual(RacketAITime.seconds(NSNumber(value: 12.25)), 12.25)
        XCTAssertNil(RacketAITime.seconds("1:75"), "seconds past 59")
        XCTAssertNil(RacketAITime.seconds("abc"))
        XCTAssertNil(RacketAITime.seconds(""))
        XCTAssertNil(RacketAITime.seconds(NSNumber(value: true)), "a JSON true isn't a time")
        XCTAssertNil(RacketAITime.seconds(":30"))
    }

    // MARK: Parsing — JSON in its many shapes

    private let clean = #"{"sport":"table_tennis","analyzer":{"app":"ChatGPT","model":"gpt-5"},"rallies":[{"start_s":10,"end_s":18,"winner":"near","ending":"net","shots":[{},{},{}],"confidence":0.8},{"start_s":30,"end_s":41.5,"winner":"far","ending":"edge_ball"}]}"#

    func testCleanReply() {
        guard let r = report(clean) else { return }
        XCTAssertEqual(r.format, .json)
        XCTAssertEqual(r.rallies.count, 2)
        XCTAssertEqual(r.rallies[0].startSec, 10)
        XCTAssertEqual(r.rallies[0].winner, .near)
        XCTAssertEqual(r.rallies[0].ending, .net)
        XCTAssertEqual(r.rallies[0].shots, 3)
        XCTAssertEqual(r.rallies[0].confidence, 0.8)
        XCTAssertEqual(r.rallies[1].ending, .edgeBall)
        XCTAssertEqual(r.app, "ChatGPT")
        XCTAssertEqual(r.model, "gpt-5")
        XCTAssertTrue(r.skipped.isEmpty)
        XCTAssertTrue(r.warnings.isEmpty)
    }

    func testCodeFenceAndProseAroundIt() {
        let text = "Sure! Here is the analysis of your video:\n\n```json\n\(clean)\n```\n\nLet me know if you want shots too."
        XCTAssertEqual(report(text)?.rallies.count, 2)
        let bare = "Here you go: \(clean) Hope that helps [1]."
        XCTAssertEqual(report(bare)?.rallies.count, 2)
        let unlabeled = "```\n\(clean)\n```"
        XCTAssertEqual(report(unlabeled)?.rallies.count, 2)
    }

    func testCitationBracketsBeforeTheJSONAreSkipped() {
        let text = "Based on the frames [1][2], rallies follow.\n\(clean)"
        XCTAssertEqual(report(text)?.rallies.count, 2)
    }

    func testSmartQuotesFromNotes() {
        let text = clean.replacingOccurrences(of: "\"", with: "\u{201C}")
        XCTAssertEqual(report(text)?.rallies.count, 2)
        let mixed = "\u{FEFF}" + clean.replacingOccurrences(of: "\"ending\"", with: "\u{201C}ending\u{201D}")
        XCTAssertEqual(report(mixed)?.rallies.count, 2)
    }

    func testTrailingCommasCommentsAndSingleQuotes() {
        let text = """
        {
          // the app's notes
          'rallies': [
            {'start_s': 10, 'end_s': 18, 'winner': 'near',},
            {start_s: 30, end_s: 40, winner: "far"},
          ],
        }
        """
        let r = report(text)
        XCTAssertEqual(r?.rallies.count, 2)
        XCTAssertEqual(r?.rallies.last?.winner, .far)
    }

    func testTopLevelArrayAndNestedRallies() {
        XCTAssertEqual(report(#"[{"start":"0:10","end":"0:18","winner":"near"}]"#)?.rallies.first?.startSec, 10)
        XCTAssertEqual(report(#"{"analysis":{"result":{"rallies":[{"start_s":1,"end_s":5}]}}}"#)?.rallies.count, 1)
        XCTAssertEqual(report(#"{"points":[{"from":1,"to":5}]}"#)?.rallies.count, 1)
    }

    func testKeyAliasesAndTimeStrings() {
        let text = #"{"rallies":[{"Start Time":"1:05","End-Time":"1:12.5","Won By":"Far side","How":"Double bounce"},{"time":"2:00 - 2:08","point_to":"near camera","outcome":"SERVE_FAULT"},{"start_s":300,"duration":7}]}"#
        guard let r = report(text) else { return }
        XCTAssertEqual(r.rallies.map(\.startSec), [65, 120, 300])
        XCTAssertEqual(r.rallies.map(\.endSec), [72.5, 128, 307])
        XCTAssertEqual(r.rallies.map(\.winner), [.far, .near, nil])
        XCTAssertEqual(r.rallies.map(\.ending), [.doubleBounce, .serveFault, nil])
    }

    func testConfidenceAsPercentAndUnknownAnalyzer() {
        let r = report(#"{"analyzer":{"app":"unknown","model":""},"rallies":[{"start_s":1,"end_s":5,"confidence":85}]}"#)
        XCTAssertEqual(r?.rallies.first?.confidence, 0.85)
        XCTAssertNil(r?.app)
        XCTAssertNil(r?.model)
    }

    func testSportMismatchIsAWarningNotAFailure() {
        let r = report(#"{"sport":"badminton","rallies":[{"start_s":1,"end_s":5}]}"#)
        XCTAssertEqual(r?.rallies.count, 1)
        XCTAssertEqual(r?.warnings.first, "The reply says it’s badminton; this is table tennis.")
        XCTAssertEqual(report(#"{"sport":"Table tennis","rallies":[{"start_s":1,"end_s":5}]}"#)?.warnings, [])
    }

    // MARK: Parsing — a pasted table / list

    func testMarkdownTable() {
        let text = """
        | # | Start | End | Winner | Ending |
        |---|-------|-----|--------|--------|
        | 1 | 0:10 | 0:18 | near | net |
        | 2 | 0:30 | 0:41 | far | double bounce |
        | 3 | 1:00 | 1:06 | Far | long |
        """
        guard let r = report(text) else { return }
        XCTAssertEqual(r.format, .table)
        XCTAssertEqual(r.rallies.map(\.startSec), [10, 30, 60])
        XCTAssertEqual(r.rallies.map(\.winner), [.near, .far, .far])
        XCTAssertEqual(r.rallies.map(\.ending), [.net, .doubleBounce, nil])
    }

    func testPlainListWithBareSeconds() {
        let text = """
        Rally 1: 12.0 to 19.5, near won by net
        Rally 2: 25 - 31, far won (out)
        2 rallies found in total.
        """
        guard let r = report(text) else { return }
        XCTAssertEqual(r.rallies.map(\.startSec), [12, 25])
        XCTAssertEqual(r.rallies.map(\.endSec), [19.5, 31])
        XCTAssertEqual(r.rallies.map(\.ending), [.net, .out])
    }

    func testCSVRows() {
        let text = "start,end,winner\n10s,18s,near\n30s,40s,far"
        XCTAssertEqual(report(text)?.rallies.count, 2)
    }

    func testBrokenJSONFallsBackToLines() {
        // A truncated reply: the object never closes, but each line still has its times.
        let text = """
        {"rallies":[
        {"start_s": 10, "end_s": 18, "winner":"near"},
        {"start_s": 30, "end_s": 40, "winner":"far"},
        """
        guard let r = report(text) else { return }
        XCTAssertEqual(r.format, .table, "no complete reply object, so each line is read on its own")
        XCTAssertEqual(r.rallies.map(\.startSec), [10, 30])
        XCTAssertEqual(r.rallies.map(\.winner), [.near, .far])
    }

    // MARK: Parsing — failures

    func testNothingToRead() {
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("   \n "), .empty)
        XCTAssertEqual(failure("I can't watch videos, sorry."), .nothingFound)
        XCTAssertEqual(failure(#"{"error":"video too long"}"#), .noRallies)
        XCTAssertEqual(failure(#"{"rallies":[]}"#), .noRallies)
        XCTAssertEqual(failure("[]"), .noRallies)
    }

    // MARK: Validation

    func testValidationRejectsWithReasonsAndClamps() {
        let text = #"""
        {"rallies":[
          {"start_s":10,"end_s":18},
          {"start_s":20,"end_s":15},
          {"start_s":22,"end_s":22.2},
          {"start_s":700,"end_s":710},
          {"start_s":595,"end_s":640},
          {"start_s":-3,"end_s":4},
          {"start_s":12,"end_s":17},
          {"start_s":10.1,"end_s":18.1},
          {"end_s":50},
          {"start_s":"later","end_s":"soon"}
        ]}
        """#
        guard let r = report(text, length: 600) else { return }
        XCTAssertEqual(r.rallies.map(\.number), [6, 1, 5])
        XCTAssertEqual(r.rallies.map(\.startSec), [0, 10, 595])
        XCTAssertEqual(r.rallies.last?.endSec, 600, "an end past the video is trimmed")
        XCTAssertEqual(r.rallies.first?.clamped, true)
        XCTAssertEqual(r.clampedCount, 2)
        XCTAssertEqual(r.skipped.map(\.number), [2, 3, 4, 7, 8, 9, 10])
        XCTAssertEqual(r.skipped.map(\.reason), [.endsBeforeStart, .tooShort, .afterVideoEnds, .overlaps(1), .duplicate(1),
                                                 .missingTimes, .missingTimes])
        XCTAssertEqual(r.skipped[3].line, "Rally 7: overlaps rally 1")
        XCTAssertTrue(r.warnings.contains("2 rallies ran past the video’s edges and were trimmed to fit."))
    }

    func testTouchingRalliesAreFine() {
        let r = report(#"{"rallies":[{"start_s":10,"end_s":20},{"start_s":19.9,"end_s":30}]}"#)
        XCTAssertEqual(r?.rallies.count, 2)
    }

    func testTooManyRallies() {
        let many = (0..<1005).map { #"{"start_s":\#(Double($0) * 2),"end_s":\#(Double($0) * 2 + 1)}"# }.joined(separator: ",")
        let r = report("{\"rallies\":[\(many)]}", length: 5000)
        XCTAssertEqual(r?.rallies.count, RacketAIParser.maxRallies)
        XCTAssertEqual(r?.skipped.filter { $0.reason == .tooMany }.count, 5)
    }

    // MARK: Endings

    func testEndingNamesAndLabelsAnyCase() {
        XCTAssertEqual(RacketAIWire.ending("Let (replay)", sport: .tableTennis), .letReplay)
        XCTAssertEqual(RacketAIWire.ending("let_replay", sport: .tableTennis), .letReplay)
        XCTAssertEqual(RacketAIWire.ending("Two-bounce fault", sport: .pickleball), .twoBounceFault)
        XCTAssertEqual(RacketAIWire.ending("NOT_UP", sport: .squash), .notUp)
        XCTAssertNil(RacketAIWire.ending("winner", sport: .tableTennis), "table tennis has no winner ending")
        XCTAssertNil(RacketAIWire.ending("tin", sport: .tennis))
    }

    func testUnknownEndingSuggestionsPerSport() {
        // Review5 low: "long" is out, in every sport with an out (the board's TT "Net" was the chip after Out).
        XCTAssertEqual(RacketAIWire.suggestion("long", sport: .tableTennis), .out)
        XCTAssertEqual(RacketAIWire.suggestion("long", sport: .badminton), .out)
        XCTAssertEqual(RacketAIWire.suggestion("Long", sport: .squash), .out)
        XCTAssertEqual(RacketAIWire.suggestion("netted", sport: .squash), .tin, "squash has no net: the tin")
        XCTAssertEqual(RacketAIWire.suggestion("ace", sport: .tennis), .winner)
        XCTAssertEqual(RacketAIWire.suggestion("ace", sport: .badminton), .landedIn)
        XCTAssertEqual(RacketAIWire.suggestion("fault", sport: .tennis), .doubleFault)
        XCTAssertNil(RacketAIWire.suggestion("ace", sport: .tableTennis))
        XCTAssertNil(RacketAIWire.suggestion("banana", sport: .tennis))
    }

    func testUnknownEndingsAreCountedAndResolved() {
        let text = #"{"rallies":[{"start_s":1,"end_s":5,"ending":"long"},{"start_s":10,"end_s":15,"ending":"Long"},{"start_s":20,"end_s":25,"ending":"banana"},{"start_s":30,"end_s":35,"ending":"net"}]}"#
        guard let r = report(text) else { return }
        XCTAssertEqual(r.unknownEndings.map(\.word), ["long", "banana"])
        XCTAssertEqual(r.unknownEndings.map(\.count), [2, 1])
        XCTAssertEqual(r.unknownEndings.map(\.suggestion), [.out, nil])
        XCTAssertEqual(RacketAIImportBuilder.unknownLine(r.unknownEndings[0]), "Two rallies used an ending Snappet doesn’t know: “long”.")
        XCTAssertEqual(RacketAIImportBuilder.unknownLine(r.unknownEndings[1]), "One rally used an ending Snappet doesn’t know: “banana”.")

        var choices = RacketAIImportBuilder.defaultChoices(r)
        XCTAssertEqual(choices["long"], .countAs(.out))
        XCTAssertEqual(choices["banana"], .leaveOut)
        XCTAssertEqual(RacketAIImportBuilder.counts(r, choices: choices), .init(read: 3, skipped: 1))
        XCTAssertEqual(RacketAIImportBuilder.counts(r, choices: choices).readLine, "Read 3 rallies")
        choices["long"] = .leaveOut
        XCTAssertEqual(RacketAIImportBuilder.counts(r, choices: choices).skippedLine, "3 skipped")
        choices["banana"] = .countAs(.edgeBall)
        let rallies = RacketAIImportBuilder.rallies(r, choices: choices, clip: .whole(0, 600), side: .near, source: "ai:ChatGPT")
        XCTAssertEqual(rallies.map(\.ending), [.edgeBall, .net])
    }

    // MARK: Import builder

    func testImportMapsTimesSidesAndProvenance() {
        let text = #"{"rallies":[{"start_s":5,"end_s":9,"winner":"near","ending":"out","shots":[1,2,3,4,5]},{"start_s":14,"end_s":20,"winner":"far"}]}"#
        let clip = RacketAIClip.rallies([RacketRally(startSec: 100, endSec: 108), RacketRally(startSec: 200, endSec: 210)], within: 0, 600)
        guard let r = report(text, length: clip.lengthSec) else { return }
        let near = RacketAIImportBuilder.rallies(r, choices: [:], clip: clip, side: .near, source: RacketAISource.raw("Gemini"))
        XCTAssertEqual(near.map { [$0.startSec, $0.endSec] }, [[104, 108], [203, 209]])
        XCTAssertEqual(near.map(\.winner), [.us, .them])
        XCTAssertEqual(near.first?.aiShots, 5)
        XCTAssertEqual(near.first?.sourceRaw, "ai:Gemini")
        XCTAssertEqual(near.first?.aiName, "Gemini")
        XCTAssertTrue(near.allSatisfy(\.isFromAI))
        let far = RacketAIImportBuilder.rallies(r, choices: [:], clip: clip, side: .far, source: "ai:Gemini")
        XCTAssertEqual(far.map(\.winner), [.them, .us], "you were on the far side")
    }

    func testWinnerWords() {
        XCTAssertEqual(RacketAIWire.winner("Near side"), .near)
        XCTAssertEqual(RacketAIWire.winner("far-camera"), .far)
        XCTAssertEqual(RacketAIWire.winner("opponent"), .them)
        XCTAssertEqual(RacketAIWire.winner("you"), .us)
        XCTAssertNil(RacketAIWire.winner("unknown"))
        XCTAssertEqual(RacketAIWire.winner(.us, side: .far), .us)
    }

    func testSourceLabel() {
        XCTAssertEqual(RacketAISource.label(app: .chatGPT, reported: "Gemini"), "ChatGPT", "the picked app wins")
        XCTAssertEqual(RacketAISource.label(app: .other, reported: "Perplexity"), "Perplexity")
        XCTAssertEqual(RacketAISource.label(app: .other, reported: nil), "Other app")
        XCTAssertNil(RacketAISource.name(nil))
        XCTAssertNil(RacketAISource.name("you"))
    }

    // MARK: Compare and merge

    private let sides = (us: "You", them: "Alex")

    private func ai(_ s: Double, _ e: Double, _ w: RacketRallyWinner?, _ end: RacketRallyEnding? = nil, shots: Int? = nil) -> RacketRally {
        var r = RacketRally(startSec: s, endSec: e, winner: w, ending: end)
        r.sourceRaw = "ai:ChatGPT"
        r.tagSourceRaw = "ai:ChatGPT"
        r.aiShots = shots
        return r
    }

    func testCompareFindsAgreementsAndDisagreements() {
        let mineTagged = RacketRally(startSec: 10, endSec: 18, winner: .us, ending: .net)
        let mineUntagged = RacketRally(startSec: 30, endSec: 40)
        let mineAgree = RacketRally(startSec: 50, endSec: 58, winner: .them)
        let mineNotRally = RacketRally(startSec: 70, endSec: 74, notRally: true)
        let ais = [ai(10.5, 18.2, .them, .net), ai(30, 41, .us, .out), ai(50, 57, .them), ai(70, 75, .us),
                   ai(90, 99, .us, shots: 5)]
        let r = RacketAICompare.build(ai: ais, yours: [mineTagged, mineUntagged, mineAgree, mineNotRally],
                                      appName: "ChatGPT", sides: sides)
        XCTAssertEqual(r.total, 5)
        XCTAssertEqual(r.matching, 1)
        XCTAssertEqual(r.matchLine, "1 of 5 match")
        XCTAssertEqual(r.items.map(\.title), ["Rally 1 · winner", "Rally 2 · winner", "Rally 2 · ending",
                                              "Rally 4 · is it a rally?", "Rally 5 · is it a rally?"])
        XCTAssertEqual(r.items[0].yours, "Yours: You won")
        XCTAssertEqual(r.items[0].theirs, "ChatGPT: Alex won")
        XCTAssertTrue(r.items[0].protected, "you tagged it yourself")
        XCTAssertEqual(r.items[1].yours, "Yours: Not tagged")
        XCTAssertFalse(r.items[1].protected)
        XCTAssertEqual(r.items[2].theirs, "ChatGPT: Out")
        XCTAssertEqual(r.items[3].yours, "Yours: Not a rally")
        XCTAssertTrue(r.items[3].protected)
        XCTAssertEqual(r.items[4].yours, "Yours: Not marked")
        XCTAssertEqual(r.items[4].theirs, "ChatGPT: Yes, 5 shots")
        XCTAssertEqual(r.disagreementLine, "5 disagreements")
    }

    func testPairingIsOneToOneByBestOverlap() {
        let mine = RacketRally(startSec: 10, endSec: 20)
        let a = ai(9, 21, .us), b = ai(15, 19, .them)
        let pairs = RacketAICompare.pairs(ai: [a, b], yours: [mine])
        XCTAssertEqual(pairs[a.id], mine.id)
        XCTAssertNil(pairs[b.id], "the second one is a new rally")
        XCTAssertFalse(RacketAICompare.sameRally(RacketRally(startSec: 0, endSec: 10), RacketRally(startSec: 9, endSec: 30)))
    }

    func testNothingChangesUnlessPicked() {
        let mine = RacketRally(startSec: 10, endSec: 18, winner: .us)
        let ais = [ai(10, 18, .them), ai(30, 40, .us, .out)]
        let r = RacketAICompare.build(ai: ais, yours: [mine], appName: "ChatGPT", sides: sides)
        let keep = RacketAIMerge.apply(r, picks: RacketAICompare.defaultPicks(r), yours: [mine], ai: ais, source: "ai:ChatGPT")
        XCTAssertEqual(keep.rallies, [mine], "Keep my choices with nothing picked changes nothing")
        XCTAssertEqual(keep.accepted, 0)
    }

    func testUseAppForAllLeavesYourOwnTags() {
        let mine = RacketRally(startSec: 10, endSec: 18, winner: .us)
        let untagged = RacketRally(startSec: 50, endSec: 60)
        let ais = [ai(10, 18, .them), ai(30, 40, .us, .out), ai(50, 60, .them, .net)]
        let r = RacketAICompare.build(ai: ais, yours: [mine, untagged], appName: "ChatGPT", sides: sides)
        let picks = RacketAICompare.useAppForAll(r, current: RacketAICompare.defaultPicks(r))
        let out = RacketAIMerge.apply(r, picks: picks, yours: [mine, untagged], ai: ais, source: "ai:ChatGPT")
        XCTAssertEqual(out.rallies.count, 3)
        XCTAssertEqual(out.rallies[0], mine, "your own tag is untouched")
        XCTAssertEqual(out.rallies[1].winner, .us)
        XCTAssertEqual(out.rallies[1].ending, .out)
        XCTAssertEqual(out.rallies[1].sourceRaw, "ai:ChatGPT")
        XCTAssertEqual(out.rallies[2].id, untagged.id, "your marked rally keeps its identity")
        XCTAssertEqual(out.rallies[2].winner, .them)
        XCTAssertEqual(out.rallies[2].ending, .net)
        XCTAssertNil(out.rallies[2].sourceRaw, "you marked it")
        XCTAssertEqual(out.rallies[2].tagSourceRaw, "ai:ChatGPT", "the app tagged it")
        XCTAssertEqual(out.accepted, 3)
    }

    func testPickingTheAppOnYourOwnTagChangesOnlyThatItem() {
        let mine = RacketRally(startSec: 10, endSec: 18, winner: .us, ending: .net)
        let ais = [ai(10, 18, .them, .out)]
        let r = RacketAICompare.build(ai: ais, yours: [mine], appName: "ChatGPT", sides: sides)
        var picks = RacketAICompare.defaultPicks(r)
        picks[r.items.first { $0.field == .winner }!.id] = .theirs
        let out = RacketAIMerge.apply(r, picks: picks, yours: [mine], ai: ais, source: "ai:ChatGPT")
        XCTAssertEqual(out.rallies[0].winner, .them)
        XCTAssertEqual(out.rallies[0].ending, .net, "the ending stayed yours")
        XCTAssertEqual(out.rallies[0].tagSourceRaw, "ai:ChatGPT")
    }

    func testNotRallyPickedAsRally() {
        let mine = RacketRally(startSec: 10, endSec: 14, notRally: true)
        let ais = [ai(10, 14, .us, .net)]
        let r = RacketAICompare.build(ai: ais, yours: [mine], appName: "ChatGPT", sides: sides)
        var picks = RacketAICompare.defaultPicks(r)
        picks[r.items[0].id] = .theirs
        let out = RacketAIMerge.apply(r, picks: picks, yours: [mine], ai: ais, source: "ai:ChatGPT")
        XCTAssertTrue(out.rallies[0].isRally)
        XCTAssertEqual(out.rallies[0].winner, .us)
    }

    func testANewRallyOverlappingYoursIsNotAdded() {
        // Two AI rallies both overlap one of yours: one pairs, the other is "new" but can't be added over yours.
        let mine = RacketRally(startSec: 10, endSec: 30)
        let ais = [ai(10, 29, .us), ai(25, 35, .them)]
        let r = RacketAICompare.build(ai: ais, yours: [mine], appName: "ChatGPT", sides: sides)
        let picks = RacketAICompare.useAppForAll(r, current: [:])
        let out = RacketAIMerge.apply(r, picks: picks, yours: [mine], ai: ais, source: "ai:ChatGPT")
        XCTAssertEqual(out.rallies.count, 1)
        XCTAssertEqual(out.accepted, 1)
    }

    func testReplayIsNotAWinnerDisagreement() {
        let mine = RacketRally(startSec: 10, endSec: 18, ending: .letReplay)
        let r = RacketAICompare.build(ai: [ai(10, 18, .us, .letReplay)], yours: [mine], appName: "ChatGPT", sides: sides)
        XCTAssertTrue(r.items.isEmpty)
        XCTAssertEqual(r.matching, 1)
        XCTAssertEqual(r.disagreementLine, "No disagreements")
    }

    func testReviewMarksTheImport() {
        let imp = RacketAIImport(appRaw: "chatGPT", appName: "ChatGPT", model: nil, importedAt: .now, partStart: 0,
                                 partEnd: 100, rallies: [ai(1, 5, .us)])
        XCTAssertTrue(imp.isPending)
        let reviewed = RacketAIMerge.review([imp], id: imp.id, accepted: 1)
        XCTAssertFalse(reviewed[0].isPending)
        XCTAssertEqual(reviewed[0].accepted, 1)
    }

    // MARK: Stored on the log

    func testLogFindsTheLastSendAndPendingSuggestions() throws {
        var log = RacketRecordingLog(startedAt: Date(timeIntervalSince1970: 0))
        let old = RacketAIRequest(appRaw: "gemini", kindRaw: "wholeSmaller", sentAt: Date(timeIntervalSince1970: 10),
                                  partStart: 0, partEnd: 100, clip: .whole(0, 100))
        let new = RacketAIRequest(appRaw: "chatGPT", kindRaw: "ralliesOnly", sentAt: Date(timeIntervalSince1970: 20),
                                  partStart: 0, partEnd: 100, clip: .whole(0, 50))
        let other = RacketAIRequest(appRaw: "claude", kindRaw: "wholeSmaller", sentAt: Date(timeIntervalSince1970: 30),
                                    partStart: 100, partEnd: 200, clip: .whole(100, 200))
        log.aiRequests = [old, new, other]
        XCTAssertEqual(log.lastAIRequest(partStart: 0, partEnd: 100)?.app, .chatGPT)
        XCTAssertNil(log.lastAIRequest(partStart: 0, partEnd: 150))
        var reviewed = RacketAIImport(appRaw: "chatGPT", appName: "ChatGPT", model: nil, importedAt: .now, partStart: 0,
                                      partEnd: 100, rallies: [ai(1, 5, .us)])
        reviewed.reviewed = true
        let pending = RacketAIImport(appRaw: "chatGPT", appName: "ChatGPT", model: nil, importedAt: .now, partStart: 0,
                                     partEnd: 100, rallies: [ai(10, 15, .us), ai(150, 155, .us)])
        log.aiImports = [reviewed, pending]
        XCTAssertEqual(log.pendingAIImports(partStart: 0, partEnd: 100).map(\.id), [pending.id])
        XCTAssertEqual(log.aiSuggestions(partStart: 0, partEnd: 100).map(\.startSec), [10])

        // Additive Optionals: a step-3 log (without them) still decodes, and these round-trip.
        let data = try JSONEncoder().encode(log)
        let back = try JSONDecoder().decode(RacketRecordingLog.self, from: data)
        XCTAssertEqual(back.allAIImports.count, 2)
        XCTAssertEqual(back.allAIRequests.last?.clip, other.clip)
        let bare = try JSONDecoder().decode(RacketRecordingLog.self, from: JSONEncoder().encode(RacketRecordingLog(startedAt: .now)))
        XCTAssertNil(bare.aiImports)
    }

    // MARK: Provenance in From your tags and history

    func testProvenanceInSummaryAndHistory() {
        var accepted = RacketRally(startSec: 30, endSec: 40, winner: .us)
        accepted.sourceRaw = "ai:ChatGPT"
        var tagged = RacketRally(startSec: 50, endSec: 60, winner: .them)
        tagged.tagSourceRaw = "ai:ChatGPT"
        let mine = RacketRally(startSec: 10, endSec: 18, winner: .us)
        let s = RacketTagSummary.make([mine, accepted, tagged], sport: .tableTennis)
        XCTAssertEqual(s.tagged, 3, "accepted items count — you chose them")
        XCTAssertEqual(s.fromAI, 2)
        XCTAssertEqual(s.sourceLine, "From your tags, 3 of 3 · 2 accepted from ChatGPT")
        XCTAssertEqual(RacketTagSummary.make([mine], sport: .tableTennis).sourceLine, "From your tags, 1 of 1")
        var gemini = RacketRally(startSec: 70, endSec: 80, winner: .us)
        gemini.sourceRaw = "ai:Gemini"
        XCTAssertTrue(RacketTagSummary.make([accepted, gemini], sport: .tableTennis).sourceLine.hasSuffix("2 accepted from other apps"))

        // Retagging by hand makes the tag yours again.
        let retagged = RacketRallyMarking.tag([tagged], id: tagged.id, winner: .us, ending: nil, lastShotBy: nil, notRally: false)
        XCTAssertNil(retagged[0].tagSourceRaw)
        XCTAssertFalse(retagged[0].isFromAI)
    }

    func testSuggestionsDontCountInHistoryUntilAccepted() {
        var ex = SessionExercise(exerciseId: "racket", targetSets: 0, targetReps: "", targetRestSeconds: 0, sets: [])
        ex.disciplineRaw = WorkoutDiscipline.racket.rawValue
        var log = RacketRecordingLog(startedAt: .now)
        log.rallies = [RacketRally(startSec: 10, endSec: 18, winner: .us)]
        log.aiImports = [RacketAIImport(appRaw: "chatGPT", appName: "ChatGPT", model: nil, importedAt: .now, partStart: 0,
                                        partEnd: 100, rallies: [ai(30, 40, .us), ai(50, 60, .them)])]
        ex.racketRecordingLog = log
        var t = RacketTagTotals.of([ex])
        XCTAssertEqual(t.marked, 1, "suggestions don't count")
        XCTAssertEqual(t.fromAI, 0)
        var accepted = ai(30, 40, .us)
        accepted.tagSourceRaw = "ai:ChatGPT"
        ex.racketRecordingLog?.rallies?.append(accepted)
        t = RacketTagTotals.of([ex])
        XCTAssertEqual(t.marked, 2)
        XCTAssertEqual(t.wonUs, 2)
        XCTAssertEqual(t.fromAI, 1)
    }
}
