import SwiftUI

/// The dictionary pane: one list of the owner's own words, used everywhere.
///
/// It is its own destination rather than a card inside Dictation and again inside
/// Meetings, because it is one thing. Two copies would mean adding a colleague's
/// name twice and silently not having it work in whichever half was forgotten.
struct VocabularySettings: View {
    @Bindable var runtime: AppRuntime

    var body: some View {
        @Bindable var settings = runtime.settings

        SettingsPane {
            VocabularyCard(terms: $settings.payload.vocabulary)
        }
    }
}

/// The owner's own words, corrected in whatever comes back from the model.
///
/// It is a list of entries rather than a text box because the thing being built is a
/// list. A text box asks the owner to hold a rule in their head — one per line — and
/// then punishes them for a stray blank line or a trailing space; rows show the
/// entries as the separate things they are, and each one can be removed on its own.
struct VocabularyCard: View {
    @Binding var terms: [String]

    @State private var draft = ""
    @FocusState private var addFieldFocused: Bool

    /// One row's height, and the point past which the list scrolls instead of
    /// pushing the rest of the pane off the bottom of the window.
    private static let rowHeight: CGFloat = 30
    private static let maximumListHeight: CGFloat = 186

    var body: some View {
        Card(
            title: "Your words",
            footnote: "Names, jargon, and product names that are easy to mishear. MyWhispr rewrites close misses of these back to the spelling you gave, in dictation and in meetings alike. An entry can be several words."
        ) {
            VStack(spacing: 0) {
                entries
                addRow
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
        }
    }

    /// Capped in height so a long vocabulary scrolls inside its card rather than
    /// pushing the rest of the pane off the bottom of the window.
    @ViewBuilder
    private var entries: some View {
        if !terms.isEmpty {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(terms.indices, id: \.self) { index in
                        VocabularyEntryRow(
                            text: Binding(
                                get: { index < terms.count ? terms[index] : "" },
                                set: { if index < terms.count { terms[index] = $0 } }
                            ),
                            onCommit: { tidy() },
                            onRemove: { remove(at: index) }
                        )
                        if index < terms.count - 1 {
                            Divider().opacity(0.35).padding(.leading, 10)
                        }
                    }
                }
            }
            .frame(height: min(CGFloat(terms.count) * Self.rowHeight, Self.maximumListHeight))

            Divider().opacity(0.5)
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            TextField("Add a word or expression", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($addFieldFocused)
                .onSubmit(commitDraft)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture { addFieldFocused = true }
    }

    // MARK: - Editing

    private func commitDraft() {
        let entry = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !entry.isEmpty else { return }
        // A duplicate is not an error worth reporting; the list simply already says
        // what the owner just asked it to say.
        guard !terms.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) else { return }
        terms.append(entry)
        // Focus stays put so a run of entries can be typed without reaching for the
        // mouse between each one.
        addFieldFocused = true
    }

    private func remove(at index: Int) {
        guard index < terms.count else { return }
        terms.remove(at: index)
    }

    /// Applied when an entry loses focus rather than on every keystroke, so deleting
    /// the last character of a word does not delete the row out from under the cursor.
    private func tidy() {
        var seen = Set<String>()
        terms = terms.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}

private struct VocabularyEntryRow: View {
    @Binding var text: String
    var onCommit: () -> Void
    var onRemove: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit { isFocused = false }
                .onChange(of: isFocused) { _, focused in
                    if !focused { onCommit() }
                }

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 12))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            // Faint rather than invisible: a control that only exists under the
            // pointer cannot be found by anyone who is not already pointing at it.
            .opacity(isHovering ? 1 : 0.3)
            .help("Remove")
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { isHovering = $0 }
    }
}
