#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity contract for a household **power hour** (household prompt 04, wireframe frame 7),
/// shared by the app (`PowerHourActivityController`) and the widget extension. The countdown renders
/// from `start...end` with `Text(timerInterval:)`, so the OS ticks it with no background work; the count
/// updates whenever the app syncs or is opened.
struct PowerHourActivityAttributes: ActivityAttributes {
    var householdName: String
    var petName: String

    struct ContentState: Codable, Hashable, Sendable {
        var start: Date
        var end: Date
        var done: Int
        var target: Int
        /// How many people have ticked something during it.
        var people: Int
    }
}
#endif
