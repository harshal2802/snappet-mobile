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

    /// `directory` nil = Application Support (the person's log).
    init(filename: String = "highlight-feedback.jsonl", directory: URL? = nil) {
        let dir = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                             in: .userDomainMask, appropriateFor: nil, create: true))
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        self.url = (dir ?? FileManager.default.temporaryDirectory).appendingPathComponent(filename)
    }

    /// How the app builds its store for these arguments (prompt 320). A test launch reads and appends to an emptied
    /// scratch log, never the person's: on 2026-11-26 device runs of the Clips month reel and the progress reel
    /// appended 8 "shown" rows to it, and the reel builder tunes itself from that log.
    static func make(arguments: [String]) -> FeedbackStore {
        guard UITestStore.isTestLaunch(arguments) else { return FeedbackStore() }
        let scratch = TestLaunchFiles.scratchRoot.appendingPathComponent("feedback", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        return FeedbackStore(directory: scratch)
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
