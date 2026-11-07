import Foundation

// MARK: - Round trip with another AI app (prompt 247, issue #438 step 4) — pure
//
// No model finds rallies yet (step 5), so a player can send a part's video and a prompt written for the sport to an AI
// app they already use, bring the reply back (paste or a file), and compare it with their own tags. Snappet makes no
// network call and holds no API key: the system share sheet carries the clip, the clipboard / Files bring the reply.
// Boards: TtAISend, TtAIPrompt, TtAIImport, TtAICompare (+ Bd / Tn / Pb / Pd / Sq). Tested in `RacketAIRoundTripTests`.

/// The app the player sends to (AISend "Send to"). The share sheet does the sending; this names the app in the copy and
/// on the results ("labelled ChatGPT").
enum RacketAIApp: String, Codable, CaseIterable, Sendable {
    case chatGPT, gemini, claude, other

    var name: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .other: return "Other app"
        }
    }

    /// The AISend row.
    var rowLabel: String {
        switch self {
        case .claude: return "Claude · frames only"
        case .other: return "Other apps…"
        default: return name
        }
    }

    /// Claude can't take video, so Snappet sends still frames from each rally (board copy).
    var framesOnly: Bool { self == .claude }
}

/// AISend "What to send".
enum RacketAISendKind: String, Codable, CaseIterable, Sendable {
    case ralliesOnly, wholeSmaller, original

    func title(unit: String) -> String {
        switch self {
        case .ralliesOnly: return "Rallies only, smaller file"
        case .wholeSmaller: return "Whole \(unit), smaller file"
        case .original: return "Original quality"
        }
    }

    var detail: String {
        switch self {
        case .ralliesOnly: return "Best for upload limits"
        case .wholeSmaller: return "Includes dead time"
        case .original: return "Large file"
        }
    }

    var smaller: Bool { self != .original }
}

/// Which side of the camera the player was on (AIImport "Which side were you on?").
enum RacketAISide: String, Codable, CaseIterable, Sendable { case near, far }

/// Where a rally or its tags came from: `nil` is you; `"ai:<name>"` is another AI app (prompt 247). Step 5's model will
/// add its own prefix.
enum RacketAISource {
    static let prefix = "ai:"

    static func raw(_ name: String) -> String { prefix + name }
    static func isAI(_ raw: String?) -> Bool { raw?.hasPrefix(prefix) == true }
    static func name(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix(prefix) else { return nil }
        return String(raw.dropFirst(prefix.count))
    }

    /// The name results are labelled with: the app picked on send, or what the reply reported for "Other apps".
    static func label(app: RacketAIApp, reported: String?) -> String {
        if app == .other, let r = reported?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty, r.count <= 30 {
            return r
        }
        return app.name
    }
}

// MARK: - The clip that was sent

/// The video sent, as pieces of the recording joined end to end (one piece for a whole part; one per rally stretch
/// for "Rallies only", the dead time cut). Clip seconds map back to recording seconds piece by piece.
struct RacketAIClip: Codable, Hashable, Sendable {
    struct Piece: Codable, Hashable, Sendable {
        var startSec: Double
        var endSec: Double
        var lengthSec: Double { max(0, endSec - startSec) }
    }

    var pieces: [Piece]

    var lengthSec: Double { pieces.reduce(0) { $0 + $1.lengthSec } }

    static func whole(_ lo: Double, _ hi: Double) -> RacketAIClip { RacketAIClip(pieces: [Piece(startSec: lo, endSec: max(lo, hi))]) }

    /// "Rallies only": your marked rallies in the part, padded and merged like Keep rallies only.
    static func rallies(_ rallies: [RacketRally], within lo: Double, _ hi: Double) -> RacketAIClip {
        let inPart = RacketRallyMarking.inRange(rallies, lo, hi)
        let ranges = RacketKeepRallies.ranges(inPart, duration: hi)
            .map { max(lo, $0.lowerBound)...min(hi, $0.upperBound) }
            .filter { $0.upperBound > $0.lowerBound }
        return RacketAIClip(pieces: ranges.map { Piece(startSec: $0.lowerBound, endSec: $0.upperBound) })
    }

    /// The piece holding clip time `t` and the recording time it maps to.
    func locate(_ t: Double) -> (piece: Int, recSec: Double)? {
        guard !pieces.isEmpty else { return nil }
        var cursor = 0.0
        let tc = min(max(0, t), lengthSec)
        for (i, p) in pieces.enumerated() {
            if tc < cursor + p.lengthSec || i == pieces.count - 1 {
                return (i, p.startSec + min(p.lengthSec, tc - cursor))
            }
            cursor += p.lengthSec
        }
        return nil
    }

    /// A clip range on the recording. A range running across a cut ends where its first piece ends (the rest is
    /// dead time that was never sent).
    func recordingRange(_ a: Double, _ b: Double) -> (start: Double, end: Double)? {
        guard let s = locate(a), let e = locate(b) else { return nil }
        if e.piece != s.piece { return (s.recSec, pieces[s.piece].endSec) }
        return (s.recSec, e.recSec)
    }
}

/// "Claude · frames only": which instants to send as stills — evenly spaced over the clip (about one every 2 s, at most
/// 40 so it fits an upload), named by clip time so the reply's times line up with the video's.
enum RacketAIFrames {
    struct Frame: Equatable, Sendable {
        var clipSec: Double
        var recSec: Double
    }

