import SwiftUI

/// The searchable list of dictations or meetings.
///
/// Rows lead with the content itself — the words that were said, or the meeting's
/// name — because that is what the owner is scanning for. Metadata sits underneath
/// in a quieter tier, and processing state only appears when it is not the boring
/// answer, so a healthy list is pure content with no status noise.
struct SessionList: View {
    var sessions: [SessionRecord]
    var kind: WorkflowKind
    @Binding var selection: UUID?
    var searchText: String
    var onDelete: (UUID) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session)
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
        if !searchText.isEmpty {
            EmptyStateView(icon: "magnifyingglass", message: "Nothing matches “\(searchText)”.")
        } else {
            switch kind {
            case .dictation:
                EmptyStateView(
                    icon: "waveform",
                    message: "Hold the dictation key in any text field and speak. What you say lands here."
                )
            case .meeting:
                EmptyStateView(
                    icon: "person.wave.2",
                    message: "Recorded meetings and their transcripts live here."
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

struct SessionRow: View {
    var session: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .foregroundStyle(session.state == .completed ? .primary : .secondary)
                Spacer(minLength: 4)
                stateBadge
            }
            Text(metadata)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
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
        switch session.state {
        case .completed:
            EmptyView()
        case .recording:
            Image(systemName: "record.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.accent)
        case .processing:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.danger)
        case .interrupted:
            Image(systemName: "arrow.trianglehead.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.accent)
        }
    }
}
