import AppKit
import GitKit
import Observation

enum SidebarItem: Hashable {
    case workingCopy
    case history
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
    private(set) var isFetching = false
    private(set) var isSwitchingBranch = false
    /// Bumped whenever the snapshot actually changes, so dependent views know to reload.
    private(set) var revision = 0

    var selection: SidebarItem?
    var filterText = ""
    var isShowingRepositorySwitcher = false
    var operationError: OperationError?

    private(set) var localBranchTree: [RefTreeNode<Branch>] = []
    private(set) var remoteBranchTrees: [String: [RefTreeNode<Branch>]] = [:]

    /// Replaces the repository shown in this model's window. Set by the window.
    @ObservationIgnored var switchRepository: ((URL) -> Void)?

    @ObservationIgnored private var watcher: RepositoryWatcher?
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
    }

    var name: String { url.lastPathComponent }

    var headDescription: String {
        switch snapshot?.head {
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
    }

    private func validateSelection() {
        guard let snapshot else { return }
        switch selection {
        case .ref(let refName) where branch(refName) == nil && tag(refName) == nil:
            selection = nil
        case .stash(let selector) where !snapshot.stashes.contains(where: { $0.selector == selector }):
            selection = nil
        default:
            break
        }
        #if DEBUG
        // Lets UI snapshot tooling start on a specific pane.
        let debugSelect = ProcessInfo.processInfo.environment["GITY_DEBUG_SELECT"]
        if selection == nil, debugSelect == "workingCopy" {
            selection = .workingCopy
        }
        if revision == 1, debugSelect == "switcher" {
            isShowingRepositorySwitcher = true
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

    func commits(for item: SidebarItem, limit: Int = 500) async throws -> [Commit] {
        guard let client, let snapshot else { return [] }
        // An unborn branch has nothing to log, and `git log` errors on it.
        if case .unborn = snapshot.head, snapshot.localBranches.isEmpty { return [] }

        switch item {
        case .history: return try await client.log(["HEAD", "--branches", "--remotes", "--tags"], limit: limit)
        case .ref(let refName): return try await client.log([refName], limit: limit)
        case .stash(let selector): return try await client.log([selector], limit: limit)
        case .workingCopy: return []
        }
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

    private func performStaging(title: String, _ operation: (GitClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await operation(client)
        } catch {
            operationError = OperationError(title: title, message: error.localizedDescription)
        }
        await refresh()
    }

    // MARK: - Actions

    func checkout(_ branch: Branch) async {
        guard let client, !branch.isHead, !isSwitchingBranch else { return }
        isSwitchingBranch = true
        defer { isSwitchingBranch = false }
        do {
            if branch.isRemote {
                if let existing = snapshot?.localBranches.first(where: { $0.upstream == branch.shortName }) {
                    try await client.switchBranch(existing.name)
                } else {
                    try await client.switchToTrackingBranch(for: branch)
                }
            } else {
                try await client.switchBranch(branch.name)
            }
            await refresh()
            if let current = snapshot?.currentBranch {
                selection = .ref(current.refName)
            }
        } catch {
            operationError = OperationError(title: "Couldn’t check out “\(branch.shortName)”", message: error.localizedDescription)
        }
    }

    func fetch() async {
        guard let client, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            try await client.fetchAll()
            await refresh()
        } catch {
            operationError = OperationError(title: "Fetch failed", message: error.localizedDescription)
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInTerminal() {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
