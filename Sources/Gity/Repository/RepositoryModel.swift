import AppKit
import GitKit
import Observation

enum SidebarItem: Hashable {
    case workingCopy
    case history
    case reflog
    /// A branch or tag, identified by its full ref name (e.g. `refs/heads/main`).
    case ref(String)
    case stash(String)
}

/// State for a single repository window.
@Observable
final class RepositoryModel {
    let url: URL
    private let client: GitClient?

    private(set) var snapshot: RepositorySnapshot? {
        didSet { rebuildTrees() }
    }
    private(set) var loadError: String?
    var isFetching = false
    /// What a running operation is doing, e.g. "Pulling…". Only one operation runs at a time.
    var activity: String?
    var isBusy: Bool { activity != nil }
    /// Bumped whenever the snapshot actually changes, so dependent views know to reload.
    private(set) var revision = 0

    var selection: SidebarItem?
    var filterText = ""
    var isShowingRepositorySwitcher = false
    var operationError: OperationError?
    var activeSheet: RepositorySheet?

    /// The commit message being written, kept per repository across launches.
    var commitMessage = "" {
        didSet { CommitDrafts.save(commitMessage, for: url) }
    }
    var isAmending = false

    /// Undo for git operations, separate from the window's (text editing) undo manager so
    /// each operation is its own undo step no matter how AppKit groups events. Edit › Undo
    /// uses it whenever no text is being edited.
    @ObservationIgnored let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    /// Mirrors `undoManager` so menus update: the names of the next undo and redo, if any.
    private(set) var undoActionName: String?
    private(set) var redoActionName: String?

    func updateUndoState() {
        undoActionName = undoManager.canUndo ? undoManager.undoActionName : nil
        redoActionName = undoManager.canRedo ? undoManager.redoActionName : nil
    }

    private(set) var localBranchTree: [RefTreeNode<Branch>] = []
    private(set) var remoteBranchTrees: [String: [RefTreeNode<Branch>]] = [:]

    /// Replaces the repository shown in this model's window. Set by the window.
    @ObservationIgnored var switchRepository: ((URL) -> Void)?

    @ObservationIgnored private var watcher: RepositoryWatcher?
    @ObservationIgnored private var autoFetchTask: Task<Void, Never>?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var needsAnotherRefresh = false

    struct OperationError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init(url: URL, gitExecutableURL: URL?) {
        self.url = url
        self.client = gitExecutableURL.map { GitClient(repositoryURL: url, executableURL: $0) }
        self.commitMessage = CommitDrafts.load(for: url)
    }

    /// The git client, for operations in extensions. Nil when git isn't installed.
    var git: GitClient? { client }

    var name: String { url.lastPathComponent }

    var headDescription: String {
        // Mid-rebase HEAD is detached, but the branch being rebased is what matters.
        if let operation = snapshot?.pendingOperation, operation.kind == .rebase, let branch = operation.branchName {
            return "\(branch) (rebasing)"
        }
        return switch snapshot?.head {
        case .branch(let name): name
        case .unborn(let name): "\(name) (no commits)"
        case .detached(let sha): "Detached at \(sha.prefix(7))"
        case nil: ""
        }
    }

    // MARK: - Loading

