import Foundation

/// Pure deserialization helper — no SwiftUI, no SwiftData, no platform I/O.
/// Decodes a backup bundle from raw JSON `Data`; inserting the resulting snapshots
/// into the model context is the responsibility of the caller (`DataManagementView`).
enum SnappetRestorer {

    enum RestoreError: LocalizedError {
        case invalidData(String)
        case unsupportedSchemaVersion(Int)

        var errorDescription: String? {
            switch self {
            case .invalidData(let detail):
                return "The backup file couldn't be read: \(detail)"
            case .unsupportedSchemaVersion(let v):
                return "This backup was made with a newer version of Snappet (schema v\(v)). Please update the app to restore it."
            }
        }
    }

    static func restoreBundle(from data: Data) throws -> SnappetBackupBundle {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let bundle: SnappetBackupBundle
        do {
            bundle = try dec.decode(SnappetBackupBundle.self, from: data)
        } catch {
            throw RestoreError.invalidData(error.localizedDescription)
        }
        guard bundle.schemaVersion <= SnappetBackupBundle.currentSchemaVersion else {
            throw RestoreError.unsupportedSchemaVersion(bundle.schemaVersion)
        }
        return bundle
    }
}
