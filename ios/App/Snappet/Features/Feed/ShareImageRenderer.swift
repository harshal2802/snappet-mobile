import SwiftUI
import UIKit

// MARK: - Recap Feed — ShareImageRenderer (F4 / R3)
//
// The thin device edge over `ImageRenderer`: renders a SwiftUI template view at the EXACT
// `ShareAspect.exportPixelSize` so Instagram / iMessage / Photos do zero re-crop (the cropping-bug
// mitigation, _locked-design.md:290). The dimension math + aspect live in the pure
// `ShareTemplateModel`; this file only owns the render itself.
//
// `proposedSize` is set explicitly (no intrinsic sizing) and `scale` is chosen so the output is the
// literal target pixel size: we render the view at the aspect's *point* size and scale by the ratio
// of export-pixels to those points (an exact integer multiple for the canonical 1080-wide sizes).

enum ShareImageRenderer {

    /// Render `view`, laid out at `aspect.previewSize` points, into a `UIImage` whose pixel
    /// dimensions equal `aspect.exportPixelSize` exactly. Must run on the main actor (ImageRenderer
    /// drives the SwiftUI host); call it from a `Task { @MainActor in … }` so heavy renders yield.
    @MainActor
    static func render<V: View>(_ view: V, aspect: ShareAspect) -> UIImage? {
        let pointSize = aspect.previewSize
        let pixelSize = aspect.exportPixelSize

        // Lay the view out at an explicit proposed size (never rely on intrinsic sizing), then scale
        // so width*scale == pixelSize.width exactly. previewSize and exportPixelSize share an aspect
        // ratio, so a single width-derived scale yields the exact pixel height too.
        let renderer = ImageRenderer(content:
            view.frame(width: pointSize.width, height: pointSize.height)
        )
        renderer.proposedSize = ProposedViewSize(width: pointSize.width, height: pointSize.height)
        renderer.scale = pixelSize.width / pointSize.width  // e.g. 1080 / 360 = 3.0
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// PNG `Data` at the exact export pixel size — for callers that hand off raw bytes.
    @MainActor
    static func renderPNG<V: View>(_ view: V, aspect: ShareAspect) -> Data? {
        render(view, aspect: aspect)?.pngData()
    }
}
