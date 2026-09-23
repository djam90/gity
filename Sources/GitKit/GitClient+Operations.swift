import Foundation

/// Operations that change the repository. Each maps to one or a few git commands; the app adds
/// confirmation, undo and error presentation on top.
extension GitClient {
    // MARK: - Revisions

    /// The commit `revision` points at, or nil if it doesn't resolve (e.g. `HEAD` before the first commit).
    public func resolve(_ revision: String) async -> String? {
        guard let output = try? await runner.string(["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"]) else { return nil }
        let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// The object a ref points at without peeling (annotated tags resolve to the tag object).
    public func objectName(ofRef ref: String) async -> String? {
        guard let output = try? await runner.string(["rev-parse", "--verify", "--quiet", ref]) else { return nil }
        let sha = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    public func isValidBranchName(_ name: String) async -> Bool {
        (try? await runner.run(["check-ref-format", "--branch", name])) != nil
    }

    public func isValidTagName(_ name: String) async -> Bool {
        (try? await runner.run(["check-ref-format", "refs/tags/\(name)"])) != nil
    }

    /// The git directory (`.git`, or the per-worktree directory for linked worktrees).
    public func gitDirectory() async throws -> URL {
        let path = try await runner.string(["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - Committing

    public func commit(message: String, amend: Bool = false) async throws {
        try await runner.run(["commit", "--file=-"] + (amend ? ["--amend"] : []), input: Data(message.utf8))
    }

    /// Changes the message of `HEAD`, leaving staged changes out of it.
    public func rewordHead(message: String) async throws {
        try await runner.run(["commit", "--amend", "--only", "--allow-empty", "--file=-"], input: Data(message.utf8))
    }

    /// Commits using the message git prepared (e.g. for a merge), without asking for one.
    public func commitWithPreparedMessage() async throws {
        try await runner.run(["commit", "--no-edit"])
    }

    /// Full message of `HEAD`, for amending.
    public func headMessage() async throws -> String {
        try await runner.string(["log", "-1", "--format=%B", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Working copy

    /// Applies a patch built by `PatchBuilder` to the index (`cached`) or the working tree.
    public func apply(patch: String, toIndex: Bool, reverse: Bool) async throws {
        var arguments = ["apply", "--recount", "--whitespace=nowarn"]
        if toIndex { arguments.append("--cached") }
        if reverse { arguments.append("--reverse") }
        try await runner.run(arguments + ["-"], input: Data(patch.utf8))
    }

    /// Throws away unstaged changes, going back to the staged version.
    public func discardUnstagedChanges(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await runner.run(["--literal-pathspecs", "restore", "--worktree", "--"] + paths)
    }

    /// Throws away staged and unstaged changes, going back to `HEAD`. Files added since are removed.
    public func discardAllChanges(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await runner.run(["--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--"] + paths)
    }

    /// Stops tracking the paths, leaving the files on disk.
    public func untrack(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await runner.run(["--literal-pathspecs", "rm", "--cached", "-r", "--quiet", "--"] + paths)
    }

    /// Replaces the working copy version of `paths` with the one from `revision`.
    public func restore(paths: [String], from revision: String) async throws {
        guard !paths.isEmpty else { return }
        try await runner.run(["--literal-pathspecs", "checkout", revision, "--"] + paths)
    }

    // MARK: - Conflicts

    public enum ConflictSide: Sendable {
        case ours
        case theirs
    }

    /// Resolves a conflict by taking one side's version entirely, then marks it resolved.
    public func resolveConflict(path: String, using side: ConflictSide) async throws {
        let flag = side == .ours ? "--ours" : "--theirs"
        do {
            try await runner.run(["--literal-pathspecs", "checkout", flag, "--", path])
            try await runner.run(["--literal-pathspecs", "add", "--", path])
        } catch {
            // The chosen side deleted the file ("does not have our/their version").
            try await runner.run(["--literal-pathspecs", "rm", "--quiet", "--", path])
        }
    }

    public func continueOperation(_ kind: PendingOperation.Kind) async throws {
        try await runner.run([kind.command, "--continue"])
    }

    public func abortOperation(_ kind: PendingOperation.Kind) async throws {
        try await runner.run([kind.command, "--abort"])
    }

    /// Skips the commit a rebase stopped at.
    public func skipRebaseStep() async throws {
        try await runner.run(["rebase", "--skip"])
    }

    /// Reads the merge, rebase, cherry-pick or revert that is in progress, if any.
    public func pendingOperation(gitDirectory: URL) -> PendingOperation? {
        let fileManager = FileManager.default
        func read(_ name: String) -> String? {
            (try? String(contentsOf: gitDirectory.appending(path: name), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: gitDirectory.appending(path: name).path)
        }

        for directory in ["rebase-merge", "rebase-apply"] where exists(directory) {
            // `rebase-apply` is also used by `git am`, which Gity doesn't drive.
            if directory == "rebase-apply", exists("rebase-apply/applying") { continue }
            let isMerge = directory == "rebase-merge"
            let step = read("\(directory)/\(isMerge ? "msgnum" : "next")").flatMap { Int($0) }
            let total = read("\(directory)/\(isMerge ? "end" : "last")").flatMap { Int($0) }
            let head = read("\(directory)/head-name")?.dropPrefix("refs/heads/")
            return PendingOperation(kind: .rebase, branchName: head, step: step, totalSteps: total, message: read("MERGE_MSG"))
        }
        if exists("MERGE_HEAD") { return PendingOperation(kind: .merge, message: read("MERGE_MSG")) }
        if exists("CHERRY_PICK_HEAD") { return PendingOperation(kind: .cherryPick, message: read("MERGE_MSG")) }
        if exists("REVERT_HEAD") { return PendingOperation(kind: .revert, message: read("MERGE_MSG")) }
        return nil
    }

    // MARK: - Remotes

    public func pull(rebase: Bool, autostash: Bool) async throws {
        try await runner.run(["pull", rebase ? "--rebase" : "--no-rebase", autostash ? "--autostash" : "--no-autostash"])
    }

    /// Pushes the current branch. Without an upstream, pass `remote` and `branch` to create one.
    public func push(remote: String? = nil, branch: String? = nil, setUpstream: Bool = false, forceWithLease: Bool = false) async throws {
        var arguments = ["push"]
        if setUpstream { arguments.append("--set-upstream") }
        if forceWithLease { arguments.append("--force-with-lease") }
        if let remote {
            arguments.append(remote)
            if let branch { arguments.append("HEAD:refs/heads/\(branch)") }
        }
        try await runner.run(arguments)
    }

    public func pushTag(_ name: String, to remote: String) async throws {
        try await runner.run(["push", remote, "refs/tags/\(name)"])
    }

    public func deleteRemoteBranch(_ name: String, remote: String) async throws {
        try await runner.run(["push", remote, "--delete", "refs/heads/\(name)"])
    }

    public func deleteRemoteTag(_ name: String, remote: String) async throws {
        try await runner.run(["push", remote, "--delete", "refs/tags/\(name)"])
    }

    /// Fetches every remote. Background fetches pass `quiet` so nothing is printed to stderr.
    public func fetchAll(quiet: Bool) async throws {
        try await runner.run(["fetch", "--all", "--prune"] + (quiet ? ["--quiet"] : []))
    }

    // MARK: - Branches and tags

    public func createBranch(_ name: String, at startPoint: String?, checkout: Bool) async throws {
        if checkout {
            try await runner.run(["switch", "--create", name] + (startPoint.map { [$0] } ?? []))
        } else {
            try await runner.run(["branch", name] + (startPoint.map { [$0] } ?? []))
        }
    }

    public func renameBranch(_ name: String, to newName: String) async throws {
        try await runner.run(["branch", "--move", name, newName])
    }

    public func deleteBranch(_ name: String, force: Bool) async throws {
        try await runner.run(["branch", force ? "-D" : "-d", name])
    }

    /// Sets (or with `nil`, removes) the branch's upstream, e.g. `origin/main`.
    public func setUpstream(of branch: String, to upstream: String?) async throws {
        if let upstream {
            try await runner.run(["branch", "--set-upstream-to=\(upstream)", branch])
        } else {
            try await runner.run(["branch", "--unset-upstream", branch])
        }
    }

    public func checkoutDetached(_ revision: String) async throws {
        try await runner.run(["switch", "--detach", revision])
    }

    /// Creates a lightweight tag, or an annotated one when there is a message.
    public func createTag(_ name: String, at revision: String, message: String?) async throws {
        if let message, !message.isEmpty {
            try await runner.run(["tag", "--annotate", "--file=-", name, revision], input: Data(message.utf8))
        } else {
            try await runner.run(["tag", name, revision])
        }
    }

    public func deleteTag(_ name: String) async throws {
        try await runner.run(["tag", "--delete", name])
    }

    /// Points `ref` at `object`, creating it if needed. Used to undo deletions.
    public func updateRef(_ ref: String, to object: String) async throws {
        try await runner.run(["update-ref", ref, object])
    }

    public func deleteRef(_ ref: String) async throws {
        try await runner.run(["update-ref", "-d", ref])
    }

    // MARK: - Merging and rewriting

    public func merge(_ revision: String, autostash: Bool) async throws {
        try await runner.run(["merge", "--no-edit", autostash ? "--autostash" : "--no-autostash", revision])
    }

    public func rebase(onto revision: String, autostash: Bool) async throws {
        try await runner.run(["rebase", autostash ? "--autostash" : "--no-autostash", revision])
    }

    /// Applies commits (oldest first) to the current branch.
    public func cherryPick(_ commits: [Commit]) async throws {
        // Merge commits need to be told which parent's changes to take; the first is the mainline.
        let mainline = commits.contains(where: \.isMerge) ? ["--mainline", "1"] : []
        try await runner.run(["cherry-pick"] + mainline + commits.map(\.sha))
    }

    public func revert(_ commit: Commit) async throws {
        try await runner.run(["revert", "--no-edit"] + (commit.isMerge ? ["--mainline", "1"] : []) + [commit.sha])
    }

    public func reset(to revision: String, mode: ResetMode) async throws {
        try await runner.run(["reset", "--\(mode.rawValue)", revision])
    }

    /// True if `revision..HEAD` contains merge commits, which an interactive rebase would flatten.
    public func hasMerges(after revision: String?) async throws -> Bool {
        let range = revision.map { "\($0)..HEAD" } ?? "HEAD"
        return !(try await runner.string(["rev-list", "--merges", "--max-count=1", range])).isEmpty
    }

    /// Commits from `HEAD` back to and including `commit` on the first-parent line, oldest first.
    public func commitsForRebase(from commit: Commit) async throws -> [Commit] {
        let revisions = commit.parents.first.map { ["\($0)..HEAD"] } ?? ["HEAD"]
        let output = try await runner.string(
            ["log", "--first-parent", "--reverse", "--format=\(GitParser.logFormat)"] + revisions + ["--"]
        )
        return GitParser.commits(output)
    }

    /// Full messages of the commits `commitsForRebase(from:)` returns, by SHA.
    public func messagesForRebase(from commit: Commit) async throws -> [String: String] {
        let revisions = commit.parents.first.map { ["\($0)..HEAD"] } ?? ["HEAD"]
        let output = try await runner.string(["log", "--first-parent", "--format=%H%x1f%B%x1e"] + revisions + ["--"])
        var messages: [String: String] = [:]
        for record in output.split(separator: "\u{1e}") {
            let parts = record.drop { $0.isNewline }.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            messages[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return messages
    }

    /// SHAs on the current branch's first-parent line (the commits history rewriting can touch),
    /// and those among them not yet on the upstream branch.
    public func rewritableCommits(limit: Int = 500) async throws -> (all: Set<String>, unpushed: Set<String>?) {
        async let all = runner.string(["rev-list", "--first-parent", "--max-count=\(limit)", "HEAD", "--"])
        async let unpushed = try? runner.string(["rev-list", "--first-parent", "--max-count=\(limit)", "HEAD", "--not", "@{upstream}", "--"])
        func set(_ output: String) -> Set<String> { Set(output.split(whereSeparator: \.isNewline).map(String.init)) }
        return (set(try await all), await unpushed.map(set))
    }

    /// Runs `git rebase -i` with a prepared plan instead of an editor.
    /// - Parameters:
    ///   - steps: Oldest first, starting with the commit after `base`.
    ///   - base: Parent of the first step, or nil to rewrite from the root commit.
    public func interactiveRebase(steps: [RebaseStep], base: String?, autostash: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gity-rebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let todo = try RebasePlan.todo(for: steps) { index, message in
            let file = directory.appending(path: "message-\(index).txt")
            try message.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        }
        let todoFile = directory.appending(path: "git-rebase-todo")
        try todo.write(to: todoFile, atomically: true, encoding: .utf8)

        // Message files stay behind if the rebase stops at a conflict, since its remaining `exec`
        // lines still need them; they live in the temporary folder, which macOS cleans up.
        try await runner.run(
            ["rebase", "--interactive", autostash ? "--autostash" : "--no-autostash"] + (base.map { [$0] } ?? ["--root"]),
            environment: ["GIT_SEQUENCE_EDITOR": "cp \(RebasePlan.shellQuoted(todoFile.path))"]
        )
    }

    // MARK: - Stashes

    public func stash(message: String?, includeUntracked: Bool) async throws {
        var arguments = ["stash", "push"]
        if includeUntracked { arguments.append("--include-untracked") }
        if let message, !message.isEmpty { arguments += ["--message", message] }
        try await runner.run(arguments)
    }

    public func applyStash(_ selector: String, pop: Bool) async throws {
        try await runner.run(["stash", pop ? "pop" : "apply", selector])
    }

    public func dropStash(_ selector: String) async throws {
        try await runner.run(["stash", "drop", "--quiet", selector])
    }

    /// Puts a dropped stash commit back on the stash list.
    public func storeStash(_ sha: String, message: String) async throws {
        try await runner.run(["stash", "store", "--message", message, sha])
    }

    /// Selectors of stashes by SHA, e.g. to find a stash again after the list shifted.
    public func stashSelectors() async throws -> [String: String] {
        let output = try await runner.string(["stash", "list", "--format=%H %gd"])
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    /// The stash as a commit whose first parent is the commit it was made on.
    public func stashCommit(_ selector: String) async throws -> Commit? {
        GitParser.commits(try await runner.string(["log", "-1", "--format=\(GitParser.logFormat)", selector, "--"])).first
    }

    // MARK: - History

    /// Recent `HEAD` movements, newest first.
    public func reflog(limit: Int = 500) async throws -> [Commit] {
        let output = try await runner.string(
            ["log", "--walk-reflogs", "--max-count=\(limit)", "--decorate=full", "--decorate-refs-exclude=refs/stash",
             "--format=\(GitParser.reflogFormat)", "HEAD", "--"]
        )
        return GitParser.reflog(output)
    }

    /// Commits that touched `path`, following renames.
    public func fileHistory(path: String, limit: Int = 500) async throws -> [FileHistoryEntry] {
        let output = try await runner.string(
            ["-c", "core.quotePath=false", "log", "--follow", "--max-count=\(limit)", "--decorate=full",
             "--decorate-refs-exclude=refs/stash", "--name-status", "--format=\(GitParser.fileHistoryFormat)",
             "--", path]
        )
        return GitParser.fileHistory(output, path: path)
    }

    /// Line-by-line authorship of `path` in the working copy, or at `revision`.
    public func blame(path: String, revision: String? = nil) async throws -> Blame {
        let output = try await runner.string(
            ["blame", "--porcelain"] + (revision.map { [$0] } ?? []) + ["--", path]
        )
        return GitParser.blame(output)
    }
}

extension PendingOperation.Kind {
    var command: String {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        }
    }
}

/// Turns rebase steps into a `git-rebase-todo` file.
public enum RebasePlan {
    /// - Parameter writeMessage: Stores a message and returns the path of the file holding it.
    public static func todo(for steps: [RebaseStep], writeMessage: (Int, String) throws -> String) throws -> String {
        var lines: [String] = []
        /// Message for the commit being built from the current pick and the squashes that follow it.
        var pendingMessage: String?

        func finishGroup() throws {
            guard let message = pendingMessage else { return }
            let file = try writeMessage(lines.count, message)
            // Hooks already ran when the commits were first made; the content doesn't change here.
            lines.append("exec git commit --amend --allow-empty --no-verify --quiet --file=\(shellQuoted(file))")
            pendingMessage = nil
        }

        for step in steps {
            switch step.action {
            case .drop:
                lines.append("drop \(step.sha)")
            case .pick, .reword:
                try finishGroup()
                lines.append("pick \(step.sha)")
                pendingMessage = step.message
            case .squash, .fixup:
                // Both are fixups to git; a squash's combined message is set on the group's first commit.
                lines.append("fixup \(step.sha)")
                if let message = step.message { pendingMessage = message }
            }
        }
        try finishGroup()
        return lines.joined(separator: "\n") + "\n"
    }

    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
