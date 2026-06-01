import SwiftUI

/// Value-first onboarding (#60 §C): explain what Snappet does and *why* it needs
/// Health + Photos BEFORE prompting. Permissions are requested only on the explicit
/// "Connect" tap — never silently on appear.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(SnappetColor.brand)
                Text("Snappet")
                    .font(.largeTitle.bold())
                Text("Turn your workouts into highlight reels — automatically.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 18) {
                ValuePoint(icon: "applewatch", tint: SnappetColor.workout,
                           title: "Reads your workout heart rate",
                           detail: "Snappet finds your most intense moments from your Apple Watch workouts.")
                ValuePoint(icon: "photo.on.rectangle.angled", tint: SnappetColor.habits,
                           title: "Finds the clips you already shot",
                           detail: "It matches the photos and videos you filmed during the workout — no manual picking.")
                ValuePoint(icon: "wand.and.stars", tint: SnappetColor.reels,
                           title: "Builds a reel ranked by intensity",
                           detail: "A finished reel in one tap. Pin, reorder, or regenerate if you want to tweak it.")
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(spacing: 8) {
                Button {
                    connecting = true
                    Task { await model.completeOnboarding() }
                } label: {
                    if connecting {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Connect Health & Photos").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(connecting)

                Text("Everything stays on your device. Nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
    }
}

private struct ValuePoint: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
