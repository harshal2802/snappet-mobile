import SwiftUI
import UIKit

/// A sheet that turns the current climb into a scannable QR code (and a shareable link), so a friend
/// with Snappet can scan it and jump straight to the same climb — fully offline, since both apps
/// carry the same catalog. Encodes a `KilterClimbLink` (`snappet://kilter/climb/<uuid>?angle=<n>`).
struct KilterShareView: View {
    let climb: KilterClimb
    let gradeLabel: String
    let angle: Int
    @Environment(\.dismiss) private var dismiss
    @State private var copiedFrames = false

    private var link: KilterClimbLink { KilterClimbLink(uuid: climb.uuid, angle: angle) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(climb.name).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Text("\(gradeLabel) · \(angle)° · by \(climb.setter)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                if let image = QRCodeImage.make(for: link.encoded) {
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

                // Frames export — the raw `p<placement>r<role>` string (what the catalog stores and the
                // board-explorer's "Copy frames" emits), so a climb (incl. one you authored) is portable
                // as plain text into other tools, even without Snappet.
                if !climb.frames.isEmpty {
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = climb.frames
                            copiedFrames = true
                        } label: {
                            Label(copiedFrames ? "Copied" : "Copy frames",
                                  systemImage: copiedFrames ? "checkmark" : "doc.on.doc")
                        }
                        .accessibilityIdentifier("kilter.share.copyFrames")
                        ShareLink(item: climb.frames) { Label("Share frames", systemImage: "text.quote") }
                            .accessibilityIdentifier("kilter.share.shareFrames")
                    }
                    .font(.subheadline)
                    .buttonStyle(.bordered)
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
}
