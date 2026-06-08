import SwiftUI

/// Live preview of the configurable HR/fitness overlay **elements** (prompt 28) over the clip player
/// — the WYSIWYG twin of `StudioOverlays.hrElementLayers` (the export burn-in). Each element is a
/// rounded badge at its normalized position; **live** elements track the playhead `fraction`, static
/// ones show the clip value. Drag a badge to reposition it. The pure `HROverlayValues` resolves the
/// text + colour so the preview matches the exported file.
struct HROverlayElementsView: View {
    let elements: [HROverlayElement]
    let values: HROverlayValues
    /// Playhead position as a fraction of the clip (0…1).
    let fraction: Double
    /// Called with (elementID, normalized position) as the user drags a badge.
    var onMove: (UUID, CGPoint) -> Void = { _, _ in }

    var body: some View {
        GeometryReader { geo in
            ForEach(elements) { element in
                if let reading = values.reading(for: element, atFraction: fraction) {
                    badge(reading)
                        .position(x: element.normalizedX * geo.size.width,
                                  y: element.normalizedY * geo.size.height)
                        .gesture(
                            DragGesture()
                                .onChanged { g in
                                    onMove(element.id,
                                           CGPoint(x: g.location.x / max(1, geo.size.width),
                                                   y: g.location.y / max(1, geo.size.height)))
                                })
                        .accessibilityIdentifier("hrOverlayBadge")
                }
            }
        }
        .allowsHitTesting(true)
    }

    private func badge(_ reading: HROverlayValues.Reading) -> some View {
        Text(reading.text)
            .font(.caption.weight(.semibold)).monospacedDigit()
            .foregroundStyle(Color(studioHex: reading.hex))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.4), in: Capsule())
    }
}