    static let maxFrames = 40

    static func times(_ clip: RacketAIClip, everySec: Double = 2, max limit: Int = maxFrames) -> [Frame] {
        let len = clip.lengthSec
        guard len > 0, limit > 0 else { return [] }
        let step = Swift.max(everySec, len / Double(limit))
        var out: [Frame] = []
        var t = step / 2
        while t < len && out.count < limit {
            let clipSec = (t * 10).rounded() / 10
            if let at = clip.locate(clipSec) { out.append(Frame(clipSec: clipSec, recSec: at.recSec)) }
            t += step
        }
        return out
    }
}

// MARK: - Wire format (schema snappet.racket-analysis/1)

enum RacketAIWire {
    static let schema = "snappet.racket-analysis/1"

    static func sport(_ s: RacketSport) -> String {
        switch s {
        case .tableTennis: return "table_tennis"
        case .badminton: return "badminton"
        case .tennis: return "tennis"
        case .pickleball: return "pickleball"
        case .padel: return "padel"
        case .squash: return "squash"
        }
    }

    /// `doubleBounce` → `double_bounce`.
    static func name(_ e: RacketRallyEnding) -> String {
        var out = ""
        for c in e.rawValue {
            if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) }
        }
        return out
    }

    /// The sport's endings in the board's order, as wire names.
    static func endings(_ s: RacketSport) -> [String] { RacketRallyEnding.choices(for: s).map(name) }

    /// "Double-bounce", "double bounce", "DOUBLE_BOUNCE", "Let (replay)" → one key.
    static func normalize(_ word: String) -> String {
        let lowered = word.lowercased().replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
        let parts = lowered.split { !$0.isLetter && !$0.isNumber }
        return parts.joined(separator: "_")
    }

    /// An ending the sport knows (by wire name or label, any case / spacing), else `nil`.
    static func ending(_ word: String, sport: RacketSport) -> RacketRallyEnding? {
        let key = normalize(word)
        guard !key.isEmpty else { return nil }
        return RacketRallyEnding.choices(for: sport).first { name($0) == key || normalize($0.label) == key }
    }

    /// Words other apps use for an ending Snappet calls something else — offered as "Count it as …" (review5 low: the
    /// AI "long" mapping), never applied without the player's say.
    private static let synonyms: [String: [RacketRallyEnding]] = [
        "long": [.out], "wide": [.out], "out_of_bounds": [.out], "outside": [.out], "out_long": [.out], "out_wide": [.out],
        "overhit": [.out], "sideline": [.out], "baseline": [.out], "long_out": [.out],
        "netted": [.net, .tin], "into_net": [.net, .tin], "in_net": [.net, .tin], "hit_net": [.net, .tin],
        "into_the_net": [.net, .tin], "net_error": [.net, .tin],
        "two_bounces": [.doubleBounce, .notUp], "bounced_twice": [.doubleBounce, .notUp], "double_bounced": [.doubleBounce, .notUp],
        "ace": [.winner, .landedIn], "clean_winner": [.winner, .landedIn], "unreturned": [.winner, .landedIn],
        "kill": [.winner, .landedIn], "smash_winner": [.winner, .landedIn], "landed": [.landedIn, .winner],
        "fault": [.serveFault, .serviceFault, .doubleFault], "serve_error": [.serveFault, .serviceFault, .doubleFault],
        "service_error": [.serveFault, .serviceFault, .doubleFault], "foot_fault": [.serviceFault, .serveFault, .doubleFault],
        "let": [.letReplay], "replay": [.letReplay], "edge": [.edgeBall], "edge_hit": [.edgeBall],
        "miss": [.missedSwing, .missedShot], "whiff": [.missedSwing, .missedShot], "missed": [.missedSwing, .missedShot],
        "kitchen": [.kitchenFault], "nvz_fault": [.kitchenFault], "volley_in_kitchen": [.kitchenFault],
        "wall": [.hitWallFirst], "glass": [.hitWallFirst], "body": [.hitPlayer], "hit_body": [.hitPlayer],
        "interruption": [.interrupted], "stopped": [.interrupted], "board": [.tin], "tin_hit": [.tin],
    ]

    /// The sport's closest ending for an unknown word, or `nil` when there's no good guess.
    static func suggestion(_ word: String, sport: RacketSport) -> RacketRallyEnding? {
        let choices = RacketRallyEnding.choices(for: sport)
        if let list = synonyms[normalize(word)], let hit = list.first(where: choices.contains) { return hit }
        // A known ending this sport doesn't use (a tennis "winner" in table tennis): no guess.
        return nil
    }

    enum WinnerWord: String, Equatable, Sendable { case near, far, us, them }

    static func winner(_ word: String) -> WinnerWord? {
        let k = normalize(word)
        switch k {
        case "near", "near_side", "near_camera", "camera_side", "close", "front", "bottom", "near_player", "near_team":
            return .near
        case "far", "far_side", "far_camera", "back", "top", "far_player", "far_team", "opposite":
            return .far
        case "us", "you", "me", "player", "mine", "my_side", "our_side": return .us
        case "them", "opponent", "opponents", "other", "their_side": return .them
        default:
            if k.hasPrefix("near") { return .near }
            if k.hasPrefix("far") { return .far }
            return nil
        }
    }

    static func winner(_ w: WinnerWord, side: RacketAISide) -> RacketRallyWinner {
        switch w {
        case .us: return .us
        case .them: return .them
        case .near: return side == .near ? .us : .them
        case .far: return side == .far ? .us : .them
        }
    }
}

