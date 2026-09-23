import GitKit
import SwiftUI

/// Reorder, reword, squash, fixup or delete the commits from a chosen commit up to `HEAD`.
/// Newest commits are at the top, as in the history list; drag rows to reorder them.
struct InteractiveRebaseSheet: View {
    let model: RepositoryModel
    let commit: Commit

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var loadError: String?
    @State private var isRunning = false

    struct Row: Identifiable {
        let commit: Commit
        let message: String
        var action: RebaseStep.Action = .pick
        var editedMessage: String

        var id: String { commit.sha }
    }

    /// Squash and fixup combine a commit with the one below it, so the oldest commit can't use them.
    private var problem: String? {
        guard let oldest = rows.last else { return nil }
        if oldest.action == .squash || oldest.action == .fixup {
            return "The oldest commit can’t be squashed: there’s no older commit in the list to combine it with."
        }
        if rows.allSatisfy({ $0.action == .drop }) {
            return "Keep at least one commit."
        }
        return nil
    }

    private var hasChanges: Bool {
        rows.contains { $0.action != .pick } || rows.map(\.id) != originalOrder
    }

    @State private var originalOrder: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Interactive Rebase")
                    .font(.headline)
                Text("Drag to reorder. Squash and Fixup combine a commit with the one below it; Squash keeps both messages.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Group {
                if let loadError {
                    ContentUnavailableView("Couldn’t Load Commits", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else if rows.isEmpty {
                    ProgressView()
                } else {
                    List {
                        ForEach($rows) { $row in
                            RebaseRowView(row: $row)
                        }
                        .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack {
                Text("\(rows.count) commit\(rows.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Rebase") {
                    isRunning = true
                    Task {
                        let succeeded = await model.rebaseInteractively(from: commit, steps: steps())
                        isRunning = false
                        // On conflicts the rebase pauses; the banner takes over from here.
                        if succeeded || model.snapshot?.pendingOperation != nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil || !hasChanges || isRunning || rows.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 460, idealHeight: 560)
        .task { await load() }
    }

    private func load() async {
        guard let git = model.git else { return }
        do {
            async let plan = git.commitsForRebase(from: commit)
            async let messages = git.messagesForRebase(from: commit)
            let (commits, fullMessages) = try await (plan, messages)
            rows = commits.reversed().map { commit in
                let message = fullMessages[commit.sha] ?? commit.subject
                return Row(commit: commit, message: message, editedMessage: message)
            }
            originalOrder = rows.map(\.id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The plan in git's order (oldest first). Messages are set on the commit a group of
    /// squashes ends up in: its own (possibly edited) message followed by the squashed ones.
    private func steps() -> [RebaseStep] {
        var steps: [RebaseStep] = []
        var leader: (index: Int, message: String, changed: Bool)?

        func finishGroup() {
            if let leader, leader.changed {
                steps[leader.index].message = leader.message
            }
            leader = nil
        }

        for row in rows.reversed() {
            switch row.action {
            case .pick, .reword:
                finishGroup()
                steps.append(RebaseStep(sha: row.commit.sha, action: row.action))
                let isReworded = row.action == .reword && row.editedMessage != row.message
                leader = (steps.count - 1, isReworded ? row.editedMessage : row.message, isReworded)
            case .squash:
                steps.append(RebaseStep(sha: row.commit.sha, action: .squash))
                if let current = leader {
                    leader = (current.index, current.message + "\n\n" + row.message, true)
                }
            case .fixup, .drop:
                steps.append(RebaseStep(sha: row.commit.sha, action: row.action))
            }
        }
        finishGroup()
        return steps
    }
}

private struct RebaseRowView: View {
    @Binding var row: InteractiveRebaseSheet.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .help("Drag to reorder")

                Picker("Action", selection: $row.action) {
                    ForEach(RebaseStep.Action.allCases, id: \.self) { action in
                        Label(action.title, systemImage: action.symbol).tag(action)
                    }
                }
                .labelsHidden()
                .fixedSize()

                Text(row.commit.shortSHA)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)

                Text(row.commit.subject)
                    .lineLimit(1)
                    .strikethrough(row.action == .drop)
                    .foregroundStyle(row.action == .drop || row.action == .fixup ? .secondary : .primary)

                Spacer(minLength: 8)

                Text(row.commit.authorName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if row.action == .reword {
                TextEditor(text: $row.editedMessage)
                    .font(.body.monospaced())
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 5))
                    .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.separator) }
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 3)
    }
}

extension RebaseStep.Action {
    var title: String {
        switch self {
        case .pick: "Pick"
        case .reword: "Reword"
        case .squash: "Squash"
        case .fixup: "Fixup"
        case .drop: "Delete"
        }
    }

    var symbol: String {
        switch self {
        case .pick: "checkmark.circle"
        case .reword: "pencil"
        case .squash: "arrow.down.right.and.arrow.up.left"
        case .fixup: "arrow.down.to.line"
        case .drop: "trash"
        }
    }
}
