import GitKit
import SwiftUI

enum DiffPreferenceKey {
    static let ignoreWhitespace = "diff.ignoreWhitespace"
    static let contextLines = "diff.contextLines"
}

/// Loads and shows the diff for one file, with a header and display options.
struct DiffPane: View {
    let model: RepositoryModel
    let target: DiffTarget
    let reloadToken: Int

    @AppStorage(DiffPreferenceKey.ignoreWhitespace) private var ignoreWhitespace = false
    @AppStorage(DiffPreferenceKey.contextLines) private var contextLines = 3

    @State private var document: DiffDocument?
    @State private var loadError: String?
    @State private var showsFullDiff = false

    /// Large diffs are cut off here until the user asks for everything; SwiftUI text layout
    /// of tens of thousands of lines is noticeably slow.
    private static let initialLineLimit = 5_000

    private struct LoadKey: Hashable {
        let reloadToken: Int
        let options: DiffOptions
        let showsFullDiff: Bool
    }

    private var options: DiffOptions {
        DiffOptions(ignoreWhitespace: ignoreWhitespace, contextLines: contextLines)
    }

    var body: some View {
        VStack(spacing: 0) {
            DiffHeader(
                target: target,
                diff: document?.diff,
                ignoreWhitespace: $ignoreWhitespace,
                contextLines: $contextLines
            )
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: LoadKey(reloadToken: reloadToken, options: options, showsFullDiff: showsFullDiff)) {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView("Couldn’t Load Diff", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else if let document {
            if document.diff.isBinary {
                ContentUnavailableView("Binary File", systemImage: "doc.fill", description: Text("Binary files can’t be shown as text."))
            } else if document.diff.isEmpty {
                ContentUnavailableView("No Content Changes", systemImage: "equal", description: Text(emptyDescription))
            } else {
                DiffTextView(document: document, lineActions: lineActions(for: document.diff))
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if document.diff.isTruncated {
                            truncationBanner(document.diff)
                        }
                    }
            }
        } else {
            ProgressView()
        }
    }

    /// Hunk and line staging for working copy files, when the diff maps exactly onto the file.
    private func lineActions(for diff: FileDiff) -> DiffLineActions? {
        guard let change = target.workingCopyChange, !ignoreWhitespace, !diff.isTruncated, !diff.isCombined else { return nil }
        let mode: DiffLineActions.Mode
        switch change.area {
        case .unstaged: mode = .unstaged
        case .untracked: mode = .untracked
        case .staged: mode = .staged
        case .conflicted: return nil
        }
        return DiffLineActions(mode: mode) { lines, discard in
            Task { await model.applyLines(lines, of: diff, change: change, discard: discard) }
        }
    }

    private var emptyDescription: String {
        if target.kind == .added || target.kind == .untracked { return "This file is empty." }
        if let originalPath = target.originalPath { return "Renamed from \(originalPath) without content changes." }
        if ignoreWhitespace { return "Only whitespace changed." }
        return "Only the file mode or metadata changed."
    }

    private func truncationBanner(_ diff: FileDiff) -> some View {
        HStack {
            Image(systemName: "scissors")
            Text("Showing the first \(Self.initialLineLimit.formatted()) of \(diff.lineCount.formatted()) lines.")
            Spacer()
            Button("Show Full Diff") { showsFullDiff = true }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func load() async {
        do {
            let diff = try await model.diff(for: target, options: options, maxLines: showsFullDiff ? nil : Self.initialLineLimit)
            guard !Task.isCancelled else { return }
            document = DiffDocument(diff: diff)
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }
}

private struct DiffHeader: View {
    let target: DiffTarget
    let diff: FileDiff?
    @Binding var ignoreWhitespace: Bool
    @Binding var contextLines: Int

    var body: some View {
        HStack(spacing: 8) {
            FileKindBadge(kind: target.kind)

            VStack(alignment: .leading, spacing: 1) {
                Text(target.fileName)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(pathDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .textSelection(.enabled)

            Spacer(minLength: 12)

            if let diff, !diff.isBinary {
                HStack(spacing: 6) {
                    Text("+\(diff.additions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
                .font(.callout.monospacedDigit().weight(.medium))
            }

            Menu {
                Toggle("Ignore Whitespace", isOn: $ignoreWhitespace)
                Picker("Context Lines", selection: $contextLines) {
                    Text("1 Line").tag(1)
                    Text("3 Lines").tag(3)
                    Text("10 Lines").tag(10)
                    Text("25 Lines").tag(25)
                    Text("Entire File").tag(100_000)
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Diff options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var pathDescription: String {
        if let originalPath = target.originalPath {
            return "\(originalPath) → \(target.path)"
        }
        return target.path
    }
}