// MARK: - Times ("75", "75s", "1:15", "1:01:15", "1:02.5")

enum RacketAITime {
    static func seconds(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber:
            // JSON booleans are NSNumbers too.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String: return seconds(s)
        default: return nil
        }
    }

    static func seconds(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        for suffix in ["seconds", "second", "secs", "sec", "s"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // "1m 05s" / "1m5"
        if let m = s.range(of: #"^(\d+)\s*m(?:in)?\s*(\d+(?:\.\d+)?)?$"#, options: .regularExpression) {
            let body = String(s[m])
            let nums = body.split { !$0.isNumber && $0 != "." }.compactMap { Double($0) }
            guard let mins = nums.first else { return nil }
            return mins * 60 + (nums.count > 1 ? nums[1] : 0)
        }
        if s.contains(":") {
            let comps = s.split(separator: ":", omittingEmptySubsequences: false).map { String($0) }
            guard (2...3).contains(comps.count), let last = Double(comps.last!), last >= 0, last < 60
            else { return nil }
            let heads = comps.dropLast().map { Int($0) }
            guard heads.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
            let h = heads.compactMap { $0 }
            if h.count == 1 { return Double(h[0]) * 60 + last }
            guard h[1] < 60 else { return nil }
            return Double(h[0]) * 3600 + Double(h[1]) * 60 + last
        }
        guard let d = Double(s), d.isFinite else { return nil }
        return d
    }
}

// MARK: - The prompt (TtAIPrompt)

enum RacketAIPrompt {
    /// The editable part: the board's first two lines.
    static func defaultBody(_ sport: RacketSport) -> String {
        """
        You are analyzing a \(sport.label.lowercased()) video from Snappet.
        Find every rally. For each one, give start and end in seconds, who won (near or far side of the camera), how it ended, and each shot if you can.
        """
    }

    /// The board's example reply line (its ending is the sport's second chip, as on every board).
    static func exampleJSON(_ sport: RacketSport) -> String {
        let endings = RacketAIWire.endings(sport)
        let e = endings.count > 1 ? endings[1] : endings.first ?? "out"
        return #"{"sport":"\#(RacketAIWire.sport(sport))","analyzer":{"app":"","model":""},"rallies":[{"start_s":0,"end_s":0,"winner":"near","ending":"\#(e)","shots":[{"t_s":0,"side":"near","stroke":"forehand"}],"confidence":0.0}]}"#
    }

    /// The fixed part (can't be edited or removed): which video this is, the allowed endings, the JSON format line.
    static func fixedTail(sport: RacketSport, clip: RacketAIClip, title: String, framesOnly: Bool) -> String {
        let len = clip.lengthSec
        let secs = Int(len.rounded())
        var lines: [String] = []
        let range = clip.pieces.isEmpty ? "" : ", \(RacketVideoTime.clock(clip.pieces[0].startSec))–\(RacketVideoTime.clock(clip.pieces[clip.pieces.count - 1].endSec)) of the recording"
        lines.append("This video is \(RacketVideoTime.clock(len)) long (\(secs) seconds): \(title)\(range).")
        lines.append("Give every time in seconds from the start of this video, between 0 and \(secs).")
        if clip.pieces.count > 1 {
            lines.append("It joins \(clip.pieces.count) stretches of play with the dead time cut out, so times run straight through.")
        }
        if framesOnly {
            lines.append("You have still frames instead of the video. Each file name ends with its time in seconds, for example frame-0012.5s.jpg.")
        }
        lines.append("Use only these endings: \(RacketAIWire.endings(sport).joined(separator: ", ")).")
        lines.append("Reply with JSON only, using schema \(RacketAIWire.schema):")
        lines.append(exampleJSON(sport))
        lines.append("Fill in analyzer with your app and model name. Say unknown when you are not sure.")
        return lines.joined(separator: "\n")
    }

    /// The prompt sent: your edited body (or the default) and the fixed tail. Same inputs, same text.
    static func build(sport: RacketSport, clip: RacketAIClip, title: String, framesOnly: Bool = false,
                      customBody: String? = nil) -> String {
        let custom = customBody?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (custom?.isEmpty == false ? custom! : defaultBody(sport))
        return body + "\n\n" + fixedTail(sport: sport, clip: clip, title: title, framesOnly: framesOnly)
    }

    /// Where edits are kept (per sport, "Edits are kept for next time").
    static func storageKey(_ sport: RacketSport) -> String { "racket.ai.prompt.\(sport.rawValue)" }
}

// MARK: - Reading a reply (TtAIImport)

/// One rally read from a reply, in the sent clip's seconds.
struct RacketAIParsedRally: Equatable, Sendable {
    /// 1-based, in the reply's order.
    var number: Int
    var startSec: Double
    var endSec: Double
    var winner: RacketAIWire.WinnerWord?
    /// The ending as written, when given.
    var endingWord: String?
    /// The ending when Snappet knows it for this sport.
    var ending: RacketRallyEnding?
    var shots: Int?
    var confidence: Double?
    /// An edge was moved into the video (a start before 0, an end past the end).
    var clamped = false

    var hasUnknownEnding: Bool { endingWord != nil && ending == nil }
}

struct RacketAIParseReport: Equatable, Sendable {
    enum Format: Equatable, Sendable { case json, table }

