import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

/// A sheet that turns the current climb into a scannable QR code (and a shareable link), so a friend
/// with Snappet can scan it and jump straight to the same climb — fully offline, since both apps
/// carry the same catalog. Encodes a `KilterClimbLink` (`snappet://kilter/climb/<uuid>?angle=<n>`).
struct KilterShareView: View {
    let climb: KilterClimb
    let gradeLabel: String
    let angle: Int
    @Environment(\.dismiss) private var dismiss

    private var link: KilterClimbLink { KilterClimbLink(uuid: climb.uuid, angle: angle) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(climb.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Text("\(gradeLabel) · \(angle)° · by \(climb.setter)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                if let image = Self.qrImage(for: link.encoded) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable().scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 260)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("QR code for \(climb.name)")
                        .accessibilityIdentifier("kilter.share.qr")
                } else {
                    ContentUnavailableView("Couldn't make a code", systemImage: "qrcode")
                }

                Text("Open Kilter Board on another phone, tap Scan, and point it here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)

                if let url = link.url {
                    ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("kilter.share.link")
                }
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Share climb")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Render a string into a crisp QR `UIImage` (the CoreImage generator emits a tiny bitmap, so
    /// scale up with nearest-neighbor interpolation to keep the modules sharp).
    static func qrImage(for string: String) -> UIImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
