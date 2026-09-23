import AppKit
import GitKit

/// Everything that changes the repository. Operations run one at a time (`activity`), refresh
/// afterwards, report errors in an alert and register undo where it makes sense.
extension RepositoryModel {
    private var autostash: Bool {
        UserDefaults.standard.object(forKey: PreferenceKey.autostash) as? Bool ?? true
    }

    private var pullRebases: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.pullRebases)
    }

    // MARK: - Running operations

    /// Runs `body` as the window's single running operation.
    /// - Returns: Whether it succeeded.
    @discardableResult
    func perform(_ activity: String, failure: String, _ body: (GitClient) async throws -> Void) async -> Bool {
        guard let client = git else { return false }
        guard !isBusy else {
            NSSound.beep()
            return false
        }
        self.activity = activity
        defer { self.activity = nil }
        do {
            try await body(client)
            await refresh()
            return true
        } catch {
            await refresh()
            if let snapshot, snapshot.pendingOperation != nil, snapshot.hasConflicts {
                // Stopped at conflicts: the banner explains what happened and how to go on.
                selection = .workingCopy
            } else {
                operationError = OperationError(title: failure, message: error.localizedDescription)
            }
            return false
        }
    }

    /// Runs an operation that moves `HEAD` (commit, merge, reset…) and registers an undo that moves it back.
    /// - Parameter undoTarget: Where undo goes; defaults to where `HEAD` was before.
    @discardableResult
    func performMovingHead(
        _ activity: String, failure: String, undoName: String, undoMode: ResetMode = .keep,
        undoTarget: String? = nil,
        _ body: (GitClient) async throws -> Void
    ) async -> Bool {
        let before: String? = if let undoTarget { undoTarget } else { await git?.resolve("HEAD") }
        let succeeded = await perform(activity, failure: failure, body)
        if succeeded, snapshot?.pendingOperation == nil, let before, let after = await git?.resolve("HEAD"), after != before {
            registerUndo(GitUndoRecord(
                name: undoName,
                undo: [.moveHead(from: after, to: before, mode: undoMode)],
                redo: [.moveHead(from: before, to: after, mode: undoMode)]
            ))
        }
        return succeeded
    }

    func showError(_ title: String, _ message: String) {
        operationError = OperationError(title: title, message: message)
    }

    // MARK: - Undo

    func registerUndo(_ record: GitUndoRecord) {
        guard !record.undo.isEmpty else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.performUndo(record) }
        }
        undoManager.setActionName(record.name)
        undoManager.endUndoGrouping()
        updateUndoState()
    }

    private func performUndo(_ record: GitUndoRecord) {
        // Registering while undoing puts the inverse on the redo stack, and vice versa.
        registerUndo(record.reversed)
        Task {
            let succeeded = await perform("Undoing \(record.name)…", failure: "Couldn’t undo \(record.name)") { client in
                for step in record.undo {
                    try await execute(step, client: client)
                }
            }
            // The repository no longer matches what the remaining steps expect.
            if !succeeded { undoManager.removeAllActions() }
            updateUndoState()
        }
    }

    func undo() {
        guard undoManager.canUndo, !isBusy else { return }
        undoManager.undo()
        updateUndoState()
    }

    func redo() {
        guard undoManager.canRedo, !isBusy else { return }
        undoManager.redo()
        updateUndoState()
    }

    private struct UndoError: LocalizedError {
        let errorDescription: String?
    }

    private func execute(_ step: GitUndoStep, client: GitClient) async throws {
        switch step {
        case .moveHead(let from, let to, let mode):
            guard await client.resolve("HEAD") == from else {
                throw UndoError(errorDescription: "The branch has changed since, so this can no longer be undone.")
            }
            try await client.reset(to: to, mode: mode)
        case .setRef(let ref, let object):
            if let object {
                try await client.updateRef(ref, to: object)
            } else {
                try await client.deleteRef(ref)
            }
        case .renameBranch(let from, let to):
            try await client.renameBranch(from, to: to)
        case .switchTo(let target, let isDetached):
            if isDetached {
                try await client.checkoutDetached(target)
            } else {
                try await client.switchBranch(target)
            }
        case .storeStash(let sha, let message):
            try await client.storeStash(sha, message: message)
        case .popStash(let sha), .dropStash(let sha):
            guard let selector = try await client.stashSelectors()[sha] else {
                throw UndoError(errorDescription: "The stash no longer exists.")
            }
            if case .popStash = step {
                try await client.applyStash(selector, pop: true)
            } else {
                try await client.dropStash(selector)
            }
        }
    }

    // MARK: - Committing

    var stagedChanges: [FileChange] {
        snapshot?.status.changes.filter { $0.area == .staged } ?? []
    }

    func setAmending(_ amending: Bool) async {
        isAmending = amending
        guard let client = git else { return }
        let headMessage = (try? await client.headMessage()) ?? ""
        if amending, commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitMessage = headMessage
        } else if !amending, commitMessage == headMessage {
            commitMessage = ""
        }
    }

    /// Prefills the message git prepared for a merge or conflicted cherry-pick, without its comments.
    func adoptPreparedMessage() {
        guard commitMessage.isEmpty, let message = snapshot?.pendingOperation?.message else { return }
        commitMessage = message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let snapshot else { return }
        let amend = isAmending

        if stagedChanges.isEmpty, !amend, snapshot.pendingOperation?.kind != .merge {
            let unstaged = snapshot.status.changes.filter { $0.area != .staged && $0.area != .conflicted }
            guard !unstaged.isEmpty else { return }
            let answer = await Confirmation.ask(
                "Stage all changes and commit?",
                message: "No changes are staged. Gity can stage all \(unstaged.count) changed file\(unstaged.count == 1 ? "" : "s") and commit them.",
                confirmTitle: "Stage All and Commit"
            )
            guard answer.confirmed else { return }
            await performStaging(title: "Couldn’t stage changes") { client in
                try await client.stage(paths: unstaged.map(\.path))
            }
        }

        let succeeded = await performMovingHead(
            amend ? "Amending…" : "Committing…",
            failure: amend ? "Couldn’t amend the commit" : "Couldn’t commit",
            undoName: amend ? "Amend Commit" : "Commit",
            undoMode: .soft
        ) { client in
            try await client.commit(message: message, amend: amend)
        }
        if succeeded {
            commitMessage = ""
            isAmending = false
        }
    }

    // MARK: - Working copy

    func discard(_ changes: [FileChange]) async {
        let changes = changes.filter { $0.area != .conflicted }
        guard !changes.isEmpty else { return }
        let title = changes.count == 1
            ? "Discard changes to “\((changes[0].path as NSString).lastPathComponent)”?"
            : "Discard changes to \(changes.count) files?"
        let answer = await Confirmation.ask(
            title,
            message: "This can’t be undone. New files are moved to the Trash.",
            confirmTitle: "Discard",
            isDestructive: true
        )
        guard answer.confirmed else { return }

        let isUnborn = if case .unborn = snapshot?.head { true } else { false }
        await perform("Discarding…", failure: "Couldn’t discard changes") { client in
            let untracked = changes.filter { $0.area == .untracked }
            let unstaged = changes.filter { $0.area == .unstaged }
            let staged = changes.filter { $0.area == .staged }

            try await client.discardUnstagedChanges(paths: unstaged.map(\.path))
            if isUnborn {
                // Nothing to go back to before the first commit: unstage, then trash like new files.
                try await client.untrack(paths: staged.map(\.path))
                try trash(staged.map(\.path))
            } else {
                try await client.discardAllChanges(paths: staged.flatMap { [$0.originalPath, $0.path].compactMap { $0 } })
            }
            try trash(untracked.map(\.path))
        }
    }

    private func trash(_ paths: [String]) throws {
        for path in paths {
            let fileURL = url.appending(path: path)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        }
    }

    /// Stages, unstages or discards some lines of a file, using a patch built from its diff.
    func applyLines(_ lines: Set<DiffLineID>, of diff: FileDiff, change: FileChange, discard: Bool) async {
        let isStaged = change.area == .staged
        let direction: PatchBuilder.Direction = isStaged || discard ? .reverse : .forward
        guard let patch = PatchBuilder.patch(from: diff, selecting: lines, direction: direction) else { return }

        if discard {
            let answer = await Confirmation.ask(
                "Discard \(lines.count) changed line\(lines.count == 1 ? "" : "s")?",
                message: "This can’t be undone.",
                confirmTitle: "Discard",
                isDestructive: true
            )
            guard answer.confirmed else { return }
        }
        await performStaging(title: discard ? "Couldn’t discard the lines" : isStaged ? "Couldn’t unstage the lines" : "Couldn’t stage the lines") { client in
            try await client.apply(patch: patch, toIndex: !discard, reverse: direction == .reverse)
        }
    }

    func ignore(pattern: String) async {
        do {
            try GitIgnore.append(pattern, inRepositoryAt: url)
        } catch {
            showError("Couldn’t update .gitignore", error.localizedDescription)
        }
        await refresh()
    }

    func untrack(_ paths: [String]) async {
        await perform("Untracking…", failure: "Couldn’t stop tracking the file") { client in
            try await client.untrack(paths: paths)
        }
    }

    func restore(paths: [String], from revision: String, revisionName: String) async {
        let answer = await Confirmation.ask(
            paths.count == 1
                ? "Restore “\((paths[0] as NSString).lastPathComponent)” from \(revisionName)?"
                : "Restore \(paths.count) files from \(revisionName)?",
            message: "The working copy version is replaced. Uncommitted changes to it are lost.",
            confirmTitle: "Restore",
            isDestructive: true
        )
        guard answer.confirmed else { return }
        await perform("Restoring…", failure: "Couldn’t restore the file") { client in
            try await client.restore(paths: paths, from: revision)
        }
    }

    // MARK: - Conflicts

    func resolveConflicts(_ changes: [FileChange], using side: GitClient.ConflictSide) async {
        await performStaging(title: "Couldn’t resolve the conflict") { client in
            for change in changes {
                try await client.resolveConflict(path: change.path, using: side)
            }
        }
    }

    func continuePendingOperation() async {
        guard let operation = snapshot?.pendingOperation else { return }
        // Undo goes back to before the whole operation: ORIG_HEAD for a rebase, which has moved HEAD since.
        let undoTarget = operation.kind == .rebase ? await git?.resolve("ORIG_HEAD") : nil
        await performMovingHead(
            "Continuing \(operation.title.lowercased())…",
            failure: "Couldn’t continue the \(operation.title.lowercased())",
            undoName: operation.title,
            undoTarget: undoTarget
        ) { client in
            if operation.kind == .merge {
                try await client.commitWithPreparedMessage()
            } else {
                try await client.continueOperation(operation.kind)
            }
        }
        if snapshot?.pendingOperation == nil { commitMessage = "" }
    }

    func abortPendingOperation() async {
        guard let operation = snapshot?.pendingOperation else { return }
        let answer = await Confirmation.ask(
            "Abort the \(operation.title.lowercased())?",
            message: "The repository goes back to how it was before the \(operation.title.lowercased()) started. Conflict resolutions made so far are lost.",
            confirmTitle: "Abort \(operation.title)",
            isDestructive: true
        )
        guard answer.confirmed else { return }
        await perform("Aborting…", failure: "Couldn’t abort the \(operation.title.lowercased())") { client in
            try await client.abortOperation(operation.kind)
        }
        commitMessage = ""
    }

    func skipRebaseStep() async {
        await perform("Skipping commit…", failure: "Couldn’t skip the commit") { client in
            try await client.skipRebaseStep()
        }
    }

    // MARK: - Remotes

    func fetch() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        await perform("Fetching…", failure: "Fetch failed") { client in
            try await client.fetchAll(quiet: false)
        }
    }

    /// - Parameter rebase: Overrides the Pull preference.
    func pull(rebase: Bool? = nil) async {
        guard let branch = currentBranch else {
            showError("Can’t pull", "Check out a branch to pull into it.")
            return
        }
        guard let upstream = branch.upstream, !branch.isUpstreamGone else {
            showError(
                "“\(branch.name)” has no upstream branch",
                "Push the branch first, or choose the remote branch it tracks from its context menu in the sidebar."
            )
            return
        }
        let rebase = rebase ?? pullRebases
        await performMovingHead(
            rebase ? "Pulling with rebase…" : "Pulling…",
            failure: "Couldn’t pull from \(upstream)",
            undoName: "Pull"
        ) { client in
            try await client.pull(rebase: rebase, autostash: autostash)
        }
    }

    func push(force: Bool = false) async {
        guard let branch = currentBranch else {
            showError("Can’t push", "Check out a branch to push it.")
            return
        }
        guard let snapshot, !snapshot.remotes.isEmpty else {
            showError("Can’t push", "This repository has no remotes to push to.")
            return
        }
        // The first push picks a remote and creates the upstream.
        guard let upstream = branch.upstream, !branch.isUpstreamGone,
              let remoteBranch = snapshot.remotes.flatMap(\.branches).first(where: { $0.shortName == upstream }),
              case .remote(let remote) = remoteBranch.kind
        else {
            activeSheet = .push(branch: branch.name)
            return
        }

        if force {
            let answer = await Confirmation.ask(
                "Force push “\(branch.name)” to \(upstream)?",
                message: "Commits on \(upstream) that aren’t in your branch are removed from the remote. The push is refused if someone else pushed since your last fetch.",
                confirmTitle: "Force Push",
                isDestructive: true
            )
            guard answer.confirmed else { return }
        }
        await perform(force ? "Force pushing…" : "Pushing…", failure: "Couldn’t push to \(upstream)") { client in
            try await client.push(remote: remote, branch: remoteBranch.name, forceWithLease: force)
        }
    }

    /// First push of a branch, from the push sheet.
    func push(branch: String, to remote: String, as remoteName: String, track: Bool) async -> Bool {
        await perform("Pushing…", failure: "Couldn’t push to \(remote)") { client in
            try await client.push(remote: remote, branch: remoteName, setUpstream: track)
        }
    }

    // MARK: - Branches

    func checkout(_ branch: Branch) async {
        guard !branch.isHead else { return }
        let previous = headReference
        var target = branch.name
        let succeeded = await perform("Switching to \(branch.shortName)…", failure: "Couldn’t check out “\(branch.shortName)”") { client in
            if branch.isRemote {
                if let existing = snapshot?.localBranches.first(where: { $0.upstream == branch.shortName }) {
                    target = existing.name
                    try await client.switchBranch(existing.name)
                } else {
                    try await client.switchToTrackingBranch(for: branch)
                }
            } else {
                try await client.switchBranch(branch.name)
            }
        }
        guard succeeded else { return }
        if let current = currentBranch {
            selection = .ref(current.refName)
        }
        if let previous {
            registerUndo(GitUndoRecord(
                name: "Check Out",
                undo: [.switchTo(previous.name, isDetached: previous.isDetached)],
                redo: [.switchTo(target, isDetached: false)]
            ))
        }
    }

    func checkoutDetached(_ revision: String, name: String) async {
        let answer = await Confirmation.ask(
            "Check out \(name)?",
            message: "You won’t be on a branch (a “detached HEAD”). Create a branch there if you want to keep commits you make.",
            confirmTitle: "Check Out"
        )
        guard answer.confirmed else { return }
        let previous = headReference
        let succeeded = await perform("Checking out \(name)…", failure: "Couldn’t check out \(name)") { client in
            try await client.checkoutDetached(revision)
        }
        if succeeded {
            selection = .history
            if let previous {
                registerUndo(GitUndoRecord(
                    name: "Check Out",
                    undo: [.switchTo(previous.name, isDetached: previous.isDetached)],
                    redo: [.switchTo(revision, isDetached: true)]
                ))
            }
        }
    }

    func createBranch(_ name: String, at startPoint: String?, checkout: Bool) async -> Bool {
        let previous = headReference
        let succeeded = await perform("Creating branch…", failure: "Couldn’t create “\(name)”") { client in
            try await client.createBranch(name, at: startPoint, checkout: checkout)
        }
        guard succeeded else { return false }
        let ref = "refs/heads/\(name)"
        if checkout { selection = .ref(ref) }
        if let sha = await git?.resolve(ref) {
            let switchBack: [GitUndoStep] = checkout ? previous.map { [.switchTo($0.name, isDetached: $0.isDetached)] } ?? [] : []
            registerUndo(GitUndoRecord(
                name: "Create Branch",
                undo: switchBack + [.setRef(ref, object: nil)],
                redo: [.setRef(ref, object: sha)] + (checkout ? [.switchTo(name, isDetached: false)] : [])
            ))
        }
        return true
    }

    func renameBranch(_ branch: Branch, to newName: String) async -> Bool {
        let succeeded = await perform("Renaming branch…", failure: "Couldn’t rename “\(branch.name)”") { client in
            try await client.renameBranch(branch.name, to: newName)
        }
        if succeeded {
            if selection == .ref(branch.refName) { selection = .ref("refs/heads/\(newName)") }
            registerUndo(GitUndoRecord(
                name: "Rename Branch",
                undo: [.renameBranch(from: newName, to: branch.name)],
                redo: [.renameBranch(from: branch.name, to: newName)]
            ))
        }
        return succeeded
    }

    func delete(_ branch: Branch) async {
        guard !branch.isHead else {
            showError("Can’t delete the current branch", "Check out another branch first.")
            return
        }
        if branch.isRemote {
            await deleteRemote(branch)
            return
        }

        let remoteUpstream = branch.upstream.flatMap { upstream in
            branch.isUpstreamGone ? nil : snapshot?.remotes.flatMap(\.branches).first { $0.shortName == upstream }
        }
        let answer = await Confirmation.ask(
            "Delete branch “\(branch.name)”?",
            message: "You can undo this with Edit › Undo.",
            confirmTitle: "Delete",
            isDestructive: true,
            checkbox: remoteUpstream.map { "Also delete “\($0.shortName)” on the remote" }
        )
        guard answer.confirmed else { return }

        var force = false
        guard let client = git else { return }
        do {
            try await client.deleteBranch(branch.name, force: false)
        } catch let error as GitError where error.standardError.contains("not fully merged") {
            let forceAnswer = await Confirmation.ask(
                "“\(branch.name)” isn’t fully merged",
                message: "It has commits that aren’t on any other branch. Delete it anyway?",
                confirmTitle: "Delete Anyway",
                isDestructive: true
            )
            guard forceAnswer.confirmed else { return }
            force = true
        } catch {
            showError("Couldn’t delete “\(branch.name)”", error.localizedDescription)
            return
        }

        await perform("Deleting branch…", failure: "Couldn’t delete “\(branch.name)”") { client in
            if force { try await client.deleteBranch(branch.name, force: true) }
            if answer.isChecked, let remoteUpstream, case .remote(let remote) = remoteUpstream.kind {
                try await client.deleteRemoteBranch(remoteUpstream.name, remote: remote)
            }
        }
        // Offered even if deleting the remote branch failed: the local one may be gone already.
        guard self.branch(branch.refName) == nil else { return }
        registerUndo(GitUndoRecord(
            name: "Delete Branch",
            undo: [.setRef(branch.refName, object: branch.tipSHA)],
            redo: [.setRef(branch.refName, object: nil)]
        ))
    }

    private func deleteRemote(_ branch: Branch) async {
        guard case .remote(let remote) = branch.kind else { return }
        let answer = await Confirmation.ask(
            "Delete “\(branch.shortName)” from \(remote)?",
            message: "The branch is removed from the remote for everyone. This can’t be undone from Gity.",
            confirmTitle: "Delete",
            isDestructive: true
        )
        guard answer.confirmed else { return }
        await perform("Deleting remote branch…", failure: "Couldn’t delete “\(branch.shortName)”") { client in
            try await client.deleteRemoteBranch(branch.name, remote: remote)
        }
    }

    func setUpstream(of branch: Branch, to upstream: Branch?) async {
        await perform("Updating upstream…", failure: "Couldn’t change the upstream of “\(branch.name)”") { client in
            try await client.setUpstream(of: branch.name, to: upstream?.shortName)
        }
    }

    // MARK: - Merging and rebasing

    func merge(_ revision: String, name: String) async {
        guard let current = currentBranch else {
            showError("Can’t merge", "Check out the branch to merge into first.")
            return
        }
        await performMovingHead("Merging \(name)…", failure: "Couldn’t merge “\(name)” into “\(current.name)”", undoName: "Merge") { client in
            try await client.merge(revision, autostash: autostash)
        }
    }

    func rebase(onto revision: String, name: String) async {
        guard let current = currentBranch else {
            showError("Can’t rebase", "Check out the branch to rebase first.")
            return
        }
        await performMovingHead("Rebasing onto \(name)…", failure: "Couldn’t rebase “\(current.name)” onto “\(name)”", undoName: "Rebase") { client in
            try await client.rebase(onto: revision, autostash: autostash)
        }
    }

    // MARK: - Commits

    private var currentBranchName: String {
        currentBranch.map { "“\($0.name)”" } ?? "HEAD"
    }

    /// - Parameter commits: In any order; they're applied oldest first.
    func cherryPick(_ commits: [Commit]) async {
        let ordered = commits.sorted { $0.authorDate < $1.authorDate }
        await performMovingHead("Cherry-picking…", failure: "Couldn’t cherry-pick onto \(currentBranchName)", undoName: "Cherry-Pick") { client in
            try await client.cherryPick(ordered)
        }
    }

    func revert(_ commit: Commit) async {
        await performMovingHead("Reverting…", failure: "Couldn’t revert \(commit.shortSHA)", undoName: "Revert") { client in
            try await client.revert(commit)
        }
    }

    func reset(to commit: Commit, mode: ResetMode) async {
        if mode == .hard {
            let answer = await Confirmation.ask(
                "Reset \(currentBranchName) to \(commit.shortSHA) and discard all changes?",
                message: "Uncommitted changes are lost for good. The branch can be moved back with Edit › Undo.",
                confirmTitle: "Reset",
                isDestructive: true
            )
            guard answer.confirmed else { return }
        }
        // Undoing a hard reset can't bring back discarded changes, but it must not destroy new ones either.
        await performMovingHead("Resetting…", failure: "Couldn’t reset to \(commit.shortSHA)", undoName: "Reset", undoMode: mode == .hard ? .keep : mode) { client in
            try await client.reset(to: commit.sha, mode: mode)
        }
    }

    func createTag(_ name: String, at target: String, message: String?) async -> Bool {
        let succeeded = await perform("Creating tag…", failure: "Couldn’t create tag “\(name)”") { client in
            try await client.createTag(name, at: target, message: message)
        }
        let ref = "refs/tags/\(name)"
        if succeeded, let object = await git?.objectName(ofRef: ref) {
            registerUndo(GitUndoRecord(name: "Create Tag", undo: [.setRef(ref, object: nil)], redo: [.setRef(ref, object: object)]))
        }
        return succeeded
    }

    func delete(_ tag: Tag) async {
        let remote = snapshot?.remotes.first { $0.name == "origin" } ?? snapshot?.remotes.first
        let answer = await Confirmation.ask(
            "Delete tag “\(tag.name)”?",
            message: "You can undo deleting the local tag with Edit › Undo.",
            confirmTitle: "Delete",
            isDestructive: true,
            checkbox: remote.map { "Also delete it from “\($0.name)”" }
        )
        guard answer.confirmed, let client = git else { return }
        let object = await client.objectName(ofRef: tag.refName)
        let succeeded = await perform("Deleting tag…", failure: "Couldn’t delete tag “\(tag.name)”") { client in
            try await client.deleteTag(tag.name)
            if answer.isChecked, let remote {
                try await client.deleteRemoteTag(tag.name, remote: remote.name)
            }
        }
        if succeeded, let object {
            registerUndo(GitUndoRecord(name: "Delete Tag", undo: [.setRef(tag.refName, object: object)], redo: [.setRef(tag.refName, object: nil)]))
        }
    }

    func push(_ tag: Tag, to remote: String) async {
        await perform("Pushing tag…", failure: "Couldn’t push “\(tag.name)” to \(remote)") { client in
            try await client.pushTag(tag.name, to: remote)
        }
    }

    // MARK: - Rewriting history

    /// Checks history from `commit` up can be rewritten, and asks first if it was already pushed.
    private func confirmRewriting(_ commit: Commit, action: String) async -> Bool {
        let rewritable = await rewritableCommits()
        guard rewritable.all.contains(commit.sha) else {
            showError("Can’t \(action.lowercased()) this commit", "Only commits on the current branch can be changed.")
            return false
        }
        if (try? await git?.hasMerges(after: commit.parents.first)) != false {
            showError(
                "Can’t \(action.lowercased()) this commit",
                "Commits after \(commit.shortSHA) include a merge, which rewriting history would flatten."
            )
            return false
        }
        guard let unpushed = rewritable.unpushed, !unpushed.contains(commit.sha) else { return true }
        let answer = await Confirmation.ask(
            "\(commit.shortSHA) was already pushed",
            message: "Changing it rewrites history others may have. You’ll need to force push afterwards.",
            confirmTitle: action
        )
        return answer.confirmed
    }

    /// Runs an interactive rebase starting at `commit` (inclusive).
    @discardableResult
    func rebaseInteractively(from commit: Commit, steps: [RebaseStep], name: String = "Interactive Rebase") async -> Bool {
        await performMovingHead("Rewriting history…", failure: "Couldn’t rewrite history", undoName: name) { client in
            try await client.interactiveRebase(steps: steps, base: commit.parents.first, autostash: autostash)
        }
    }

    func editMessage(of commit: Commit) async {
        guard let client = git, await confirmRewriting(commit, action: "Edit Message") else { return }
        let message = (try? await client.message(of: commit)) ?? commit.subject
        activeSheet = .editMessage(MessageEditRequest(title: "Edit Commit Message", confirmTitle: "Save", message: message) { [weak self] newMessage in
            await self?.reword(commit, message: newMessage)
        })
    }

    private func reword(_ commit: Commit, message: String) async {
        guard let client = git else { return }
        if await client.resolve("HEAD") == commit.sha {
            await performMovingHead("Rewording…", failure: "Couldn’t change the message", undoName: "Edit Message") { client in
                try await client.rewordHead(message: message)
            }
            return
        }
        guard let plan = try? await client.commitsForRebase(from: commit) else { return }
        let steps = plan.map { RebaseStep(sha: $0.sha, action: $0.sha == commit.sha ? .reword : .pick, message: $0.sha == commit.sha ? message : nil) }
        await rebaseInteractively(from: commit, steps: steps, name: "Edit Message")
    }

    func squashIntoParent(_ commit: Commit) async {
        guard let client = git, let parentSHA = commit.parents.first, !commit.isMerge else { return }
        guard let parent = try? await client.log([parentSHA], limit: 1).first, !parent.isMerge else {
            showError("Can’t squash this commit", "Its parent is a merge commit.")
            return
        }
        guard await confirmRewriting(parent, action: "Squash") else { return }
        let parentMessage = (try? await client.message(of: parent)) ?? parent.subject
        let message = (try? await client.message(of: commit)) ?? commit.subject
        activeSheet = .editMessage(MessageEditRequest(
            title: "Squash into Parent",
            confirmTitle: "Squash",
            message: parentMessage + "\n\n" + message
        ) { [weak self] combined in
            guard let self, let plan = try? await client.commitsForRebase(from: parent) else { return }
            let steps = plan.map { step -> RebaseStep in
                switch step.sha {
                case parent.sha: RebaseStep(sha: step.sha, action: .pick, message: combined)
                case commit.sha: RebaseStep(sha: step.sha, action: .squash)
                default: RebaseStep(sha: step.sha)
                }
            }
            await self.rebaseInteractively(from: parent, steps: steps, name: "Squash")
        })
    }

    func dropCommit(_ commit: Commit) async {
        guard let client = git, !commit.isMerge, await confirmRewriting(commit, action: "Delete") else { return }
        let answer = await Confirmation.ask(
            "Delete commit “\(commit.subject)”?",
            message: "Its changes are removed from the branch. You can undo this with Edit › Undo.",
            confirmTitle: "Delete Commit",
            isDestructive: true
        )
        guard answer.confirmed, let plan = try? await client.commitsForRebase(from: commit) else { return }
        let steps = plan.map { RebaseStep(sha: $0.sha, action: $0.sha == commit.sha ? .drop : .pick) }
        await rebaseInteractively(from: commit, steps: steps, name: "Delete Commit")
    }

    func startInteractiveRebase(from commit: Commit) async {
        guard await confirmRewriting(commit, action: "Rebase") else { return }
        activeSheet = .interactiveRebase(commit)
    }

    // MARK: - Stashes

    func stash(message: String?, includeUntracked: Bool) async -> Bool {
        let previous = await git?.objectName(ofRef: "stash@{0}")
        let succeeded = await perform("Stashing…", failure: "Couldn’t stash changes") { client in
            try await client.stash(message: message, includeUntracked: includeUntracked)
        }
        // With nothing to stash git succeeds without making one.
        if succeeded, let sha = await git?.objectName(ofRef: "stash@{0}"), sha != previous {
            registerUndo(GitUndoRecord(name: "Stash", undo: [.popStash(sha: sha)], redo: []))
        }
        return succeeded
    }

    func apply(_ stash: Stash, pop: Bool) async {
        let succeeded = await perform(pop ? "Applying and deleting stash…" : "Applying stash…", failure: "Couldn’t apply the stash") { client in
            try await client.applyStash(stash.selector, pop: pop)
        }
        if succeeded { selection = .workingCopy }
    }

    func drop(_ stash: Stash) async {
        let answer = await Confirmation.ask(
            "Delete stash “\(stash.message)”?",
            message: "You can undo this with Edit › Undo.",
            confirmTitle: "Delete",
            isDestructive: true
        )
        guard answer.confirmed, let sha = await git?.objectName(ofRef: stash.selector) else { return }
        let succeeded = await perform("Deleting stash…", failure: "Couldn’t delete the stash") { client in
            try await client.dropStash(stash.selector)
        }
        if succeeded {
            registerUndo(GitUndoRecord(
                name: "Delete Stash",
                undo: [.storeStash(sha: sha, message: stash.message)],
                redo: [.dropStash(sha: sha)]
            ))
        }
    }
}
