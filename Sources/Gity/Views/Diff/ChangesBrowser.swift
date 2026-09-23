import AppKit
import GitKit
import SwiftUI
import UniformTypeIdentifiers

/// File list on the left, diff of the selected file on the right.
/// Used for both the working copy and commit details. Sections with a staging action
/// get a header button, context menu items and space bar staging.
struct ChangesBrowser: View {
    let model: RepositoryModel
    let sections: [FileSection]
    /// Changing this reloads the visible diff (e.g. when the working copy changes on disk).
    var reloadToken = 0
    /// Shown under the file list, e.g. the commit composer.
    var fileListFooter: AnyView?

    @State private var selection = Set<DiffTarget.ID>()
    /// Files that were just staged or unstaged. Once they reappear in their new section they
    /// are selected again, so the selection follows the file like in Tower.
    @State private var pendingReselection: PendingReselection?

    private struct PendingReselection {
        let paths: Set<String>
        let wereStaged: Set<String>
    }

    private var allTargets: [DiffTarget] { sections.flatMap(\.targets) }
    private var selectedTargets: [DiffTarget] { allTargets.filter { selection.contains($0.id) } }
    private var supportsStaging: Bool { sections.contains { $0.stagingAction != nil } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                fileList
                fileListFooter
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)

            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .onChange(of: allTargets.map(\.id), initial: true) { _, ids in
            if let pending = pendingReselection {
                let moved = allTargets.filter { target in
                    guard let change = target.workingCopyChange, pending.paths.contains(change.path) else { return false }
                    // Only match the entry on the other side, not a leftover half of a partially staged file.
                    return (change.area == .staged) != pending.wereStaged.contains(change.path)
                }
                if !moved.isEmpty {
                    selection = Set(moved.map(\.id))
                    pendingReselection = nil
                    return
                }
                // Not refreshed yet; keep waiting as long as the old selection still exists.
                if !selection.isDisjoint(with: ids) { return }
                pendingReselection = nil
            }

            // Keep the selection when files come and go; otherwise pick the first file.
            selection.formIntersection(ids)
            if selection.isEmpty, let first = ids.first {
                selection = [first]
            }
        }
    }

    private var fileList: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.targets) { target in
                        FileRow(target: target)
                            .tag(target.id)
                    }
                } header: {
                    SectionHeader(section: section) {
                        let changes = section.targets.compactMap(\.workingCopyChange)
                        Task { await model.toggleStaging(changes) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: DiffTarget.ID.self) { ids in
            let targets = allTargets.filter { ids.contains($0.id) }
            if supportsStaging, !targets.isEmpty {
                stagingMenuItems(for: targets)
                Divider()
            }
            if !targets.isEmpty {
                FileContextMenu(model: model, targets: targets)
            }
        }
        .onKeyPress(.space) {
            guard supportsStaging, !selection.isEmpty else { return .ignored }
            toggleStaging(selectedTargets)
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { press in
            // ⌘⌫ discards, as in Tower and the Finder's Move to Trash.
            guard press.modifiers == .command, supportsStaging else { return .ignored }
            let changes = selectedTargets.compactMap(\.workingCopyChange)
            guard !changes.isEmpty else { return .ignored }
            Task { await model.discard(changes) }
            return .handled
        }
    }

    @ViewBuilder
    private var detail: some View {
        let selected = selectedTargets
        if selected.count == 1, let target = selected.first {
            DiffPane(model: model, target: target, reloadToken: reloadToken)
                .id(target.id)
        } else if selected.isEmpty {
            ContentUnavailableView("No File Selected", systemImage: "doc.text.magnifyingglass")
        } else {
            ContentUnavailableView {
                Label("\(selected.count) Files Selected", systemImage: "doc.on.doc")
            } description: {
                if supportsStaging {
                    Text("Press Space to stage or unstage them.")
                }
            }
        }
    }

    @ViewBuilder
    private func stagingMenuItems(for targets: [DiffTarget]) -> some View {
        let changes = targets.compactMap(\.workingCopyChange)
        let conflicted = changes.filter { $0.area == .conflicted }
        let unstaged = targets.filter { $0.workingCopyChange.map { $0.area == .unstaged || $0.area == .untracked } ?? false }
        let staged = targets.filter { $0.workingCopyChange?.area == .staged }
        if !conflicted.isEmpty {
            ConflictMenuItems(model: model, conflicts: conflicted)
            Button(conflicted.count == 1 ? "Mark as Resolved" : "Mark \(conflicted.count) Files as Resolved") {
                toggleStaging(targets.filter { $0.workingCopyChange?.area == .conflicted })
            }
            .help("Stage the file as it is now")
        }
        if !unstaged.isEmpty {
            Button(unstaged.count == 1 ? "Stage" : "Stage \(unstaged.count) Files") {
                toggleStaging(unstaged)
            }
        }
        if !staged.isEmpty {
            Button(staged.count == 1 ? "Unstage" : "Unstage \(staged.count) Files") {
                toggleStaging(staged)
            }
        }
        let discardable = changes.filter { $0.area != .conflicted }
        if !discardable.isEmpty {
            Button(discardable.count == 1 ? "Discard Changes…" : "Discard Changes to \(discardable.count) Files…") {
                Task { await model.discard(discardable) }
            }
        }
    }

    /// Toggles staging for `targets`. The selection follows the files to their new section.
    private func toggleStaging(_ targets: [DiffTarget]) {
        let changes = targets.compactMap(\.workingCopyChange)
        guard !changes.isEmpty else { return }
        pendingReselection = PendingReselection(
            paths: Set(changes.map(\.path)),
            wereStaged: Set(changes.filter { $0.area == .staged }.map(\.path))
        )
        Task { await model.toggleStaging(changes) }
    }
}

private struct SectionHeader: View {
    let section: FileSection
    let action: () -> Void

    var body: some View {
        HStack {
            Text("\(section.title) (\(section.targets.count))")
            Spacer()
            if let stagingAction = section.stagingAction {
                let isConflicts = section.id == "conflicted"
                Button(isConflicts ? "Mark All Resolved" : stagingAction == .stage ? "Stage All" : "Unstage All", action: action)
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(isConflicts ? "Stage every conflicted file as it is now" : stagingAction == .stage ? "Stage every file in this section" : "Unstage every file in this section")
            }
        }
    }
}

/// Resolving conflicts by taking one side. During a rebase git's "ours" is the branch being
/// rebased onto, so the sides are swapped to keep "Mine" meaning the user's own changes.
struct ConflictMenuItems: View {
    let model: RepositoryModel
    let conflicts: [FileChange]

    private var isRebasing: Bool { model.snapshot?.pendingOperation?.kind == .rebase }

    var body: some View {
        Button("Resolve Using Mine") {
            Task { await model.resolveConflicts(conflicts, using: isRebasing ? .theirs : .ours) }
        }
        .help(isRebasing ? "Keep the version from the commit being rebased" : "Keep the version from the current branch")
        Button("Resolve Using Theirs") {
            Task { await model.resolveConflicts(conflicts, using: isRebasing ? .ours : .theirs) }
        }
        .help(isRebasing ? "Keep the version from the branch being rebased onto" : "Keep the version being merged in")
    }
}

struct FileContextMenu: View {
    let model: RepositoryModel
    let targets: [DiffTarget]

    private var target: DiffTarget? { targets.count == 1 ? targets.first : nil }

    var body: some View {
        if let target {
            singleFileItems(target)
        }
        Button(targets.count == 1 ? "Copy Path" : "Copy Paths") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
        }
        if let target {
            let fileURL = model.url.appending(path: target.path)
            let existsOnDisk = FileManager.default.fileExists(atPath: fileURL.path)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
            .disabled(!existsOnDisk)
            Button("Open with Default App") {
                NSWorkspace.shared.open(fileURL)
            }
            .disabled(!existsOnDisk)
        }
    }

    @ViewBuilder
    private func singleFileItems(_ target: DiffTarget) -> some View {
        switch target.source {
        case .workingCopy(let change):
            if change.area == .untracked {
                ignoreMenu(for: change.path)
            } else {
                historyItems(path: change.path, revision: nil)
                if change.area != .staged || change.kind != .added {
                    Button("Stop Tracking") { Task { await model.untrack([change.path]) } }
                        .help("Remove the file from the repository but keep it on disk")
                }
            }
        case .commit(let commit, let file):
            historyItems(path: file.path, revision: commit.sha)
            if file.kind != .deleted {
                Button("Restore This Version to Working Copy…") {
                    Task { await model.restore(paths: [file.path], from: commit.sha, revisionName: commit.shortSHA) }
                }
            }
        }
        Divider()
    }

    @ViewBuilder
    private func historyItems(path: String, revision: String?) -> some View {
        Button("Show File History") {
            model.activeSheet = .fileInspector(FileInspectorRequest(path: path, revision: revision, mode: .history))
        }
        Button("Blame") {
            model.activeSheet = .fileInspector(FileInspectorRequest(path: path, revision: revision, mode: .blame))
        }
    }

    @ViewBuilder
    private func ignoreMenu(for path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        Menu("Ignore") {
            Button("Ignore “\(name)”") {
                Task { await model.ignore(pattern: GitIgnore.pattern(forPath: path)) }
            }
            if let pattern = GitIgnore.pattern(forExtensionOf: path) {
                Button("Ignore All “\(pattern)” Files") {
                    Task { await model.ignore(pattern: pattern) }
                }
            }
            if !directory.isEmpty {
                Button("Ignore Folder “\(directory)”") {
                    Task { await model.ignore(pattern: GitIgnore.pattern(forPath: directory, isDirectory: true)) }
                }
            }
        }
    }
}

