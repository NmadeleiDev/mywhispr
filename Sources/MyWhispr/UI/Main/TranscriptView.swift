import AppKit
import SwiftUI

/// A meeting transcript as a column of spoken passages.
///
/// Passages are bound to the audio clock: the one currently playing is lifted with
/// a filled background, and clicking any passage moves playback there. Speaker
/// identity is carried by a coloured chip rather than by a repeated name, so a long
/// exchange between two people reads as an alternating rhythm.
struct TranscriptView: View {
    var segments: [TranscriptSegmentRecord]
    var currentTime: TimeInterval
    var isPlaybackAvailable: Bool
    var onSeek: (TimeInterval) -> Void
    var onEdit: (TranscriptSegmentRecord, String) -> Void
    var onRenameSpeaker: (String) -> Void

    @State private var editing: UUID?
    @State private var draft = ""

    /// The passage the playhead is inside. Computed once per render rather than per
    /// row so a 900-passage meeting does not do a linear scan per row.
    private var activeSegmentID: UUID? {
        guard isPlaybackAvailable else { return nil }
        return segments.last { $0.start <= currentTime }?.id
    }

    /// Ids of passages that open a new speaker turn — the only rows that need a
    /// name. Built once per render; deriving it per row would be quadratic on a
    /// meeting with hundreds of passages.
    private var speakerRunStarts: Set<UUID> {
        var result: Set<UUID> = []
        var previous: String?
        for segment in segments where segment.speaker != previous {
            result.insert(segment.id)
            previous = segment.speaker
        }
        return result
    }

    var body: some View {
        let runStarts = speakerRunStarts
        let active = activeSegmentID
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(segments) { segment in
                row(
                    for: segment,
                    isActive: segment.id == active,
                    isFirstOfSpeaker: runStarts.contains(segment.id)
                )
                .id(segment.id)
            }
        }
    }

    @ViewBuilder
    private func row(
        for segment: TranscriptSegmentRecord,
        isActive: Bool,
        isFirstOfSpeaker: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if isFirstOfSpeaker {
                HStack(spacing: 8) {
                    SpeakerChip(name: segment.speaker)
                        .onTapGesture { onRenameSpeaker(segment.speaker) }
                        .help("Rename this speaker")
                    Text(Clock.string(segment.start))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.quaternary)
                }
                .padding(.top, 10)
            }

            if editing == segment.id {
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $draft)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 56)
                        .padding(8)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack(spacing: 8) {
                        Button("Cancel") { editing = nil }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        Button("Save") {
                            onEdit(segment, draft)
                            editing = nil
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.accent)
                        .controlSize(.small)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }
                // Escape abandons the edit, which is what Escape means in every
                // in-place editor on the Mac.
                .onExitCommand { editing = nil }
            } else {
                Text(segment.editedText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isActive ? Palette.accent.opacity(0.14) : .clear)
                    )
                    .contentShape(.rect)
                    // Double-click edits, single click seeks. The higher count is
                    // declared first because SwiftUI offers the gesture in order, and
                    // a single-tap handler declared first would win both.
                    .onTapGesture(count: 2) {
                        draft = segment.editedText
                        editing = segment.id
                    }
                    .onTapGesture {
                        if isPlaybackAvailable { onSeek(segment.start) }
                    }
                    .contextMenu {
                        Button("Edit") {
                            draft = segment.editedText
                            editing = segment.id
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(segment.editedText, forType: .string)
                        }
                        Divider()
                        Button("Rename \(segment.speaker)…") { onRenameSpeaker(segment.speaker) }
                    }
            }
        }
        .animation(.smooth(duration: 0.2), value: isActive)
    }
}
