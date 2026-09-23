import GitKit
import SwiftUI

/// History and blame for one file, in a large sheet.
struct FileInspectorView: View {
    let model: RepositoryModel
    let request: FileInspectorRequest

    @Environment(\.dismiss) private var dismiss
    @State private var mode: FileInspectorRequest.Mode
    /// Commit to select when switching from blame to history.
    @State private var historySelection: String?

    init(model: RepositoryModel, request: FileInspectorRequest) {
        self.model = model
        self.request = request
        _mode = State(initialValue: request.mode)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.url.appending(path: request.path).path))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text((request.path as NSString).lastPathComponent)
                        .font(.headline)
                    Text(request.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Picker("View", selection: $mode) {
                    Text("History").tag(FileInspectorRequest.Mode.history)
                    Text("Blame").tag(FileInspectorRequest.Mode.blame)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch mode {
            case .history:
                FileHistoryView(model: model, path: request.path, selection: $historySelection)
            case .blame:
                BlameView(model: model, path: request.path, revision: request.revision) { sha in
                    historySelection = sha
                    mode = .history
                }
            }
        }
        .frame(minWidth: 860, idealWidth: 1100, minHeight: 560, idealHeight: 720)
    }
}

// MARK: - History

private struct FileHistoryView: View {
    let model: RepositoryModel
    let path: String
    @Binding var selection: String?

    @State private var entries: [FileHistoryEntry]?
    @State private var loadError: String?

    var body: some View {
        if let loadError {
            ContentUnavailableView("Couldn’t Load History", systemImage: "exclamationmark.triangle", description: Text(loadError))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let entries {
            if entries.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock", description: Text("This file hasn’t been committed yet."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(entries, selection: $selection) { entry in
                        FileHistoryRow(entry: entry, currentPath: path)
                            .tag(entry.id)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 440)

                    detail(entries)
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await load() }
        }
    }

    @ViewBuilder
    private func detail(_ entries: [FileHistoryEntry]) -> some View {
        if let entry = entries.first(where: { $0.id == selection }) {
            let file = CommitFileChange(path: entry.path, originalPath: entry.originalPath, kind: entry.kind)
            DiffPane(model: model, target: DiffTarget(source: .commit(entry.commit, file)), reloadToken: 0)
                .id(entry.id)
        } else {
            ContentUnavailableView("No Commit Selected", systemImage: "circle.dashed")
        }
    }

    private func load() async {
        do {
            let loaded = try await model.fileHistory(path: path)
            entries = loaded
            if selection == nil || !loaded.contains(where: { $0.id == selection }) {
                selection = loaded.first?.id
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct FileHistoryRow: View {
    let entry: FileHistoryEntry
    let currentPath: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AuthorAvatar(name: entry.commit.authorName, email: entry.commit.authorEmail)
                .scaleEffect(0.75)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.commit.subject)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(entry.commit.shortSHA).font(.caption.monospaced())
                    Text("·")
                    Text(entry.commit.authorName)
                    Text("·")
                    Text(entry.commit.authorDate.relativeOrAbsolute)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if entry.path != currentPath {
                    Text("as \(entry.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Blame

private struct BlameView: View {
    let model: RepositoryModel
    let path: String
    let revision: String?
    let showCommit: (String) -> Void

    @State private var blame: Blame?
    @State private var loadError: String?
    @State private var hoveredSHA: String?

    private static let font = Font.system(size: 12, design: .monospaced)

    var body: some View {
        if let loadError {
            ContentUnavailableView("Couldn’t Blame File", systemImage: "exclamationmark.triangle", description: Text(loadError))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let blame {
            let digits = String(blame.lines.count).count
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(blame.lines) { line in
                        row(line, in: blame, digits: digits)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await load() }
        }
    }

    private func row(_ line: BlameLine, in blame: Blame, digits: Int) -> some View {
        let index = line.lineNumber - 1
        let startsGroup = index == 0 || blame.lines[index - 1].sha != line.sha
        let commit = blame.commits[line.sha]

        return HStack(spacing: 0) {
            // Commit info only on the first line of each run of lines from the same commit.
            HStack(spacing: 6) {
                if startsGroup {
                    if line.isUncommitted {
                        Text("Not committed yet")
                            .italic()
                            .foregroundStyle(.secondary)
                    } else if let commit {
                        Text(commit.sha.prefix(7))
                            .foregroundStyle(.secondary)
                        Text(commit.authorName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(commit.authorDate.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            .frame(width: 280, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(color(for: line.sha).opacity(hoveredSHA == line.sha ? 0.22 : 0.1))
            .overlay(alignment: .top) {
                if startsGroup, index > 0 { Rectangle().fill(.separator).frame(height: 0.5) }
            }
            .contentShape(Rectangle())
            .onHover { hoveredSHA = $0 ? line.sha : nil }
            .onTapGesture {
                if !line.isUncommitted { showCommit(line.sha) }
            }
            .help(commit.map { "\($0.summary)\n\($0.authorName) <\($0.authorEmail)>\nClick to show in history" } ?? "")

            Text(String(line.lineNumber))
                .foregroundStyle(.tertiary)
                .frame(width: CGFloat(max(digits, 3)) * 7.5 + 12, alignment: .trailing)
                .padding(.trailing, 10)

            Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 16)
        }
        .font(Self.font)
        .frame(height: 18)
    }

    /// A stable soft color per commit, so runs of lines from the same commit stand out.
    private func color(for sha: String) -> Color {
        guard !sha.allSatisfy({ $0 == "0" }) else { return .clear }
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]
        let hash = sha.prefix(8).utf8.reduce(UInt64(5381)) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private func load() async {
        do {
            blame = try await model.blame(path: path, revision: revision)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
