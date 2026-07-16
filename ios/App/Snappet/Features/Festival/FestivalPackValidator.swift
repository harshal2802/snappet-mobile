import Foundation

/// Structural validation a decoded pack must pass before install (the `KilterCatalogValidator` posture):
/// a user can point the app at any file, and a malformed or foreign one is rejected with a message the
/// install UI (prompt 02) shows verbatim instead of installing junk the matcher would choke on.
///
/// Pure Foundation → unit-tested without a simulator. What it guarantees downstream:
/// every set has an artist and a positive window, sets on ONE stage never overlap each other (different
/// stages may — that's exactly the ambiguity the matcher scores), every set sits inside its poster
/// day's rollover window, and every day sits inside the festival's date range.
enum FestivalPackValidator {
    /// What a valid pack yields — the counts the catalog browse row shows ("9 stages · 412 sets").
    struct Validated: Sendable, Equatable {
        let dayCount: Int
        let stageCount: Int
        let setCount: Int
    }

    enum Failure: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case emptyName
        case badUTCOffset(Int)
        case noDays
        case badDayDate(String)
        case duplicateDay(String)
        case dayOutsideFestival(String)
        case emptyDay(String)
        case emptyStage(day: String, stage: String)
        case emptyArtist(day: String, stage: String)
        case invalidWindow(artist: String)
        case overlapWithinStage(stage: String, first: String, second: String)
        case setOutsideDay(day: String, artist: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                return "This pack uses format v\(v), which this version of Snappet can't read."
            case .emptyName:
                return "This pack has no festival name."
            case .badUTCOffset(let s):
                return "This pack's UTC offset (\(s) s) isn't a real-world time zone offset."
            case .noDays:
                return "This pack has no festival days."
            case .badDayDate(let d):
                return "“\(d)” isn't a valid day date (expected yyyy-MM-dd)."
            case .duplicateDay(let d):
                return "The day \(d) appears twice in this pack."
            case .dayOutsideFestival(let d):
                return "The day \(d) falls outside the festival's dates."
            case .emptyDay(let d):
                return "The day \(d) has no stages."
            case .emptyStage(let day, let stage):
                return "“\(stage)” on \(day) has no sets."
            case .emptyArtist(let day, let stage):
                return "A set on “\(stage)” (\(day)) has no artist."
            case .invalidWindow(let artist):
                return "“\(artist)” has a set that ends before it starts."
            case .overlapWithinStage(let stage, let a, let b):
                return "“\(a)” and “\(b)” overlap on “\(stage)” — one stage can't host two sets at once."
            case .setOutsideDay(let day, let artist):
                return "“\(artist)” is scheduled outside the \(day) day window "
                    + "(days run to \(FestivalDay.rolloverHour):00 the next morning)."
            }
        }
    }

    /// Real-world UTC offsets span −12:00…+14:00.
    static let utcOffsetRange = (-12 * 3600)...(14 * 3600)

    @discardableResult
    static func validate(_ pack: FestivalPack) throws -> Validated {
        guard pack.formatVersion == FestivalPack.currentFormatVersion else {
            throw Failure.unsupportedVersion(pack.formatVersion)
        }
        if pack.name.trimmingCharacters(in: .whitespaces).isEmpty { throw Failure.emptyName }
        guard utcOffsetRange.contains(pack.utcOffsetSeconds) else {
            throw Failure.badUTCOffset(pack.utcOffsetSeconds)
        }
        if pack.days.isEmpty { throw Failure.noDays }

        var seenDates: Set<String> = []
        var stageCount = 0
        var setCount = 0

        for day in pack.days {
            guard let window = day.window(utcOffsetSeconds: pack.utcOffsetSeconds) else {
                throw Failure.badDayDate(day.date)
            }
            if !seenDates.insert(day.date).inserted { throw Failure.duplicateDay(day.date) }
            // Poster dates are yyyy-MM-dd, so lexical order IS chronological order.
            guard day.date >= pack.startDate, day.date <= pack.endDate else {
                throw Failure.dayOutsideFestival(day.date)
            }
            if day.stages.isEmpty { throw Failure.emptyDay(day.date) }

            for stage in day.stages {
                stageCount += 1
                if stage.sets.isEmpty { throw Failure.emptyStage(day: day.date, stage: stage.name) }

                for set in stage.sets {
                    setCount += 1
                    if set.artist.trimmingCharacters(in: .whitespaces).isEmpty {
                        throw Failure.emptyArtist(day: day.date, stage: stage.name)
                    }
                    if set.start >= set.end { throw Failure.invalidWindow(artist: set.artist) }
                    guard window.contains(set.start), set.end <= window.end else {
                        throw Failure.setOutsideDay(day: day.date, artist: set.artist)
                    }
                }

                // One stage hosts one set at a time; back-to-back (end == next start) is fine.
                let ordered = stage.sets.sorted { $0.start < $1.start }
                for (a, b) in zip(ordered, ordered.dropFirst()) where b.start < a.end {
                    throw Failure.overlapWithinStage(stage: stage.name, first: a.artist,
                                                     second: b.artist)
                }
            }
        }
        return Validated(dayCount: pack.days.count, stageCount: stageCount, setCount: setCount)
    }
}
