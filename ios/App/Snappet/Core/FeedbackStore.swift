import Foundation
import HighlightEngine

/// On-device sink for highlight feedback — the training data that lets us tune the
/// algorithm later (#60 §E). Appends one JSON object per line to a file in
/// Application Support. Stays on device (privacy); exportable with consent.
///
/// `FeedbackSink.record` may be called from any thread, so writes are serialized.
final class FeedbackStore: FeedbackSink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.snappet.feedback")
    private let url: URL
    private let encoder = JSONEncoder()

    init(filename: String = "highlight-feedback.jsonl") {
        let dir = try? FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        self.url = (dir ?? FileManager.default.temporaryDirectory).appendingPathComponent(filename)
    }

    func record(_ event: HighlightFeedbackEvent) {
        queue.async { [url, encoder] in
            guard let data = try? encoder.encode(event) else { return }
            var line = data
            line.append(0x0A) // newline
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }

    /// Read everything back (for an on-device "export my data" / offline tuning).
    func exportAll() -> [HighlightFeedbackEvent] {
        queue.sync {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            return text.split(separator: "\n").compactMap {
                try? decoder.decode(HighlightFeedbackEvent.self, from: Data($0.utf8))
            }
        }
    }

    var fileURL: URL { url }
}
