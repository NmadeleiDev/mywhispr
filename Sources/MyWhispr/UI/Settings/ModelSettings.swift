import SwiftUI

/// The shared library of downloaded speech models.
///
/// Dictation and meetings both draw from this one set of files, so this pane is
/// where disk cost lives. A model that a workflow currently depends on cannot be
/// removed without first reassigning that workflow — the constraint is enforced by
/// the button being unavailable and named, not by an error afterwards.
struct ModelSettings: View {
    @Bindable var runtime: AppRuntime
    @State private var pendingRemoval: ModelDescriptor?

    var body: some View {
        SettingsPane {
            Card(
                title: "On this Mac",
                footnote: "Downloads happen once. After a model is installed, transcription needs no network at all."
            ) {
                SettingRow(label: "Space used") {
                    Text(ByteFormat.string(runtime.models.totalBytes))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button("Show in Finder") { runtime.models.revealInFinder() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Button("Check again") { runtime.models.refresh() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Spacer()
                }
            }

            ForEach(EngineIdentifier.allCases, id: \.self) { engine in
                let models = ModelDescriptor.curated.filter { $0.engine == engine }
                if !models.isEmpty {
                    Card(title: engine.displayName) {
                        ForEach(models) { descriptor in
                            LibraryRow(
                                descriptor: descriptor,
                                state: runtime.models.state(of: descriptor.id),
                                assignment: runtime.assignment(of: descriptor.id),
                                onDownload: { runtime.models.download(descriptor) },
                                onCancel: { runtime.models.cancelDownload(descriptor.id) },
                                onRemove: { pendingRemoval = descriptor }
                            )
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "this model")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pendingRemoval { runtime.models.remove(pendingRemoval) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("The files are deleted from this Mac. Transcripts made with this model are not affected, and it can be downloaded again later.")
        }
    }
}

private struct LibraryRow: View {
    var descriptor: ModelDescriptor
    var state: ModelLibrary.State
    /// Which workflows currently point at this model, if any.
    var assignment: [WorkflowKind]
    var onDownload: () -> Void
    var onCancel: () -> Void
    var onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .font(.system(size: 13, weight: .medium))
                    ForEach(assignment, id: \.self) { kind in
                        Text(kind == .dictation ? "Dictation" : "Meetings")
                            .font(.system(size: 9, weight: .semibold))
                            .textCase(.uppercase)
                            .kerning(0.3)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Palette.accent.opacity(0.16), in: .capsule)
                            .foregroundStyle(Palette.accent)
                    }
                }
                Text(descriptor.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(descriptor.license)
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .installed(let bytes):
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteFormat.string(bytes))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!assignment.isEmpty)
                    .help(
                        assignment.isEmpty
                            ? "Delete these files"
                            : "Choose a different model for \(assignment.map { $0 == .dictation ? "Dictation" : "Meetings" }.joined(separator: " and ")) first"
                    )
            }
        case .absent:
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteFormat.string(descriptor.downloadBytes))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .help("Download size")
                Button("Download", action: onDownload)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                    .tint(Palette.accent)
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(2)
                    .frame(maxWidth: 150, alignment: .trailing)
                Button("Try again", action: onDownload)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
    }
}
