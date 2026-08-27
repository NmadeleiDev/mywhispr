import SwiftUI

/// A button that answers for itself.
///
/// Copying and re-inserting finish the instant they are pressed and leave nothing
/// behind to show for it, so the only acknowledgement was a notice at the bottom
/// edge of the window — the far side of the screen from the pointer that just
/// clicked, and easy to miss entirely. A control that does not visibly respond is
/// indistinguishable from one that is broken, and pressing it again is the natural
/// next move, which for insertion means saying the same thing twice.
///
/// So the answer is given where the question was asked: the button briefly becomes
/// what it just did, refuses a second press while it says so, and then goes back to
/// being an offer. The banner still carries the detail; this carries the fact that
/// something happened.
struct ConfirmingButton: View {
    var title: String
    var systemImage: String
    /// Past tense of `title` — "Copied" for "Copy". Kept close in length so the row
    /// around it does not jump.
    var confirmation: String
    var confirmationImage: String = "checkmark"
    var action: () -> Void

    @State private var isConfirming = false

    /// Long enough to be read without looking for it, short enough that the button
    /// is available again before anyone reaches for it a second time.
    private static let linger: Duration = .milliseconds(1_300)

    var body: some View {
        Button {
            action()
            isConfirming = true
        } label: {
            Label(
                isConfirming ? confirmation : title,
                systemImage: isConfirming ? confirmationImage : systemImage
            )
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .disabled(isConfirming)
        .animation(.snappy(duration: 0.18), value: isConfirming)
        // Reverts on its own rather than latching: a button stuck reading "Copied"
        // would be the same silent control, only lying.
        .task(id: isConfirming) {
            guard isConfirming else { return }
            try? await Task.sleep(for: Self.linger)
            isConfirming = false
        }
    }
}
