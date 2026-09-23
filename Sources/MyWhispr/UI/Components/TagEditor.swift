import SwiftUI

/// Assigns free-form tags to a meeting: chips for what is attached, a field that
/// filters the catalog as the owner types, and Enter to attach an existing tag or
/// create a new one.
struct TagEditor: View {
    var tags: [TagRecord]
    var catalog: [TagRecord]
    var compact = false
    var onAdd: (String) -> Void
    var onRemove: (UUID) -> Void

    @State private var draft = ""
    @State private var highlightedIndex = 0
    @FocusState private var fieldFocused: Bool

    private var attachedNames: Set<String> {
        Set(tags.map { $0.name.lowercased() })
    }

    private var suggestions: [TagRecord] {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = catalog.filter { !attachedNames.contains($0.name.lowercased()) }
        guard !trimmed.isEmpty else { return Array(available.prefix(8)) }
        return available
            .filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            .prefix(8)
            .map { $0 }
    }

    private var canCreateDraft: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !attachedNames.contains(trimmed.lowercased())
            && !catalog.contains { $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    private var showSuggestions: Bool {
        fieldFocused && (!suggestions.isEmpty || canCreateDraft)
    }

    var body: some View {
        if compact {
            compactBody
        } else {
            VStack(alignment: .leading, spacing: 6) {
                chips
                input(pill: false)
            }
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowTags(spacing: 4) {
                ForEach(tags) { tag in
                    TagChip(name: tag.name, compact: true) {
                        onRemove(tag.id)
                    }
                }
                input(pill: true)
            }
            if showSuggestions {
                suggestionList
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        if !tags.isEmpty {
            FlowTags(spacing: 6) {
                ForEach(tags) { tag in
                    TagChip(name: tag.name, compact: false) {
                        onRemove(tag.id)
                    }
                }
            }
        }
    }

    private func input(pill: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: pill ? 3 : 6) {
                if !pill {
                    Image(systemName: "tag")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                TextField(pill ? "Add tag" : "Add a tag", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: pill ? 10 : 12, weight: pill ? .medium : .regular))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onChange(of: draft) { _, _ in
                        highlightedIndex = 0
                    }
                    .onKeyPress(.escape) {
                        draft = ""
                        fieldFocused = false
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard showSuggestions else { return .ignored }
                        highlightedIndex = max(0, highlightedIndex - 1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard showSuggestions else { return .ignored }
                        let maxIndex = suggestionRowCount - 1
                        highlightedIndex = min(maxIndex, highlightedIndex + 1)
                        return .handled
                    }
                    .frame(minWidth: pill ? 52 : 0, idealWidth: pill ? pillFieldWidth : nil, maxWidth: pill ? 120 : .infinity)
                if !draft.isEmpty, !pill {
                    Button {
                        draft = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, pill ? 6 : 8)
            .padding(.vertical, pill ? 2 : 5)
            .background {
                if pill {
                    Capsule().fill(Color.primary.opacity(0.06))
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.background.secondary)
                }
            }
            .overlay {
                if pill {
                    Capsule()
                        .strokeBorder(
                            fieldFocused ? Palette.accent.opacity(0.45) : Color.clear,
                            lineWidth: 1
                        )
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            fieldFocused ? Palette.accent.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.6),
                            lineWidth: fieldFocused ? 1.25 : 0.5
                        )
                }
            }

            if showSuggestions, !pill {
                suggestionList
                    .padding(.top, 4)
            }
        }
    }

    private var pillFieldWidth: CGFloat {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 52 }
        return min(120, max(52, CGFloat(trimmed.count) * 7 + 16))
    }

    private var suggestionRowCount: Int {
        suggestions.count + (canCreateDraft ? 1 : 0)
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, tag in
                suggestionRow(title: tag.name, index: index) {
                    onAdd(tag.name)
                    draft = ""
                }
            }
            if canCreateDraft {
                let createIndex = suggestions.count
                suggestionRow(
                    title: "Create “\(draft.trimmingCharacters(in: .whitespacesAndNewlines))”",
                    index: createIndex,
                    isCreate: true
                ) {
                    commitCreate()
                }
            }
        }
        .padding(.vertical, 4)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func suggestionRow(
        title: String,
        index: Int,
        isCreate: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: isCreate ? .medium : .regular))
                    .foregroundStyle(isCreate ? Palette.accent : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index == highlightedIndex ? Palette.accent.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if showSuggestions, highlightedIndex < suggestions.count {
            onAdd(suggestions[highlightedIndex].name)
        } else if showSuggestions, canCreateDraft, highlightedIndex == suggestions.count {
            onAdd(trimmed)
        } else if let exact = suggestions.first(where: {
            $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) {
            onAdd(exact.name)
        } else {
            onAdd(trimmed)
        }
        draft = ""
    }

    private func commitCreate() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        draft = ""
    }
}

struct TagChip: View {
    var name: String
    var compact = false
    var selected = false
    var onRemove: (() -> Void)? = nil

    private var colour: Color { Palette.tag(name) }

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            Text(name)
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .foregroundStyle(colour)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: compact ? 7 : 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(colour.opacity(0.7))
                .help("Remove tag")
            }
        }
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(colour.opacity(selected ? 0.22 : 0.12), in: .capsule)
        .overlay(
            Capsule()
                .strokeBorder(
                    selected ? colour.opacity(0.55) : Color.clear,
                    lineWidth: 1
                )
        )
    }
}

/// Wraps chips onto additional rows without a fixed column count.
private struct FlowTags<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        FlexibleTagLayout(spacing: spacing) {
            content
        }
    }
}

private struct FlexibleTagLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        var y = bounds.minY
        var index = 0
        for row in rows {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
                index += 1
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var count: Int
        var width: CGFloat
        var height: CGFloat
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row(count: 0, width: 0, height: 0)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = current.count == 0 ? size.width : current.width + spacing + size.width
            if current.count > 0, nextWidth > maxWidth {
                rows.append(current)
                current = Row(count: 1, width: size.width, height: size.height)
            } else {
                current.count += 1
                current.width = nextWidth
                current.height = max(current.height, size.height)
            }
        }
        if current.count > 0 { rows.append(current) }
        return rows
    }
}
