import SwiftUI

/// Settings → Appearance (prompt 211; user: "can we make this color profile configurable on the settings?"). The
/// accent the whole app uses — Periwinkle by default — with a live preview, plus System / Dark / Light. A change
/// repaints every screen at once (`SnappetThemeModifier`); colours that mean something (green = done, the heart-rate
/// zones, a climb's real hold colours) never follow the accent.
struct AppearanceSettingsView: View {
    @AppStorage(SnappetAccent.defaultsKey) private var accentRaw = SnappetAccent.default.rawValue
    @AppStorage(SnappetAppearance.defaultsKey) private var modeRaw = SnappetAppearance.system.rawValue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section { preview.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }

                Section {
                    HStack(spacing: 14) {
                        ForEach(SnappetAccent.allCases) { swatch($0) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                } header: {
                    Text("Accent colour")
                } footer: {
                    Text("Used for the main action, progress and highlighted data. Colours that mean something — done, heart-rate zones, a climb’s hold colours — stay the same.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $modeRaw) {
                        ForEach(SnappetAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.appearance.mode")
                }
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("settings.appearance.done")
                }
            }
        }
    }

    private func swatch(_ accent: SnappetAccent) -> some View {
        let selected = SnappetAccent.resolve(accentRaw) == accent
        return Button { withAnimation(.snappy) { accentRaw = accent.rawValue } } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: scheme == .dark ? accent.dark : accent.light))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(SnappetColor.ink.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-4))
                Text(accent.label).font(.caption2).foregroundStyle(selected ? SnappetColor.ink : SnappetColor.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(accent.label) accent")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.appearance.accent.\(accent.rawValue)")
    }

    /// What the accent touches, in the new card style: a primary action, a progress line, the week's bars.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview").snappetLabel()
            Text("Chiro Thoracic Rehab").snappetTitle()
            Text("About 56 min · +135 XP").snappetDetail()
            ProgressView(value: 0.57).tint(SnappetColor.brand)
            HStack(alignment: .bottom) {
                Button("Start") {}.buttonStyle(.snappetPrimary).allowsHitTesting(false)
                Spacer()
                SnappetBars(values: [0, 3, 0, 1, 0, 0, 2]).frame(width: 120)
            }
        }
        .snappetPanel(glow: true)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.appearance.preview")
    }
}