    enum SkipReason: Equatable, Sendable {
        case missingTimes
        case endsBeforeStart
        case tooShort
        case afterVideoEnds
        case overlaps(Int)
        case duplicate(Int)
        case tooMany

        var line: String {
            switch self {
            case .missingTimes: return "no start or end time"
            case .endsBeforeStart: return "ends before it starts"
            case .tooShort: return "too short for a rally"
            case .afterVideoEnds: return "starts after the video ends"
            case .overlaps(let n): return "overlaps rally \(n)"
            case .duplicate(let n): return "same as rally \(n)"
            case .tooMany: return "more rallies than Snappet reads at once"
            }
        }
    }

    struct Skip: Equatable, Sendable {
        var number: Int
        var reason: SkipReason
        var line: String { "Rally \(number): \(reason.line)" }
    }

    struct Unknown: Equatable, Sendable {
        var word: String
        var count: Int
        var suggestion: RacketRallyEnding?
    }

    var format: Format
    var rallies: [RacketAIParsedRally]
    var skipped: [Skip]
    var unknownEndings: [Unknown]
    var warnings: [String]
    var app: String?
    var model: String?
    var sport: String?

    var clampedCount: Int { rallies.filter(\.clamped).count }
}

enum RacketAIParseError: Error, Equatable, Sendable {
    case empty
    case nothingFound
    case noRallies

    var line: String {
        switch self {
        case .empty: return "There’s nothing to read yet. Copy the other app’s answer, then paste it here."
        case .nothingFound: return "Snappet couldn’t find rallies in this. Ask the app to reply with the JSON from the prompt."
        case .noRallies: return "The reply has no rallies in it."
        }
    }
}

enum RacketAIParser {
    static let maxRallies = 1000
    /// A start this far past the end is still "at the end" (rounding in the reply).
    static let endToleranceSec: Double = 1
    /// Two rallies overlapping by less than this just touch.
    static let overlapToleranceSec: Double = 0.25

    static func parse(_ text: String, sport: RacketSport, clipLengthSec: Double) -> Result<RacketAIParseReport, RacketAIParseError> {
        let clean = normalizeText(text)
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }

