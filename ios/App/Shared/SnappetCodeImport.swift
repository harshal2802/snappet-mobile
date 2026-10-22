import Foundation

/// **Which QR code in a photo is ours** (prompt 201) — shared by the in-app scanners' "Choose from Photos" and the
/// "Share → Snappet" extension. A photo can hold several codes (a poster, a screenshot of a chat); the first one this
/// screen can open wins, else the first Snappet link of another kind (the app routes it), else why not. Pure — the
/// pixels → strings step is `QRImageDecoder`.
enum SnappetCodeImport {
    enum Outcome<Value> {
        /// A code this screen opens (a climb in the climb scanner).
        case value(Value)
        /// A Snappet link of another kind (a routine in the climb scanner) — in its `snappet://` form.
        case otherLink(String)
        case failure(Failure)
    }

    enum Failure: Error, Equatable {
        case noCode
        case notSnappet

        var message: String {
            switch self {
            case .noCode: "No QR code found in that photo. Try a sharper screenshot of the code."
            case .notSnappet: "That photo has a QR code, but it isn't a Snappet code."
            }
        }
    }

    static func pick<Value>(_ payloads: [String], decode: (String) -> Value?) -> Outcome<Value> {
        guard !payloads.isEmpty else { return .failure(.noCode) }
        if let v = payloads.lazy.compactMap(decode).first { return .value(v) }
        if let link = payloads.lazy.compactMap(snappetLink).first { return .otherLink(link) }
        return .failure(.notSnappet)
    }

    /// The string as a `snappet://` link when it's one of ours (either form), else nil.
    static func snappetLink(_ string: String) -> String? {
        let app = SnappetWebLink.appForm(string)
        guard let c = URLComponents(string: app), c.scheme?.lowercased() == "snappet",
              let host = c.host, !host.isEmpty else { return nil }
        return app
    }

    /// What a Snappet link opens, in words ("a Kilter climb") — the share sheet's confirmation line.
    static func describe(_ link: String) -> String {
        let host = URLComponents(string: SnappetWebLink.appForm(link))?.host?.lowercased() ?? ""
        switch host {
        case "kilter": return "a Kilter climb"
        case "routine": return "a workout routine"
        case "festival": return "a festival lineup"
        case "household": return "a household invite"
        case "quick": return "a Quick Session"
        case "log": return "a set to log"
        case "attempt": return "a climb attempt"
        case "finish": return "finishing your workout"
        case "exercise": return "an exercise"
        case "pomodoro": return "a focus timer"
        default: return "a Snappet link"
        }
    }
}
