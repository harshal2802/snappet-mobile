import Foundation
import SwiftData

/// One completed focus block. Inserted into the shared store whenever a FOCUS phase
/// runs to completion; the integrator appends this type to `SnappetSchema.models`.
@Model
final class PomodoroSession {
    /// Length of the completed focus block, in minutes.
    var minutes: Int
    /// When the focus block finished.
    var completedAt: Date

    init(minutes: Int, completedAt: Date) {
        self.minutes = minutes
        self.completedAt = completedAt
    }
}