        var raws: [RawRally]?
        var meta = Meta()
        var format = RacketAIParseReport.Format.json
        var sawJSONWithoutRallies = false
        for candidate in jsonCandidates(clean) {
            guard let obj = parseJSON(candidate) else { continue }
            if let found = rallyArray(in: obj, depth: 0) {
                raws = found.compactMap(rawRally)
                meta = self.meta(obj)
                break
            }
            sawJSONWithoutRallies = true
        }
        if raws == nil {
            let rows = tableRows(clean, sport: sport)
            if !rows.isEmpty {
                raws = rows
                format = .table
            }
        }
        guard let raws else { return .failure(sawJSONWithoutRallies ? .noRallies : .nothingFound) }
        guard !raws.isEmpty else { return .failure(.noRallies) }
        var report = validate(raws, sport: sport, clipLengthSec: clipLengthSec)
        report.format = format
        report.app = meta.app
        report.model = meta.model
        report.sport = meta.sport
        if let s = meta.sport, RacketAIWire.normalize(s) != RacketAIWire.sport(sport),
           RacketAIWire.normalize(s) != RacketAIWire.normalize(sport.label) {
            report.warnings.append("The reply says it’s \(s.replacingOccurrences(of: "_", with: " ")); this is \(sport.label.lowercased()).")
        }
        if report.clampedCount > 0 {
            let n = report.clampedCount
            report.warnings.append("\(n) \(n == 1 ? "rally ran" : "rallies ran") past the video’s edges and \(n == 1 ? "was" : "were") trimmed to fit.")
        }
        return .success(report)
    }

    // MARK: Text clean-up

    /// Smart quotes from Notes / chat apps, a BOM, non-breaking spaces.
    static func normalizeText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{FEFF}", with: "")
        for (a, b) in [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""), ("\u{2033}", "\""),
                       ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{00A0}", " "), ("\u{2212}", "-")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    /// Code-fenced blocks first, then every balanced `{…}` / `[…]` in the text, in order.
    static func jsonCandidates(_ text: String) -> [String] {
        var out: [String] = []
        let fence = try? NSRegularExpression(pattern: "```[a-zA-Z0-9_-]*[ \\t]*\\n?([\\s\\S]*?)```")
        let ns = text as NSString
        for m in fence?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] where m.numberOfRanges > 1 {
            let body = ns.substring(with: m.range(at: 1))
            out.append(contentsOf: balanced(body))
        }
        out.append(contentsOf: balanced(text))
        return out
    }

    /// Balanced JSON-looking spans, outermost first, skipping brackets inside strings.
    static func balanced(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var i = 0
        while i < chars.count && out.count < 20 {
            guard chars[i] == "{" || chars[i] == "[" else { i += 1; continue }
            var depth = 0
            var inString: Character?
            var escaped = false
            var j = i
            var closed = false
            while j < chars.count {
                let c = chars[j]
                if let q = inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == q { inString = nil }
                } else if c == "\"" {
                    inString = c
                } else if c == "{" || c == "[" {
                    depth += 1
                } else if c == "}" || c == "]" {
                    depth -= 1
                    if depth == 0 { closed = true; break }
                }
                j += 1
            }
            if closed {
                out.append(String(chars[i...j]))
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    static func parseJSON(_ s: String) -> Any? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed, .fragmentsAllowed])
    }

    // MARK: JSON shape

    private struct Meta { var app: String?; var model: String?; var sport: String? }

    private static func meta(_ obj: Any) -> Meta {
        guard let d = obj as? [String: Any] else { return Meta() }
        let keyed = normalizedKeys(d)
        var m = Meta()
        m.sport = (keyed["sport"] as? String).flatMap(nonEmpty)
        if let a = keyed["analyzer"] as? [String: Any] {
            let ak = normalizedKeys(a)
            m.app = (ak["app"] as? String ?? ak["name"] as? String).flatMap(nonEmpty)
            m.model = (ak["model"] as? String ?? ak["version"] as? String).flatMap(nonEmpty)
        } else if let a = keyed["analyzer"] as? String {
            m.app = nonEmpty(a)
        }
        m.model = m.model ?? (keyed["model"] as? String).flatMap(nonEmpty)
        return m
    }

    /// "", "unknown", "n/a" → nil.
    static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", "unknown", "n/a", "na", "none", "not sure", "null"].contains(t.lowercased()) ? nil : t
    }

    private static func normalizedKeys(_ d: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in d { out[k.lowercased().filter { $0.isLetter || $0.isNumber }] = v }
        return out
    }

    private static let rallyKeys = ["rallies", "rally", "points", "results", "items", "data", "segments", "events"]

    private static func rallyArray(in obj: Any, depth: Int) -> [Any]? {
        if let a = obj as? [Any] {
            return a.contains(where: { $0 is [String: Any] }) || a.isEmpty ? a : nil
        }
        guard let d = obj as? [String: Any], depth < 4 else { return nil }
        let keyed = normalizedKeys(d)
        for k in rallyKeys { if let a = keyed[k] as? [Any] { return a } }
        for (_, v) in d where v is [String: Any] { if let a = rallyArray(in: v, depth: depth + 1) { return a } }
        return nil
    }

    struct RawRally: Equatable, Sendable {
        var start: Double?
        var end: Double?
        var winner: RacketAIWire.WinnerWord?
        var endingWord: String?
        var shots: Int?
        var confidence: Double?
    }

    private static let startKeys = ["starts", "start", "startsec", "startseconds", "starttime", "from", "begin", "t0", "begins"]
    private static let endKeys = ["ends", "end", "endsec", "endseconds", "endtime", "to", "finish", "stop", "t1", "endings"]
    private static let winnerKeys = ["winner", "won", "wonby", "pointto", "pointwinner", "who", "side", "winningside"]
    private static let endingKeys = ["ending", "endreason", "how", "outcome", "result", "reason", "howitended", "endtype", "ended"]

    private static func rawRally(_ any: Any) -> RawRally? {
        guard let d = any as? [String: Any] else { return nil }
        let k = normalizedKeys(d)
        var r = RawRally()
        r.start = startKeys.lazy.compactMap { RacketAITime.seconds(k[$0]) }.first
        r.end = endKeys.lazy.compactMap { RacketAITime.seconds(k[$0]) }.first
        if r.start == nil || r.end == nil, let span = (k["time"] ?? k["range"] ?? k["timestamp"]) as? String {
            let times = timeTokens(span)
            if times.count >= 2 { r.start = r.start ?? times[0]; r.end = r.end ?? times[1] }
        }
        if r.end == nil, let s = r.start,
           let dur = ["durations", "duration", "durationsec", "length", "lengths"].lazy.compactMap({ RacketAITime.seconds(k[$0]) }).first {
            r.end = s + dur
        }
        r.winner = winnerKeys.lazy.compactMap { key in (k[key] as? String).flatMap { RacketAIWire.winner($0) } }.first
        r.endingWord = endingKeys.lazy.compactMap { (k[$0] as? String).flatMap(nonEmpty) }.first
        if let shots = k["shots"] as? [Any] { r.shots = shots.count }
        else if let n = (k["shots"] ?? k["shotcount"] ?? k["numshots"]) as? NSNumber { r.shots = n.intValue }
        if let c = k["confidence"] as? NSNumber {
            let v = c.doubleValue
            r.confidence = v > 1 ? min(1, v / 100) : max(0, v)
        }
        return r
    }

    // MARK: A pasted table or list

    /// Times in a line: "0:12", "1:02:03", "12.5s", "12 s", or bare numbers.
    static func timeTokens(_ line: String) -> [Double] {
        let pattern = #"(\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?|\d+(?:\.\d+)?\s*(?:s|sec|secs|seconds)\b)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = line as NSString
        return re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            .compactMap { RacketAITime.seconds(ns.substring(with: $0.range)) }
    }

    private static func bareNumbers(_ line: String) -> [Double] {
        guard let re = try? NSRegularExpression(pattern: #"(?<![\w.])(?<!\d:)\d+(?:\.\d+)?(?![\w.])(?!:\d)"#) else { return [] }
        let ns = line as NSString
        return re.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { Double(ns.substring(with: $0.range)) }
    }

    /// Lines with two times (and optionally near / far and an ending) — a Markdown table, a CSV or a list.
    static func tableRows(_ text: String, sport: RacketSport) -> [RawRally] {
        var rows: [RawRally] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " -:")).isEmpty { continue }
            var times = timeTokens(line)
            if times.count < 2 {
                // "1 | 12.0 | 19.5 | near | net": a leading rally number, then the two times.
                var nums = bareNumbers(line)
                let lead = line.trimmingCharacters(in: CharacterSet(charactersIn: " |#*-")).lowercased()
                if nums.count >= 3 || lead.hasPrefix("rally") { nums = Array(nums.dropFirst()) }
                guard nums.count >= 2 else { continue }
                times = Array(nums.prefix(2))
            }
            var r = RawRally(start: times[0], end: times[1])
            let words = line.split { !$0.isLetter && $0 != "_" && $0 != "-" }.map(String.init)
            r.winner = words.lazy.compactMap { w -> RacketAIWire.WinnerWord? in
                let k = w.lowercased()
                return k == "near" ? .near : k == "far" ? .far : nil
            }.first
            r.endingWord = endingWord(in: words, sport: sport)
            rows.append(r)
        }
        return rows
    }

    /// The first 1–3 word run that's one of the sport's endings ("double bounce", "Serve fault").
    private static func endingWord(in words: [String], sport: RacketSport) -> String? {
        for n in [3, 2, 1] where words.count >= n {
            for i in 0...(words.count - n) {
                let run = words[i..<(i + n)].joined(separator: " ")
                if RacketAIWire.ending(run, sport: sport) != nil { return run }
            }
        }
        return nil
    }

    // MARK: Validation

    static func validate(_ raws: [RawRally], sport: RacketSport, clipLengthSec L: Double) -> RacketAIParseReport {
        var kept: [RacketAIParsedRally] = []
        var skipped: [RacketAIParseReport.Skip] = []
        var candidates: [RacketAIParsedRally] = []
        for (i, raw) in raws.enumerated() {
            let n = i + 1
            if i >= maxRallies { skipped.append(.init(number: n, reason: .tooMany)); continue }
            guard let s0 = raw.start, let e0 = raw.end else { skipped.append(.init(number: n, reason: .missingTimes)); continue }
            if e0 < s0 { skipped.append(.init(number: n, reason: .endsBeforeStart)); continue }
            if s0 >= L + endToleranceSec - 0.0001 { skipped.append(.init(number: n, reason: .afterVideoEnds)); continue }
            let s = max(0, s0), e = min(L, e0)
            if e - s < RacketRallyMarking.minRallySec { skipped.append(.init(number: n, reason: .tooShort)); continue }
            var p = RacketAIParsedRally(number: n, startSec: s, endSec: e, winner: raw.winner, endingWord: raw.endingWord,
                                        ending: raw.endingWord.flatMap { RacketAIWire.ending($0, sport: sport) },
                                        shots: raw.shots, confidence: raw.confidence)
            p.clamped = s != s0 || e != e0
            candidates.append(p)
        }
        for p in candidates.sorted(by: { $0.startSec != $1.startSec ? $0.startSec < $1.startSec : $0.number < $1.number }) {
            if let prev = kept.last, p.startSec < prev.endSec - overlapToleranceSec {
                let same = abs(p.startSec - prev.startSec) <= overlapToleranceSec && abs(p.endSec - prev.endSec) <= overlapToleranceSec
                skipped.append(.init(number: p.number, reason: same ? .duplicate(prev.number) : .overlaps(prev.number)))
                continue
            }
            kept.append(p)
        }
        var unknown: [RacketAIParseReport.Unknown] = []
        for p in kept where p.hasUnknownEnding {
            let w = p.endingWord!
            if let i = unknown.firstIndex(where: { RacketAIWire.normalize($0.word) == RacketAIWire.normalize(w) }) {
                unknown[i].count += 1
            } else {
                unknown.append(.init(word: w, count: 1, suggestion: RacketAIWire.suggestion(w, sport: sport)))
            }
        }
        return RacketAIParseReport(format: .json, rallies: kept, skipped: skipped.sorted { $0.number < $1.number },
                                   unknownEndings: unknown, warnings: [], app: nil, model: nil, sport: nil)
    }
}

