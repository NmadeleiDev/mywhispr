import Accessibility
import Foundation
import Observation
import SwiftUI

/// A short-lived, window-level response to an action.
///
/// Toasts are presentation state rather than domain state: they replace one
/// another, remain long enough for their severity, and never occupy document
/// layout. Persistent, actionable conditions still belong in the view itself.
struct ToastMessage: Equatable, Identifiable, Sendable {
    enum Tone: Equatable, Sendable {
        case success
        case information
        case warning
        case failure
    }

    let id: UUID
    let text: String
    let tone: Tone

    init(id: UUID = UUID(), text: String, tone: Tone) {
        self.id = id
        self.text = text
        self.tone = tone
    }
}

@MainActor
@Observable
final class ToastPresenter {
    private(set) var current: ToastMessage?

    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    private enum Linger {
        static let success: Duration = .seconds(3)
        static let information: Duration = .seconds(4)
        static let warning: Duration = .seconds(5)
        static let failure: Duration = .seconds(7)
    }

    func present(
        _ text: String,
        tone: ToastMessage.Tone = .information,
        for duration: Duration? = nil
    ) {
        dismissTask?.cancel()

        let toast = ToastMessage(text: text, tone: tone)
        current = toast
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration ?? Self.linger(for: tone))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: toast.id)
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    private func dismiss(id: UUID) {
        guard current?.id == id else { return }
        dismissTask = nil
        current = nil
    }

    private static func linger(for tone: ToastMessage.Tone) -> Duration {
        switch tone {
        case .success: Linger.success
        case .information: Linger.information
        case .warning: Linger.warning
        case .failure: Linger.failure
        }
    }
}

/// A prominent but quiet confirmation floating above the main-window content.
struct ToastView: View {
    var toast: ToastMessage
    var onDismiss: () -> Void

    private var colour: Color {
        switch toast.tone {
        case .success: Palette.affirm
        case .information: Palette.accent
        case .warning: Palette.accent
        case .failure: Palette.danger
        }
    }

    private var symbol: String {
        switch toast.tone {
        case .success: "checkmark.circle.fill"
        case .information: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(colour)
                .padding(.top, 1)

            Text(toast.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(12)
        .frame(minWidth: 240, maxWidth: 380, alignment: .leading)
        .glassEffect(
            .regular.tint(colour.opacity(0.14)),
            in: .rect(cornerRadius: 14, style: .continuous)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement(toast.text).post()
        }
    }
}