struct FileRow: View {
    let target: DiffTarget

    var body: some View {
        HStack(spacing: 7) {
            FileKindBadge(kind: target.kind)

            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (target.path as NSString).pathExtension) ?? .data))
                .resizable()
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 0) {
                Text(target.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !target.directory.isEmpty {
                    Text(target.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        }
        .padding(.vertical, 1)
        .help(helpText)
    }

    private var helpText: String {
        if let originalPath = target.originalPath {
            return "\(target.kind.title): \(originalPath) → \(target.path)"
        }
        return "\(target.kind.title): \(target.path)"
    }
}

struct FileKindBadge: View {
    let kind: FileChange.Kind

    var body: some View {
        Text(kind.letter)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(kind.color.gradient, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .help(kind.title)
    }
}

extension FileChange.Area {
    var title: String {
        switch self {
        case .conflicted: "Conflicts"
        case .staged: "Staged"
        case .unstaged: "Changes"
        case .untracked: "Untracked"
        }
    }
}

extension FileChange.Kind {
    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .untracked: "?"
        case .conflicted: "!"
        }
    }

    var title: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type Changed"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        }
    }

    var color: Color {
        switch self {
        case .modified, .typeChanged: .orange
        case .added, .copied: .green
        case .deleted: .red
        case .renamed: .blue
        case .untracked: .gray
        case .conflicted: .pink
        }
    }
}