// MARK: - Turning a reply into rallies (TtAIImport "Import")

enum RacketAIImportBuilder {
    /// What to do with rallies that used an ending Snappet doesn't know (AIImport "Count it as Out" / "Leave them out").
    enum EndingChoice: Equatable, Sendable {
        case countAs(RacketRallyEnding)
        case leaveOut
    }

    /// The default for each unknown word: its suggestion, else leave those rallies out.
    static func defaultChoices(_ report: RacketAIParseReport) -> [String: EndingChoice] {
        var out: [String: EndingChoice] = [:]
        for u in report.unknownEndings { out[RacketAIWire.normalize(u.word)] = u.suggestion.map(EndingChoice.countAs) ?? .leaveOut }
        return out
    }

    struct Counts: Equatable, Sendable {
        var read: Int
        var skipped: Int
        /// "Read 21 rallies".
        var readLine: String { "Read \(read) \(read == 1 ? "rally" : "rallies")" }
        var skippedLine: String? { skipped > 0 ? "\(skipped) skipped" : nil }
    }

    static func counts(_ report: RacketAIParseReport, choices: [String: EndingChoice]) -> Counts {
        let left = report.rallies.filter { r in
            guard r.hasUnknownEnding else { return false }
            return (choices[RacketAIWire.normalize(r.endingWord!)] ?? .leaveOut) == .leaveOut
        }.count
        return Counts(read: report.rallies.count - left, skipped: report.skipped.count + left)
    }

