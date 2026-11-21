import Foundation
import Observation

/// The clips that are not on this phone, as of the last `MediaLinkService` pass (cloud-connect P1b,
/// prompt 266). In memory only: it is re-derived on every launch / foreground, so there is no stored
/// "missing" flag to go stale when the footage comes back.
@MainActor
@Observable
final class MediaLinkStatus {
    var missing: [MissingClip] = []

    var missingIDs: Set<UUID> { Set(missing.map(\.id)) }
}
