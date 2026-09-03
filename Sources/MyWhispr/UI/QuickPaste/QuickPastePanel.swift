import AppKit
import Observation
import SwiftUI

/// The summoned palette of recent dictations.
///
/// It exists so text you already spoke can go somewhere else without opening the
/// main window: hit the shortcut, pick a line, and it lands at the cursor you were
/// just at. The whole interaction is keyboard-driven because the hands are already
/// on the keyboard when it is summoned.
@MainActor
@Observable
final class QuickPastePresenter {
    private(set) var isVisible = false
    private(set) var items: [SessionRecord] = []
    var query = "" {
        didSet { highlighted = 0 }
    }
    var highlighted = 0

    @ObservationIgnored private var panel: KeyablePanel?
    @ObservationIgnored private weak var runtime: AppRuntime?
    /// The field the owner was typing in when the palette was summoned. Captured
    /// *before* the panel takes key focus, because afterwards MyWhispr is frontmost
    /// and the answer would be "our own palette".
    @ObservationIgnored private var target: FocusedTextTarget?
    @ObservationIgnored private var escapeMonitor: Any?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?

    var filtered: [SessionRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    func attach(runtime: AppRuntime) {
        self.runtime = runtime
    }

    func toggle() {
        isVisible ? dismiss() : present()
    }

    func present() {
        guard let runtime, !isVisible else { return }
        target = FocusedTargetCapture.capture()
        items = runtime.recentDictations
        query = ""
        highlighted = 0
        guard !items.isEmpty else {
            runtime.toast.present("There are no dictations to insert yet.", tone: .information)
            return
        }
        isVisible = true

        let panel = existingPanel()
        panel.positionAtOpticalCentre()
        panel.makeKeyAndOrderFront(nil)

        // Escape must close the palette even though the panel is borderless and has
        // no Cancel responder chain of its own.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }

        // Clicking away is how any Mac palette is dismissed. Without this the panel
        // floats above every app until Escape is pressed, which is the behaviour of
        // a stuck window rather than a summoned one.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        if let resignObserver {
            // Removed before ordering out, so hiding the panel does not re-enter here.
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let panel {
            // A summoned palette has no hidden window state worth retaining.
            self.panel = nil
            panel.contentView = nil
            panel.close()
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    func moveHighlight(by delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        highlighted = (highlighted + delta + count) % count
    }

    func commit() {
        let matches = filtered
        guard highlighted >= 0, highlighted < matches.count else { return }
        let session = matches[highlighted]
        let restoreTo = target
        dismiss()
        runtime?.insertFromHistory(sessionID: session.id, into: restoreTo)
    }

    private func existingPanel() -> KeyablePanel {
        if let panel { return panel }
        let created = KeyablePanel(size: Metrics.quickPastePanelSize)
        created.contentView = NSHostingView(rootView: QuickPasteView(presenter: self))
        panel = created
        return created
    }
}

struct QuickPasteView: View {
    @Bindable var presenter: QuickPastePresenter
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search what you have said", text: $presenter.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit { presenter.commit() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(presenter.filtered.enumerated()), id: \.element.id) { index, session in
                            row(session, isHighlighted: index == presenter.highlighted)
                                .id(session.id)
                                .onTapGesture {
                                    presenter.highlighted = index
                                    presenter.commit()
                                }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: presenter.highlighted) { _, index in
                    guard index < presenter.filtered.count else { return }
                    proxy.scrollTo(presenter.filtered[index].id, anchor: .center)
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: 14) {
                KeyHint(keys: "↑↓", label: "Choose")
                KeyHint(keys: "↩", label: "Insert")
                KeyHint(keys: "⎋", label: "Close")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .padding(20)
        .onAppear { searchFocused = true }
        .onKeyPress(.upArrow) { presenter.moveHighlight(by: -1); return .handled }
        .onKeyPress(.downArrow) { presenter.moveHighlight(by: 1); return .handled }
    }

    private func row(_ session: SessionRecord, isHighlighted: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(
                    [
                        session.sourceApplication,
                        session.startedAt.formatted(date: .abbreviated, time: .shortened),
                    ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Palette.accent.opacity(0.18) : .clear)
        )
        .contentShape(.rect)
    }
}

private struct KeyHint: View {
    var keys: String
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
