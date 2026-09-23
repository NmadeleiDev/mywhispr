import SwiftUI

/// The searchable list of dictations or meetings.
///
/// Rows lead with the content itself — the words that were said, or the meeting's
/// name — because that is what the owner is scanning for. Metadata sits underneath
/// in a quieter tier, and active status only appears when it is not the boring
/// answer, so a healthy list is pure content with no status noise.
struct SessionList: View {
    var sessions: [SessionRecord]
    var tagsBySessionID: [UUID: [TagRecord]] = [:]
    var availableTags: [TagRecord] = []
    var kind: WorkflowKind
    @Binding var selection: UUID?
    var searchText: String
    var hasActiveTagFilter = false
    var summaryGenerationSessionID: UUID?
    var onDelete: (UUID) -> Void
    var onAddTag: ((UUID, String) -> Void)? = nil
    var onRemoveTag: ((UUID, UUID) -> Void)? = nil

    var body: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.sessions) { session in
                        SessionRow(
                            session: session,
                            tags: tagsBySessionID[session.id] ?? [],
                            availableTags: availableTags,
                            isSelected: selection == session.id,
                            isGeneratingSummary: summaryGenerationSessionID == session.id,
                            onDelete: { onDelete(session.id) },
                            onAddTag: onAddTag.map { handler in { handler(session.id, $0) } },
                            onRemoveTag: onRemoveTag.map { handler in { handler(session.id, $0) } }
                        )
                            .tag(session.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) { onDelete(session.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // The Delete key is how a Mac list deletes. Routing it through the same
        // closure as the context menu means a meeting still gets its confirmation.
        .onDeleteCommand {
            if let selection { onDelete(selection) }
        }
        .overlay {
            if sessions.isEmpty {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty || hasActiveTagFilter {
            EmptyStateView(icon: "magnifyingglass", message: "No matches")
        } else {
            switch kind {
            case .dictation:
                EmptyStateView(
                    icon: "waveform",
                    message: "No dictations yet"
                )
            case .meeting:
                EmptyStateView(
                    icon: "person.wave.2",
                    message: "No meetings yet"
                )
            }
        }
    }

    private struct Group {
        var title: String
        var sessions: [SessionRecord]
    }

    /// Day buckets, newest first. `Today` and `Yesterday` are named; anything older
    /// carries its date, which is how the eye finds "the one from last Tuesday".
    private var groups: [Group] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [SessionRecord]] = [:]
        for session in sessions {
            let title: String
            if calendar.isDateInToday(session.startedAt) {
                title = "Today"
            } else if calendar.isDateInYesterday(session.startedAt) {
                title = "Yesterday"
            } else {
                title = session.startedAt.formatted(.dateTime.weekday(.wide).month().day())
            }
            if buckets[title] == nil {
                buckets[title] = []
                order.append(title)
            }
            buckets[title]?.append(session)
        }
        return order.map { Group(title: $0, sessions: buckets[$0] ?? []) }
    }
}

enum SessionRowStatus: Equatable {
    case recording
    case processing
    case writingNotes
    case failed
    case interrupted

    init?(sessionState: SessionState, isGeneratingSummary: Bool) {
        switch sessionState {
        case .completed:
            guard isGeneratingSummary else { return nil }
            self = .writingNotes
        case .recording:
            self = .recording
        case .processing:
            self = .processing
        case .failed:
            self = .failed
        case .interrupted:
            self = .interrupted
        }
    }
}

struct SessionRow: View {
    var session: SessionRecord
    var tags: [TagRecord] = []
    var availableTags: [TagRecord] = []
    var isSelected = false
    var isGeneratingSummary = false
    var onDelete: () -> Void = {}
    var onAddTag: ((String) -> Void)? = nil
    var onRemoveTag: ((UUID) -> Void)? = nil

    @State private var hovered = false
    @State private var editingTags = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundStyle(session.state == .completed ? .primary : .secondary)
                Spacer(minLength: 4)
                Menu {
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .opacity(isSelected || hovered ? 1 : 0)
                .help("Meeting actions")
            }
            HStack(spacing: 8) {
                Text(metadata)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                stateBadge
            }
            .font(.system(size: 11))

            if session.kind == .meeting, onAddTag != nil, onRemoveTag != nil {
                tagSection
            }
        }
        .padding(.vertical, 3)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var tagSection: some View {
        if editingTags {
            TagEditor(
                tags: tags,
                catalog: availableTags,
                compact: true,
                onAdd: { name in
                    onAddTag?(name)
                },
                onRemove: { id in
                    onRemoveTag?(id)
                }
            )
            .onExitCommand { editingTags = false }
        } else if !tags.isEmpty || hovered || isSelected {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3)) { tag in
                    TagChip(name: tag.name, compact: true) {
                        onRemoveTag?(tag.id)
                    }
                }
                if tags.count > 3 {
                    Text("+\(tags.count - 3)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    editingTags = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Add tag")
                .opacity(hovered || isSelected || tags.isEmpty ? 1 : 0)
                Spacer(minLength: 0)
            }
        }
    }

    private var displayTitle: String {
        let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    private var metadata: String {
        var parts: [String] = []
        if let application = session.sourceApplication { parts.append(application) }
        parts.append(session.startedAt.formatted(date: .omitted, time: .shortened))
        parts.append(Clock.compact(session.duration))
        return parts.joined(separator: " · ")
    }

    /// Only non-obvious states get a badge. A completed item shows nothing, so the
    /// list stays quiet when everything is fine.
    @ViewBuilder
    private var stateBadge: some View {
        if let status = SessionRowStatus(
            sessionState: session.state,
            isGeneratingSummary: isGeneratingSummary
        ) {
            Group {
                switch status {
                case .writingNotes:
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Palette.accent)
                        Text("Writing notes")
                    }
                    .foregroundStyle(Palette.accent)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Writing meeting notes")
                case .recording:
                    Label("Recording", systemImage: "record.circle")
                        .foregroundStyle(Palette.accent)
                case .processing:
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Processing")
                    }
                case .failed:
                    Label("Needs recovery", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                case .interrupted:
                    Label("Needs recovery", systemImage: "arrow.trianglehead.counterclockwise")
                        .foregroundStyle(Palette.accent)
                }
            }
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .fixedSize()
        }
    }
}