    /// Reloads the snapshot. Concurrent calls coalesce into at most one extra pass.
    func refresh() async {
        guard let client else {
            loadError = "Git couldn’t be found. Set its location in Settings."
            return
        }
        if isRefreshing {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        repeat {
            needsAnotherRefresh = false
            do {
                let newSnapshot = try await client.snapshot()
                if newSnapshot != snapshot {
                    snapshot = newSnapshot
                    revision += 1
                }
                loadError = nil
                validateSelection()
            } catch {
                // Keep showing the last good state on transient errors (e.g. a lock held mid-rebase).
                if snapshot == nil {
                    loadError = error.localizedDescription
                }
            }
        } while needsAnotherRefresh
    }

    func startWatching() {
        guard watcher == nil else { return }
        let watcher = RepositoryWatcher(url: url) { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        autoFetchTask?.cancel()
        autoFetchTask = nil
    }

    /// Fetches shortly after opening and then every few minutes (see Settings), so branches
    /// show how far behind their upstream they are without the user asking.
    func startAutoFetch() {
        guard autoFetchTask == nil else { return }
        autoFetchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            while !Task.isCancelled {
                let minutes = UserDefaults.standard.object(forKey: PreferenceKey.autoFetchMinutes) as? Int ?? 10
                if minutes > 0 {
                    await self?.fetchInBackground()
                }
                // When turned off, check again in a minute in case it's turned back on.
                try? await Task.sleep(for: .seconds(max(minutes, 1) * 60))
            }
        }
    }

    private func fetchInBackground() async {
        guard let client, !isBusy, !isFetching, !(snapshot?.remotes.isEmpty ?? true) else { return }
        isFetching = true
        defer { isFetching = false }
        // Offline or missing credentials: stay quiet, the user didn't ask for this fetch.
        if (try? await client.fetchAll(quiet: true)) != nil {
            await refresh()
        }
    }

    private func validateSelection() {
        guard let snapshot else { return }
        switch selection {
        case .ref(let refName) where branch(refName) == nil && tag(refName) == nil:
            // A deleted or renamed branch: fall back to the current branch.
            selection = nil
        case .stash(let selector) where !snapshot.stashes.contains(where: { $0.selector == selector }):
            selection = nil
        default:
            break
        }
        #if DEBUG
        // Lets UI snapshot tooling start on a specific pane.
        let debugSelect = ProcessInfo.processInfo.environment["GITY_DEBUG_SELECT"]
        if selection == nil {
            switch debugSelect {
            case "workingCopy": selection = .workingCopy
            case "history": selection = .history
            case "reflog": selection = .reflog
            case "stash": selection = snapshot.stashes.first.map { .stash($0.selector) }
            default: break
            }
        }
        if revision == 1, debugSelect == "switcher" {
            isShowingRepositorySwitcher = true
        }
        if revision == 1, let sheet = ProcessInfo.processInfo.environment["GITY_DEBUG_SHEET"] {
            Task { await showDebugSheet(sheet) }
        }
        if revision == 1, let script = ProcessInfo.processInfo.environment["GITY_DEBUG_SCRIPT"] {
            Task { await runDebugScript(script) }
        }
        #endif
        if selection == nil {
            if case .unborn = snapshot.head {
                // Nothing to show in history yet; the files to commit are what matter.
                selection = .workingCopy
            } else {
                selection = snapshot.currentBranch.map { .ref($0.refName) } ?? .history
            }
        }
    }

    #if DEBUG
    /// Drives the model like a user would, logging state after each step, e.g.
    /// `GITY_DEBUG_SCRIPT="stageAll;commit:Message;undo;pull:rebase"`.
    private func runDebugScript(_ script: String) async {
        let logURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GITY_DEBUG_LOG"] ?? "/tmp/gity-debug.log")
        var log = ""
        func record(_ step: String) async {
            let head = await client?.resolve("HEAD").map { String($0.prefix(7)) } ?? "-"
            let changes = snapshot?.status.changes.map { "\($0.area):\($0.path)" }.joined(separator: ",") ?? ""
            let pending = snapshot?.pendingOperation.map { "\($0.kind)" } ?? "none"
            let error = operationError.map { " ERROR[\($0.title): \($0.message)]" } ?? ""
            log += "\(step) -> head=\(head) branch=\(headDescription) pending=\(pending) changes=[\(changes)] undo=\(undoActionName ?? "-") redo=\(redoActionName ?? "-")\(error)\n"
            try? log.write(to: logURL, atomically: true, encoding: .utf8)
            operationError = nil
        }
        try? await Task.sleep(for: .seconds(1))
        await record("start")
        for command in script.split(separator: ";") {
            let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "stageAll":
                await toggleStaging(snapshot?.status.changes.filter { $0.area != .staged } ?? [])
            case "commit":
                commitMessage = argument
                await commit()
            case "amend":
                await setAmending(true)
                commitMessage = argument
                await commit()
            case "undo":
                undoManager.undo()
                try? await Task.sleep(for: .seconds(1.5))
            case "redo":
                undoManager.redo()
                try? await Task.sleep(for: .seconds(1.5))
            case "pull": await pull(rebase: argument == "rebase")
            case "push": await push(force: argument == "force")
            case "fetch": await fetch()
            case "merge": await merge(argument, name: argument)
            case "rebase": await rebase(onto: argument, name: argument)
            case "abort": await abortPendingOperation()
            case "continue": await continuePendingOperation()
            case "ours", "theirs":
                let conflicts = snapshot?.status.changes.filter { $0.area == .conflicted } ?? []
                await resolveConflicts(conflicts, using: parts[0] == "ours" ? .ours : .theirs)
            case "stash": _ = await stash(message: argument, includeUntracked: true)
            case "pop": if let stash = snapshot?.stashes.first { await apply(stash, pop: true) }
            case "drop": if let stash = snapshot?.stashes.first { await drop(stash) }
            case "branch": _ = await createBranch(argument, at: nil, checkout: true)
            case "checkout": if let branch = branch("refs/heads/\(argument)") { await checkout(branch) }
            case "deleteBranch": if let branch = branch("refs/heads/\(argument)") { await delete(branch) }
            case "tag": _ = await createTag(argument, at: "HEAD", message: nil)
            case "discardAll": await discard(snapshot?.status.changes ?? [])
            case "select":
                selection = switch argument {
                case "history": .history
                case "reflog": .reflog
                default: .workingCopy
                }
            case "cherryPick", "revert", "resetHard", "dropCommit", "squash":
                // Argument: a revision, e.g. HEAD~1 or a branch name.
                if let commit = try? await client?.log([argument], limit: 1).first {
                    switch parts[0] {
                    case "cherryPick": await cherryPick([commit])
                    case "revert": await revert(commit)
                    case "resetHard": await reset(to: commit, mode: .hard)
                    case "dropCommit": await dropCommit(commit)
                    default:
                        await squashIntoParent(commit)
                        if case .editMessage(let request) = activeSheet {
                            activeSheet = nil
                            await request.save(request.message)
                        }
                    }
                }
            case "wait": try? await Task.sleep(for: .seconds(Double(argument) ?? 2))
            case "sheet": await showDebugSheet(argument)
            default: log += "unknown command \(command)\n"
            }
            await record(String(command))
            try? await Task.sleep(for: .seconds(0.5))
        }
        log += "done\n"
        try? log.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func showDebugSheet(_ name: String) async {
        switch name {
        case "newBranch": activeSheet = .newBranch(startPoint: nil, startPointName: headDescription)
        case "stash": activeSheet = .stash
        case "push": activeSheet = .push(branch: currentBranch?.name ?? "main")
        case "rebase":
            if let commit = try? await client?.log(["HEAD~2"], limit: 1).first { activeSheet = .interactiveRebase(commit) }
        case let name where name.hasPrefix("history:"):
            activeSheet = .fileInspector(FileInspectorRequest(path: String(name.dropFirst(8)), revision: nil, mode: .history))
        case let name where name.hasPrefix("blame:"):
            activeSheet = .fileInspector(FileInspectorRequest(path: String(name.dropFirst(6)), revision: nil, mode: .blame))
        default: break
        }
    }
    #endif

    private func rebuildTrees() {
        guard let snapshot else {
            localBranchTree = []
            remoteBranchTrees = [:]
            return
        }
        // The current branch is pinned above the tree, so leave it out of the folders.
        localBranchTree = RefTree.build(snapshot.localBranches.filter { !$0.isHead }, idPrefix: "refs/heads/", path: \.name)
        remoteBranchTrees = Dictionary(uniqueKeysWithValues: snapshot.remotes.map { remote in
            (remote.name, RefTree.build(remote.branches, idPrefix: "refs/remotes/\(remote.name)/", path: \.name))
        })
    }

    // MARK: - Lookup

    func branch(_ refName: String) -> Branch? {
        guard let snapshot else { return nil }
        return snapshot.localBranches.first { $0.refName == refName }
            ?? snapshot.remotes.lazy.flatMap(\.branches).first { $0.refName == refName }
    }

    func tag(_ refName: String) -> Tag? {
        snapshot?.tags.first { $0.refName == refName }
    }

    func stash(_ selector: String) -> Stash? {
        snapshot?.stashes.first { $0.selector == selector }
    }

    var currentBranch: Branch? { snapshot?.currentBranch }

    /// What `HEAD` points at, to switch back to later: a branch name, or a SHA when detached.
    var headReference: (name: String, isDetached: Bool)? {
        switch snapshot?.head {
        case .branch(let name): (name, false)
        case .detached(let sha): (sha, true)
        case .unborn, nil: nil
        }
    }

    func commits(for item: SidebarItem, limit: Int = 500) async throws -> [Commit] {
        guard let client, let snapshot else { return [] }
        // An unborn branch has nothing to log, and `git log` errors on it.
        if case .unborn = snapshot.head, snapshot.localBranches.isEmpty { return [] }

        switch item {
        case .history: return try await client.log(["HEAD", "--branches", "--remotes", "--tags"], limit: limit)
        case .ref(let refName): return try await client.log([refName], limit: limit)
        case .stash(let selector): return try await client.log([selector], limit: limit)
        case .reflog: return try await client.reflog(limit: limit)
        case .workingCopy: return []
        }
    }

    func stashCommit(_ selector: String) async throws -> Commit? {
        try await client?.stashCommit(selector)
    }

    func fileHistory(path: String) async throws -> [FileHistoryEntry] {
        try await client?.fileHistory(path: path) ?? []
    }

    func blame(path: String, revision: String?) async throws -> Blame {
        try await client?.blame(path: path, revision: revision) ?? Blame()
    }

    /// Commits a history rewrite can touch, and which of them aren't pushed yet.
    func rewritableCommits() async -> (all: Set<String>, unpushed: Set<String>?) {
        guard let client, currentBranch != nil else { return ([], nil) }
        return (try? await client.rewritableCommits()) ?? ([], nil)
    }

    // MARK: - Diffs

    func diff(for target: DiffTarget, options: DiffOptions, maxLines: Int?) async throws -> FileDiff {
        guard let client else { return FileDiff() }
        switch target.source {
        case .workingCopy(let change):
            return try await client.diff(for: change, options: options, maxLines: maxLines)
        case .commit(let commit, let file):
            return try await client.diff(for: file, in: commit, options: options, maxLines: maxLines)
        }
    }

    func changedFiles(in commit: Commit) async throws -> [CommitFileChange] {
        try await client?.changedFiles(in: commit) ?? []
    }

    func message(of commit: Commit) async throws -> String {
        try await client?.message(of: commit) ?? commit.subject
    }

    // MARK: - Staging

    /// Stages unstaged, untracked and conflicted files and unstages staged ones.
    func toggleStaging(_ changes: [FileChange]) async {
        let toUnstage = changes.filter { $0.area == .staged }
        let toStage = changes.filter { $0.area != .staged }
        await performStaging(title: "Couldn’t update the staging area") { client in
            try await client.stage(paths: toStage.map(\.path))
            // A staged rename lives at two paths; both must leave the index together.
            try await client.unstage(paths: toUnstage.flatMap { [$0.originalPath, $0.path].compactMap { $0 } })
        }
    }

    func performStaging(title: String, _ operation: (GitClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await operation(client)
        } catch {
            operationError = OperationError(title: title, message: error.localizedDescription)
        }
        await refresh()
    }

    // MARK: - Actions

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInTerminal() {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
