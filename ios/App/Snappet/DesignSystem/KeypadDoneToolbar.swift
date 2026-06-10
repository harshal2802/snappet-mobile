import SwiftUI

/// The decimal/number pad has no return key, so without help a keypad can only be
/// dismissed by tapping elsewhere — and the value-formatted money fields only commit
/// their binding when focus resigns. Tip solved it first (a `placement: .keyboard` Done
/// button); this shares that pattern with every numeric form in the suite (issue #82).
///
/// Two shapes cover the forms we have:
///  - `keypadDoneToolbar(_:)` for a single focusable field (`FocusState<Bool>`),
///  - the `Hashable?` overload for forms with several fields sharing one focus enum —
///    Done resigns whichever is active.
extension View {
    func keypadDoneToolbar(_ focused: FocusState<Bool>.Binding) -> some View {
        toolbar {
            if focused.wrappedValue {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused.wrappedValue = false }
                }
            }
        }
    }

    func keypadDoneToolbar<Field: Hashable>(_ focused: FocusState<Field?>.Binding) -> some View {
        toolbar {
            if focused.wrappedValue != nil {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused.wrappedValue = nil }
                }
            }
        }
    }
}
