import SwiftUI

/// A weight readout you can **tap to type** (prompt 139, wireframe frame 15). Shows "71.3 kg" / "Body";
/// a tap swaps in a decimal-pad field seeded with the current value, and ending the edit (Done, or
/// tapping elsewhere) commits whatever parses — an unparseable entry keeps the previous weight. The ±
/// buttons around it are the host's; this view only owns the typed path, so every weight in the app
/// (set logging, timed sets, and the hangboard load to come) edits the same way.
struct TypeableWeightValue: View {
    @Binding var weight: Double
    let unit: WeightUnit
    let font: Font
    var color: Color = .primary
    /// Accessibility id of the readout (the field gets `<id>.field`).
    let id: String
    /// What 0 reads as — "Body" for a set weight (bodyweight); a load passes its own.
    var zeroLabel: String = "Body"

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var display: String {
        weight > 0 ? "\(SetMeasure.formatWeight(weight)) \(unit.display)" : zeroLabel
    }

    var body: some View {
        Group {
            if editing {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    TextField("0", text: $text)
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .font(font)
                        .foregroundStyle(SnappetColor.workout)
                        .fixedSize()
                        .accessibilityIdentifier("\(id).field")
                    Text(unit.display).font(.subheadline.weight(.semibold)).foregroundStyle(color.opacity(0.7))
                    // An inline Done: the decimal pad has no return key, and the keyboard toolbar isn't
                    // shown inside the full-screen workout pager — so the field carries its own.
                    Button { focused = false } label: {
                        Image(systemName: "checkmark.circle.fill").font(.title2)
                            .foregroundStyle(SnappetColor.workout)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Done")
                    .accessibilityIdentifier("\(id).done")
                }
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SnappetColor.workout).frame(height: 2).offset(y: 4)
                }
            } else {
                Button { beginEditing() } label: {
                    Text(display).font(font).foregroundStyle(color).contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Double-tap to type an exact weight")
                .accessibilityIdentifier(id)
            }
        }
        // Every keystroke the parser accepts updates the weight at once (prompt 192): tapping Log set with the field
        // still focused used to log the OLD value — the hero re-seeds after a log, destroying the field before its
        // focus-loss commit ran, so the typed 67.5 was lost and the set logged at its previous weight.
        .onChange(of: text) { _, new in
            if editing, let value = WeightEntry.parse(new) { weight = value }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused, editing { commit() }
        }
    }

    private func beginEditing() {
        text = WeightEntry.editText(weight)
        editing = true
        // The field has to exist before it can take focus.
        Task { @MainActor in focused = true }
    }

    private func commit() {
        if let value = WeightEntry.parse(text) { weight = value }
        editing = false
    }
}
