import Foundation

/// High-level, read-mostly API over a single repository.
public struct GitClient: Sendable {
    public let repositoryURL: URL
    public let runner: GitRunner

    public init(repositoryURL: URL, executableURL: URL) {
        self.repositoryURL = repositoryURL
        self.runner = GitRunner(executableURL: executableURL, workingDirectory: repositoryURL)
    }

    /// Resolves any folder inside a working tree to the working tree root.
    /// Throws if `url` is not inside a git repository.
    public static func workingTreeRoot(containing url: URL, executableURL: URL) async throws -> URL {
        let runner = GitRunner(executableURL: executableURL, workingDirectory: url)
        let path = try await runner.string(["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw GitError(arguments: ["rev-parse"], exitCode: 1, standardError: "Not inside a working tree.")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public static func initializeRepository(at url: URL, executableURL: URL) async throws {
        let runner = GitRunner(executableURL: executableURL, workingDirectory: url)
        try await runner.run(["init"])
    }

    public static func version(executableURL: URL) async throws -> String {
        let runner = GitRunner(executableURL: executableURL, workingDirectory: FileManager.default.homeDirectoryForCurrentUser)
        return try await runner.string(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loads status, refs and stashes concurrently.
    public func snapshot() async throws -> RepositorySnapshot {
        async let statusData = runner.run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        async let refOutput = runner.string([
            "for-each-ref", "--format=\(GitParser.refFormat)", "refs/heads", "refs/remotes", "refs/tags",
        ])
        async let remoteOutput = runner.string(["remote"])
        // Stash listing fails on some unusual setups (e.g. unborn HEAD on old gits); treat as empty.
        async let stashOutput = try? runner.string(["stash", "list", "--format=\(GitParser.stashFormat)"])
        async let gitDirectory = try? gitDirectory()

        let status = GitParser.status(try await statusData)
        let remoteNames = try await remoteOutput.split(whereSeparator: \.isNewline).map(String.init)
        let refs = GitParser.refs(try await refOutput, remoteNames: remoteNames)
        let stashes = GitParser.stashes(await stashOutput ?? "")
        let pendingOperation = await gitDirectory.flatMap { pendingOperation(gitDirectory: $0) }

        return RepositorySnapshot(
            status: status,
            localBranches: refs.localBranches,
            remotes: refs.remotes,
            tags: refs.tags,
            stashes: stashes,
            pendingOperation: pendingOperation
        )
    }

    /// Commit history reachable from `revisions` (e.g. `["HEAD"]`, `["refs/heads/main"]`, `["--all"]`).
    public func log(_ revisions: [String], limit: Int = 500) async throws -> [Commit] {
        let output = try await runner.string(
            ["log", "--max-count=\(limit)", "--date-order", "--decorate=full",
             "--decorate-refs-exclude=refs/stash", "--format=\(GitParser.logFormat)"]
                + revisions + ["--"]
        )
        return GitParser.commits(output)
    }

    // MARK: - Diffs

    /// Common flags that make diff output predictable regardless of the user's git config.
    private static let diffFlags = ["--no-color", "--no-ext-diff", "--find-renames"]

    /// Diff of a single working copy entry, against the index (unstaged) or HEAD (staged).
    public func diff(for change: FileChange, options: DiffOptions = DiffOptions(), maxLines: Int? = nil) async throws -> FileDiff {
        let output: String
        switch change.area {
        case .untracked:
            // Show a new file as all additions. Exit code 1 just means "there are differences".
            output = try await runner.string(
                ["diff", "--no-index"] + Self.diffFlags + options.arguments + ["--", "/dev/null", change.path],
                successExitCodes: [0, 1]
            )
        case .staged:
            output = try await runner.string(
                ["--literal-pathspecs", "diff", "--cached"] + Self.diffFlags + options.arguments
                    + ["--"] + [change.originalPath, change.path].compactMap { $0 }
            )
        case .unstaged, .conflicted:
            output = try await runner.string(
                ["--literal-pathspecs", "diff"] + Self.diffFlags + options.arguments + ["--", change.path]
            )
        }
        return GitParser.diff(output, maxLines: maxLines)
    }

    /// Files changed by `commit`, compared with its first parent.
    public func changedFiles(in commit: Commit) async throws -> [CommitFileChange] {
        let data: Data
        if let parent = commit.parents.first {
            data = try await runner.run(["diff", "--name-status", "-z", "--no-ext-diff", "--find-renames", parent, commit.sha])
        } else {
            data = try await runner.run(["diff-tree", "-r", "--root", "--no-commit-id", "--name-status", "-z", "--find-renames", commit.sha])
        }
        return GitParser.nameStatus(data)
    }

    /// Diff of one file in `commit`, compared with its first parent.
    public func diff(for file: CommitFileChange, in commit: Commit, options: DiffOptions = DiffOptions(), maxLines: Int? = nil) async throws -> FileDiff {
        let paths = ["--"] + [file.originalPath, file.path].compactMap { $0 }
        let output: String
        if let parent = commit.parents.first {
            output = try await runner.string(["--literal-pathspecs", "diff"] + Self.diffFlags + options.arguments + [parent, commit.sha] + paths)
        } else {
            output = try await runner.string(
                ["--literal-pathspecs", "diff-tree", "-p", "--root", "--no-commit-id"] + Self.diffFlags + options.arguments + [commit.sha] + paths
            )
        }
        return GitParser.diff(output, maxLines: maxLines)
    }

    /// Full commit message (subject and body).
    public func message(of commit: Commit) async throws -> String {
        try await runner.string(["show", "--no-patch", "--format=%B", commit.sha])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Staging

    /// Stages the given paths, including deletions and untracked files.
    public func stage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await runner.run(["--literal-pathspecs", "add", "--all", "--"] + paths)
    }

    /// Removes the given paths from the index, keeping working tree changes.
    public func unstage(paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        if try await hasCommits() {
            try await runner.run(["--literal-pathspecs", "restore", "--staged", "--"] + paths)
        } else {
            // Before the first commit there is no HEAD to restore from; just drop the index entries.
            try await runner.run(["--literal-pathspecs", "rm", "--cached", "-r", "--quiet", "--"] + paths)
        }
    }

    private func hasCommits() async throws -> Bool {
        (try? await runner.run(["rev-parse", "--verify", "--quiet", "HEAD"])) != nil
    }

    // MARK: - Branches

    /// Switches to an existing local branch.
    public func switchBranch(_ name: String) async throws {
        try await runner.run(["switch", "--no-guess", name])
    }

    /// Creates a local branch tracking `remoteBranch` (e.g. `origin/feature`) and switches to it.
    public func switchToTrackingBranch(for remoteBranch: Branch) async throws {
        try await runner.run(["switch", "--create", remoteBranch.name, "--track", remoteBranch.shortName])
    }

}
