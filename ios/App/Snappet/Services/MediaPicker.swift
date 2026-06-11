import SwiftUI
import PhotosUI

/// Manual media picker for the **authorized** no-clips-found fallback (#60 §C): auto-discovery
/// found nothing in the session window, so the user picks clips by hand from the full library.
/// No longer offered under `.limited` access — PHPicker browses the full library but never
/// widens the grant, so picks outside it would be unresolvable; limited surfaces present the
/// grant-extending `presentLimitedLibraryPicker` instead (issue #72 pre-merge review fix).
/// Configured with `photoLibrary: .shared()` so results carry `assetIdentifier`s — which
/// `PhotoLibraryService.media(forIdentifiers:)` maps back to engine `MediaItem`s using the
/// same creationDate→offset alignment.
struct MediaPicker: UIViewControllerRepresentable {
    /// Called with the picked asset identifiers (empty if the user cancels).
    let onPicked: ([String]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.videos, .images])
        config.selectionLimit = 0            // 0 = no limit
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([String]) -> Void
        init(onPicked: @escaping ([String]) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPicked(results.compactMap(\.assetIdentifier))
        }
    }
}
