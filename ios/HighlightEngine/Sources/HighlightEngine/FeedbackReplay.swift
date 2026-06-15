import Foundation

/// Pure, on-device port of the offline feedback-replay tuner
/// (`experiments/feedback-replay/replay.py`). Replays logged `HighlightFeedbackEvent`s into
/// per-`(selector, configFingerprint)` quality metrics, so the app can re-weight the fusion blend
/// from the user's OWN feedback — the moat loop ("using the app improves the app"), fully on device.
///
/// PLATFORM-FREE + deterministic → runs in `swift test`, no device. Mirrors `replay.py` field-for-field
/// and is **parity-tested** against that harness's golden output (`FeedbackReplayParityTests`), so the
/// offline analysis and the on-device re-weighting can never silently diverge.
public enum FeedbackReplay {

    /// Per-config quality metrics. `key` is `"selectorName | configFingerprint"` — the unit we compare.
    public struct ConfigStats: Sendable, Equatable {
        public let key: String
        public var shown = 0, kept = 0, removed = 0, pinned = 0, exported = 0, regenerated = 0, added = 0
        /// effort_mix bookkeeping: of the highlights the user *endorsed* (pinned/exported), how many
        /// were "high" (effort) vs "low" (recovery/scenic)?
        public var endorsedHigh = 0, endorsedTotal = 0

        public init(key: String) { self.key = key }

        public var keepRate: Double { shown > 0 ? Double(kept) / Double(shown) : 0 }
        public var removalRate: Double { shown > 0 ? Double(removed) / Double(shown) : 0 }
        public var pinRate: Double { shown > 0 ? Double(pinned) / Double(shown) : 0 }
        public var exportSurvivorship: Double { shown > 0 ? Double(exported) / Double(shown) : 0 }
        public var regenPerShown: Double { shown > 0 ? Double(regenerated) / Double(shown) : 0 }

        /// Empirical effort_mix: share of endorsed moments that were effort (high) — exactly the unknown
        /// the efficacy spike had to *assume*.
        public var effortMix: Double { endorsedTotal > 0 ? Double(endorsedHigh) / Double(endorsedTotal) : 0 }

        /// A single 0…1-ish score. Positive signals (keep/pin/export) minus negative (remove, and
        /// regenerate as a weak whole-set negative). Pins weighted highest — the strongest explicit
        /// positive (#60 §E). Mirrors `ConfigStats.satisfaction` in replay.py exactly.
        public var satisfaction: Double {
            let s = 0.4 * keepRate
                + 0.9 * pinRate
                + 0.7 * exportSurvivorship
                - 0.6 * removalRate
                - 0.3 * regenPerShown
            return max(0, s)
        }
    }

    /// Replay events into per-config stats. Order-independent (pure accumulation), like the Python.
    public static func replay(_ events: [HighlightFeedbackEvent]) -> [String: ConfigStats] {
        var stats: [String: ConfigStats] = [:]
        for e in events {
            let key = "\(e.selectorName) | \(e.configFingerprint)"
            var st = stats[key] ?? ConfigStats(key: key)
            switch e.action {
            case .shown:       st.shown += 1
            case .kept:        st.kept += 1
            case .removed:     st.removed += 1
            case .pinned:      st.pinned += 1;      endorse(&st, e)
            case .exported:    st.exported += 1;    endorse(&st, e)
            case .regenerated: st.regenerated += 1
            case .added:       st.added += 1
            case .reordered:   break   // not scored (matches replay.py — no branch)
            }
            stats[key] = st
        }
        return stats
    }

    private static func endorse(_ st: inout ConfigStats, _ e: HighlightFeedbackEvent) {
        guard let kind = e.highlightKind else { return }
        st.endorsedTotal += 1
        if kind == .high { st.endorsedHigh += 1 }
    }

    /// Human-readable tuning direction — mirrors `recommend()` in replay.py (thresholds + copy).
    /// The app uses `tunedWeighting(from:)` for the actual numeric re-weight; this is the explainer.
    public static func recommend(_ stats: [String: ConfigStats]) -> String {
        guard let best = ranked(stats).first else {
            return "No data — use the app to generate feedback first."
        }
        var lines = ["Best config so far: **\(best.key)** (satisfaction \(fmt(best.satisfaction)))."]
        let mix = best.effortMix
        if best.endorsedTotal >= 5 {
            if mix >= 0.6 {
                lines.append("Empirical effort_mix ≈ \(fmt(mix)) → users endorse mostly EFFORT moments: "
                    + "lean the selector HR-heavy (raise wLevel/wSlope share).")
            } else if mix <= 0.4 {
                lines.append("Empirical effort_mix ≈ \(fmt(mix)) → users endorse mostly NON-effort moments: "
                    + "a content/scene signal matters — push the fusion toward scene.")
            } else {
                lines.append("Empirical effort_mix ≈ \(fmt(mix)) → mixed; a balanced HR+scene fusion fits.")
            }
        } else {
            lines.append("Not enough endorsed highlights yet to estimate effort_mix (need ≥5).")
        }
        if best.regenPerShown > 0.15 {
            lines.append("High regenerate rate → the default cut is missing; widen maxHighlights or retune scoring.")
        }
        return lines.joined(separator: "\n")
    }

    /// Configs ranked by satisfaction (desc); ties broken by `key` for determinism.
    public static func ranked(_ stats: [String: ConfigStats]) -> [ConfigStats] {
        stats.values.sorted {
            $0.satisfaction != $1.satisfaction ? $0.satisfaction > $1.satisfaction : $0.key < $1.key
        }
    }

    /// A replay-derived fusion weighting. The ONLY sanctioned way the HR-vs-scene blend changes
    /// (project.md: "weights change only from replayed feedback data"). `nil` ⇒ not enough endorsed
    /// data yet ⇒ callers keep their gated defaults (no change from intuition, ever).
    public struct TunedWeighting: Sendable, Equatable {
        public let hrWeight: Double
        public let sceneWeight: Double
        /// Why these weights — the config + effort_mix they were derived from (for decisions.md / logs).
        public let basis: String
    }

    /// Derive HR-vs-scene fusion weights from the best config's empirical `effort_mix`: the share of
    /// endorsed moments that were effort (HR-driven) peaks. High share ⇒ HR predicts well ⇒ weight HR;
    /// low share ⇒ scene/content matters ⇒ weight scene. Both clamped to `[0.2, 0.8]` so the fusion
    /// never collapses to a single signal (the "don't hardwire HR-only" rule). Returns `nil` until
    /// `minEndorsed` endorsements exist — so weights change ONLY once real replayed feedback supports it.
    public static func tunedWeighting(from stats: [String: ConfigStats],
                                      minEndorsed: Int = 5) -> TunedWeighting? {
        guard let best = ranked(stats).first, best.endorsedTotal >= minEndorsed else { return nil }
        let mix = best.effortMix
        let hr = min(0.8, max(0.2, mix))
        return TunedWeighting(hrWeight: hr, sceneWeight: 1 - hr,
                              basis: "effort_mix \(fmt(mix)) over \(best.endorsedTotal) endorsed (\(best.key))")
    }

    /// Match Python's `f"{x:.2f}"` for the recommendation copy (parity with run.py text).
    private static func fmt(_ x: Double) -> String { String(format: "%.2f", x) }
}