    /// "Two rallies used an ending Snappet doesn’t know: “long”."
    static func unknownLine(_ u: RacketAIParseReport.Unknown) -> String {
        let n = u.count == 1 ? "One rally" : u.count == 2 ? "Two rallies" : "\(u.count) rallies"
        return "\(n) used an ending Snappet doesn’t know: “\(u.word)”."
    }

    /// The reply's rallies on the recording's timeline, labelled with where they came from. Never touches your rallies.
    static func rallies(_ report: RacketAIParseReport, choices: [String: EndingChoice], clip: RacketAIClip,
                        side: RacketAISide, source: String) -> [RacketRally] {
        var out: [RacketRally] = []
        for p in report.rallies {
            var ending = p.ending
            if p.hasUnknownEnding {
                switch choices[RacketAIWire.normalize(p.endingWord!)] ?? .leaveOut {
                case .leaveOut: continue
                case .countAs(let e): ending = e
                }
            }
            guard let range = clip.recordingRange(p.startSec, p.endSec),
                  range.end - range.start >= RacketRallyMarking.minRallySec else { continue }
            var r = RacketRally(startSec: range.start, endSec: range.end,
                                winner: p.winner.map { RacketAIWire.winner($0, side: side) }, ending: ending)
            r.sourceRaw = source
            r.tagSourceRaw = source
            r.aiShots = p.shots
            out.append(r)
        }
        return out.sorted { $0.startSec < $1.startSec }
    }
}

// MARK: - What was sent and brought back (stored on the recording log)

/// One send (AISend): which part, what was sent and to which app. The import reads its clip to map times back.
struct RacketAIRequest: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var appRaw: String
    var kindRaw: String
    var sentAt: Date
    var partStart: Double
    var partEnd: Double
    var clip: RacketAIClip

    var app: RacketAIApp { RacketAIApp(rawValue: appRaw) ?? .other }
}

/// One reply brought back. Its rallies are suggestions (dashed, labelled) until compared; then the picked items move
/// into the recording's rallies and the import is marked reviewed.
struct RacketAIImport: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var appRaw: String
    /// The label shown: "ChatGPT", or what an "Other apps" reply reported.
    var appName: String
    var model: String?
    var importedAt: Date
    var partStart: Double
    var partEnd: Double
    var rallies: [RacketRally]
    var reviewed: Bool?
    /// Items accepted on Compare.
    var accepted: Int?

    var source: String { RacketAISource.raw(appName) }
    var isPending: Bool { reviewed != true }
}

extension RacketRecordingLog {
    var allAIRequests: [RacketAIRequest] { aiRequests ?? [] }
    var allAIImports: [RacketAIImport] { aiImports ?? [] }

    /// The last send of exactly this part (to map its reply's times back), if any.
    func lastAIRequest(partStart lo: Double, partEnd hi: Double) -> RacketAIRequest? {
        allAIRequests.filter { abs($0.partStart - lo) < 0.5 && abs($0.partEnd - hi) < 0.5 }.max { $0.sentAt < $1.sentAt }
    }

    /// Imports waiting to be compared, for a part.
    func pendingAIImports(partStart lo: Double, partEnd hi: Double) -> [RacketAIImport] {
        allAIImports.filter { $0.isPending && $0.partStart < hi - 0.01 && $0.partEnd > lo + 0.01 }
    }

    /// Suggested rallies inside a part (from imports not compared yet), labelled.
    func aiSuggestions(partStart lo: Double, partEnd hi: Double) -> [RacketRally] {
        RacketRallyMarking.inRange(pendingAIImports(partStart: lo, partEnd: hi).flatMap(\.rallies), lo, hi)
    }
}

// MARK: - Compare (TtAICompare) and merge

struct RacketAICompareItem: Equatable, Identifiable, Sendable {
    enum Field: String, Equatable, Sendable { case rally, winner, ending, notRally }

    var id: String { "\(aiID)-\(field.rawValue)" }
    var aiID: UUID
    var yourID: UUID?
    var field: Field
    /// 1-based, the reply's rally in time order.
    var number: Int
    /// "Rally 4 · winner".
    var title: String
    var yours: String
    var theirs: String
    /// Your rally had this tagged by you: "Use <app> for all" leaves it; only a pick for this item changes it.
    var protected: Bool
}

struct RacketAICompareResult: Equatable, Sendable {
    var items: [RacketAICompareItem]
    /// Rallies in the reply.
    var total: Int
    /// Rallies where the app agrees with you (or adds nothing new).
    var matching: Int

    /// "18 of 21 match".
    var matchLine: String { "\(matching) of \(total) match" }
    /// "3 disagreements".
    var disagreementLine: String {
        items.isEmpty ? "No disagreements" : "\(items.count) \(items.count == 1 ? "disagreement" : "disagreements")"
    }
}

enum RacketAICompare {
    enum Pick: String, Equatable, Sendable { case yours, theirs }

    /// Overlap over union.
    static func iou(_ a: RacketRally, _ b: RacketRally) -> Double {
        let inter = max(0, min(a.endSec, b.endSec) - max(a.startSec, b.startSec))
        let union = max(a.endSec, b.endSec) - min(a.startSec, b.startSec)
        return union > 0 ? inter / union : 0
    }

    static func sameRally(_ a: RacketRally, _ b: RacketRally) -> Bool {
        let midA = (a.startSec + a.endSec) / 2, midB = (b.startSec + b.endSec) / 2
        return iou(a, b) >= 0.3 || (midA >= b.startSec && midA < b.endSec) || (midB >= a.startSec && midB < a.endSec)
    }

    /// One-to-one pairs of AI rally → your rally, best overlap first.
    static func pairs(ai: [RacketRally], yours: [RacketRally]) -> [UUID: UUID] {
        var cands: [(Double, UUID, UUID)] = []
        for a in ai { for y in yours where sameRally(a, y) { cands.append((iou(a, y), a.id, y.id)) } }
        cands.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.uuidString < $1.1.uuidString }
        var out: [UUID: UUID] = [:]
        var used = Set<UUID>()
        for (_, a, y) in cands where out[a] == nil && !used.contains(y) {
            out[a] = y
            used.insert(y)
        }
        return out
    }

    private static func winnerText(_ w: RacketRallyWinner?, sides: (us: String, them: String)) -> String? {
        w.map { $0 == .us ? "\(sides.us) won" : "\(sides.them) won" }
    }

    /// Your rallies (in the part) against the reply's.
    static func build(ai: [RacketRally], yours: [RacketRally], appName: String,
                      sides: (us: String, them: String)) -> RacketAICompareResult {
        let ais = ai.sorted { $0.startSec < $1.startSec }
        let byID = Dictionary(yours.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pairs = self.pairs(ai: ais, yours: yours)
        var items: [RacketAICompareItem] = []
        var matching = 0
        for (k, a) in ais.enumerated() {
            let n = k + 1
            func item(_ f: RacketAICompareItem.Field, _ label: String, yourID: UUID?, _ y: String, _ t: String, protected: Bool) {
                items.append(.init(aiID: a.id, yourID: yourID, field: f, number: n, title: "Rally \(n) · \(label)",
                                   yours: "Yours: \(y)", theirs: "\(appName): \(t)", protected: protected))
            }
            guard let yid = pairs[a.id], let y = byID[yid] else {
                let shots = a.aiShots.map { ", \($0) \($0 == 1 ? "shot" : "shots")" } ?? ""
                item(.rally, "is it a rally?", yourID: nil, "Not marked", "Yes" + shots, protected: false)
                continue
            }
            let byYou = !RacketAISource.isAI(y.tagSourceRaw)
            if !y.isRally {
                item(.notRally, "is it a rally?", yourID: yid, "Not a rally", "Yes", protected: byYou)
                continue
            }
            var disagrees = false
            if let aw = a.winner, aw != y.winner, y.ending?.isReplay != true {
                let mine = winnerText(y.winner, sides: sides)
                item(.winner, "winner", yourID: yid, mine ?? "Not tagged", winnerText(aw, sides: sides)!,
                     protected: mine != nil && byYou)
                disagrees = true
            }
            if let ae = a.ending, ae != y.ending {
                item(.ending, "ending", yourID: yid, y.ending?.label ?? "Not tagged", ae.label, protected: y.ending != nil && byYou)
                disagrees = true
            }
            if !disagrees { matching += 1 }
        }
        return RacketAICompareResult(items: items, total: ais.count, matching: matching)
    }

    /// Every item starts on yours (Keep my choices).
    static func defaultPicks(_ r: RacketAICompareResult) -> [String: Pick] {
        Dictionary(r.items.map { ($0.id, Pick.yours) }, uniquingKeysWith: { a, _ in a })
    }

    /// "Use <app> for all": the app's answer on every item except what you tagged yourself.
    static func useAppForAll(_ r: RacketAICompareResult, current: [String: Pick]) -> [String: Pick] {
        var out = current
        for i in r.items where !i.protected { out[i.id] = .theirs }
        return out
    }
}

enum RacketAIMerge {
    struct Outcome: Equatable, Sendable {
        var rallies: [RacketRally]
        var accepted: Int
    }

    /// Apply the picked items to the recording's rallies. Only items picked "theirs" change anything; the changed tags
    /// say they came from the app.
    static func apply(_ result: RacketAICompareResult, picks: [String: RacketAICompare.Pick], yours: [RacketRally],
                      ai: [RacketRally], source: String) -> Outcome {
        var out = yours
        let aiByID = Dictionary(ai.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var accepted = 0
        for item in result.items where picks[item.id] == .theirs {
            guard let a = aiByID[item.aiID] else { continue }
            switch item.field {
            case .rally:
                guard !RacketRallyMarking.overlaps(a.startSec, a.endSec, out, except: nil) else { continue }
                var r = a
                r.sourceRaw = source
                r.tagSourceRaw = (a.winner != nil || a.ending != nil) ? source : nil
                out.append(r)
            case .winner, .ending, .notRally:
                guard let yid = item.yourID, let i = out.firstIndex(where: { $0.id == yid }) else { continue }
                if item.field == .notRally {
                    out[i].notRally = nil
                    out[i].winner = a.winner
                    out[i].ending = a.ending
                } else if item.field == .winner {
                    out[i].winner = a.winner
                } else {
                    out[i].ending = a.ending
                }
                out[i].tagSourceRaw = source
            }
            accepted += 1
        }
        return Outcome(rallies: out.sorted { $0.startSec < $1.startSec }, accepted: accepted)
    }

    /// Mark an import reviewed once compared.
    static func review(_ imports: [RacketAIImport], id: UUID, accepted: Int) -> [RacketAIImport] {
        imports.map { i in
            guard i.id == id else { return i }
            var q = i
            q.reviewed = true
            q.accepted = accepted
            return q
        }
    }
}
