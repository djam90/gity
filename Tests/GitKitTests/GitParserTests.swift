import Foundation
import Testing
@testable import GitKit

@Suite struct GitParserTests {
    private func ref(_ fields: String...) -> String { fields.joined(separator: "\u{1f}") }

    @Test func parsesLocalRemoteAndTagRefs() {
        let output = [
            ref("refs/heads/main", "aaa", "", "*", "origin/main", "[ahead 2, behind 1]", "1700000000", "Ada", "", "", "Update docs"),
            ref("refs/heads/feature/login", "bbb", "", " ", "origin/feature/login", "[gone]", "1700000001", "Ada", "", "", "Login"),
            ref("refs/remotes/origin/HEAD", "aaa", "", " ", "", "", "1700000000", "Ada", "", "refs/remotes/origin/main", "Update docs"),
            ref("refs/remotes/origin/main", "aaa", "", " ", "", "", "1700000000", "Ada", "", "", "Update docs"),
            ref("refs/remotes/upstream/fork/topic", "ccc", "", " ", "", "", "1700000002", "Bob", "", "", "Topic"),
            ref("refs/tags/v1.0", "ttt", "ddd", " ", "", "", "1700000005", "", "Ada", "", "Release 1.0"),
            ref("refs/tags/v0.9", "eee", "", " ", "", "", "1600000000", "Ada", "", "", "Lightweight"),
        ].joined(separator: "\n")

        let refs = GitParser.refs(output, remoteNames: ["origin", "upstream/fork", "empty"])

        #expect(refs.localBranches.map(\.name) == ["main", "feature/login"])
        let main = refs.localBranches[0]
        #expect(main.isHead && main.ahead == 2 && main.behind == 1 && main.upstream == "origin/main")
        #expect(refs.localBranches[1].isUpstreamGone)

        #expect(refs.remotes.map(\.name) == ["empty", "origin", "upstream/fork"])
        #expect(refs.remotes[0].branches.isEmpty)
        #expect(refs.remotes[1].branches.map(\.name) == ["main"], "origin/HEAD symref is skipped")
        #expect(refs.remotes[2].branches.map(\.shortName) == ["upstream/fork/topic"])

        #expect(refs.tags.map(\.name) == ["v1.0", "v0.9"], "newest first")
        #expect(refs.tags[0].targetSHA == "ddd", "annotated tags are peeled")
        #expect(refs.tags[1].targetSHA == "eee")
    }

    @Test func parsesTrackingCounts() {
        #expect(GitParser.trackingCounts("") == (0, 0, false))
        #expect(GitParser.trackingCounts("[ahead 3]") == (3, 0, false))
        #expect(GitParser.trackingCounts("[behind 4]") == (0, 4, false))
        #expect(GitParser.trackingCounts("[gone]") == (0, 0, true))
    }

    @Test func parsesPorcelainV2Status() {
        let entries = [
            "# branch.oid 1234567890",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +1 -2",
            "1 M. N... 100644 100644 100644 aaa bbb staged file.txt",
            "1 .M N... 100644 100644 100644 aaa bbb dir/with space.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new.swift", "old.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt",
            "? untracked.txt",
        ]
        let data = Data((entries.joined(separator: "\0") + "\0").utf8)
        let status = GitParser.status(data)

        #expect(status.head == .branch("main"))
        #expect(status.upstream == "origin/main" && status.ahead == 1 && status.behind == 2)
        #expect(status.changes == [
            FileChange(path: "staged file.txt", kind: .modified, area: .staged),
            FileChange(path: "dir/with space.swift", kind: .modified, area: .unstaged),
            FileChange(path: "new.swift", originalPath: "old.swift", kind: .renamed, area: .staged),
            FileChange(path: "conflict.txt", kind: .conflicted, area: .conflicted),
            FileChange(path: "untracked.txt", kind: .untracked, area: .untracked),
        ])
    }

    @Test func parsesUnbornAndDetachedHead() {
        let unborn = GitParser.status(Data("# branch.oid (initial)\0# branch.head main\0".utf8))
        #expect(unborn.head == .unborn("main"))
        let detached = GitParser.status(Data("# branch.oid abc123\0# branch.head (detached)\0".utf8))
        #expect(detached.head == .detached("abc123"))
    }

    @Test func parsesCommitsAndDecorations() {
        let record = ["abc123full", "abc123", "p1 p2", "Ada", "ada@example.com", "1700000000",
                      "HEAD -> refs/heads/main, refs/remotes/origin/main, refs/remotes/origin/HEAD, tag: refs/tags/v1",
                      "Merge branch"].joined(separator: "\u{1f}")
        let commits = GitParser.commits(record + "\u{1e}\n" + record.replacingOccurrences(of: "abc123", with: "def456") + "\u{1e}\n")

        #expect(commits.count == 2)
        #expect(commits[0].parents == ["p1", "p2"])
        #expect(commits[0].decorations == [
            Decoration(kind: .head, name: "HEAD"),
            Decoration(kind: .localBranch, name: "main", isCurrent: true),
            Decoration(kind: .remoteBranch, name: "origin/main"),
            Decoration(kind: .tag, name: "v1"),
        ])
        #expect(commits[1].sha == "def456full")
    }

    @Test func parsesStashes() {
        let stashes = GitParser.stashes("stash@{0}\u{1f}1700000000\u{1f}On main: WIP\nstash@{1}\u{1f}1690000000\u{1f}WIP on main: abc")
        #expect(stashes.map(\.selector) == ["stash@{0}", "stash@{1}"])
        #expect(stashes[0].message == "On main: WIP")
    }
}

@Suite struct RefTreeTests {
    @Test func groupsBySlashWithFoldersFirst() {
        let tree = RefTree.build(["main", "feature/auth/login", "feature/auth/signup", "feature/ui", "bugfix/crash", "zeta"], path: { $0 })

        #expect(tree.map(\.name) == ["bugfix", "feature", "main", "zeta"])
        let feature = tree[1]
        #expect(feature.isFolder)
        #expect(feature.children?.map(\.name) == ["auth", "ui"])
        #expect(feature.children?[0].children?.map(\.item) == ["feature/auth/login", "feature/auth/signup"])
        #expect(feature.leaves.count == 3)
        #expect(tree[2].children == nil, "leaves have no children so no disclosure triangle is shown")
    }
}

@Suite struct RepositoryWatcherTests {
    @Test func ignoresGitInternalsNoise() {
        #expect(RepositoryWatcher.isRelevant("/repo/.git/HEAD"))
        #expect(RepositoryWatcher.isRelevant("/repo/.git/refs/heads/main"))
        #expect(RepositoryWatcher.isRelevant("/repo/src/file.swift"))
        #expect(!RepositoryWatcher.isRelevant("/repo/.git/index.lock"))
        #expect(!RepositoryWatcher.isRelevant("/repo/.git/objects/ab/cdef"))
        #expect(!RepositoryWatcher.isRelevant("/repo/.git/logs/HEAD"))
    }
}

@Suite struct DiffParserTests {
    @Test func parsesUnifiedDiffWithLineNumbers() {
        let output = """
        diff --git a/file.swift b/file.swift
        index 1111111..2222222 100644
        --- a/file.swift
        +++ b/file.swift
        @@ -1,4 +1,5 @@ struct A {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        @@ -10,2 +11,2 @@
         x
        -y
        \\ No newline at end of file
        +z

        """
        let diff = GitParser.diff(output)

        #expect(diff.hunks.count == 2)
        #expect(diff.additions == 3 && diff.deletions == 2 && !diff.isBinary)
        let first = diff.hunks[0].lines
        #expect(diff.hunks[0].header == "@@ -1,4 +1,5 @@ struct A {")
        #expect(first.map(\.kind) == [.context, .deletion, .addition, .addition, .context])
        #expect(first[1].oldNumber == 2 && first[1].newNumber == nil)
        #expect(first[3].newNumber == 3)
        #expect(first[4].oldNumber == 3 && first[4].newNumber == 4)
        #expect(diff.hunks[1].lines.map(\.kind) == [.context, .deletion, .noNewlineMarker, .addition])
        #expect(diff.hunks[1].lines[3].newNumber == 12)
    }

    @Test func detectsBinaryFiles() {
        let diff = GitParser.diff("diff --git a/a.png b/a.png\nBinary files a/a.png and b/a.png differ\n")
        #expect(diff.isBinary && diff.hunks.isEmpty)
    }

    @Test func parsesCombinedConflictDiff() {
        let output = """
        diff --cc file.txt
        @@@ -1,1 -1,1 +1,5 @@@
        ++<<<<<<< HEAD
         +ours
        ++=======
        + theirs
        ++>>>>>>> branch
        """
        let diff = GitParser.diff(output)
        #expect(diff.hunks.first?.lines.count == 5)
        #expect(diff.hunks.first?.lines.allSatisfy { $0.kind == .addition } == true)
        #expect(diff.hunks.first?.lines.first?.text == "<<<<<<< HEAD")
    }

    @Test func truncatesButKeepsCounting() {
        let body = (1...100).map { "+line \($0)" }.joined(separator: "\n")
        let diff = GitParser.diff("@@ -0,0 +1,100 @@\n" + body, maxLines: 10)
        #expect(diff.isTruncated)
        #expect(diff.hunks.flatMap(\.lines).count == 10)
        #expect(diff.additions == 100 && diff.lineCount == 100)
    }

    @Test func parsesNameStatus() {
        let data = Data("M\0a.txt\0R087\0old.swift\0new.swift\0A\0b.txt\0D\0c.txt\0".utf8)
        #expect(GitParser.nameStatus(data) == [
            CommitFileChange(path: "a.txt", kind: .modified),
            CommitFileChange(path: "new.swift", originalPath: "old.swift", kind: .renamed),
            CommitFileChange(path: "b.txt", kind: .added),
            CommitFileChange(path: "c.txt", kind: .deleted),
        ])
    }
}

/// Runs real git in a temporary repository.
@Suite struct StagingIntegrationTests {
    private func makeRepository(commit: Bool) async throws -> (URL, GitClient) {
        let url = FileManager.default.temporaryDirectory.appending(path: "gity-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let git = try #require(GitExecutable.locate())
        let client = GitClient(repositoryURL: url, executableURL: git)
        try await client.runner.run(["init", "-q", "-b", "main"])
        try await client.runner.run(["config", "user.name", "Test"])
        try await client.runner.run(["config", "user.email", "test@example.com"])
        try "one\n".write(to: url.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        if commit {
            try await client.runner.run(["add", "."])
            try await client.runner.run(["commit", "-q", "-m", "init"])
        }
        return (url, client)
    }

    private func areas(_ client: GitClient) async throws -> [String: FileChange.Area] {
        let changes = try await client.snapshot().status.changes
        return Dictionary(changes.map { ($0.path, $0.area) }, uniquingKeysWith: { a, _ in a })
    }

    @Test func stagesAndUnstagesModifiedDeletedAndUntrackedFiles() async throws {
        let (url, client) = try await makeRepository(commit: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try "two\n".write(to: url.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: url.appending(path: "new file.txt"), atomically: true, encoding: .utf8)

        try await client.stage(paths: ["tracked.txt", "new file.txt"])
        #expect(try await areas(client) == ["tracked.txt": .staged, "new file.txt": .staged])

        try await client.unstage(paths: ["tracked.txt", "new file.txt"])
        #expect(try await areas(client) == ["tracked.txt": .unstaged, "new file.txt": .untracked])

        try FileManager.default.removeItem(at: url.appending(path: "tracked.txt"))
        try await client.stage(paths: ["tracked.txt"])
        #expect(try await client.snapshot().status.changes == [FileChange(path: "tracked.txt", kind: .deleted, area: .staged), FileChange(path: "new file.txt", kind: .untracked, area: .untracked)])
    }

    @Test func unstagesBeforeFirstCommit() async throws {
        let (url, client) = try await makeRepository(commit: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try await client.stage(paths: ["tracked.txt"])
        #expect(try await areas(client) == ["tracked.txt": .staged])
        try await client.unstage(paths: ["tracked.txt"])
        #expect(try await areas(client) == ["tracked.txt": .untracked])
    }
}

@Suite struct FuzzyMatcherTests {
    @Test func matchesSubsequencesAtWordStarts() throws {
        let match = try #require(FuzzyMatcher.match("gd", in: "gity-demo"))
        #expect(match.indices == [0, 5])
        #expect(FuzzyMatcher.match("xyz", in: "gity-demo") == nil)
        #expect(FuzzyMatcher.match("GITY", in: "gity")?.indices == [0, 1, 2, 3], "case insensitive")
    }

    @Test func ranksBetterMatchesHigher() throws {
        func score(_ query: String, _ candidate: String) throws -> Int {
            try #require(FuzzyMatcher.match(query, in: candidate)).score
        }
        #expect(try score("demo", "gity-demo") > score("demo", "d-e-m-o-thing"), "contiguous beats scattered")
        #expect(try score("gity", "gity") > score("gity", "my-gity-fork"), "prefix and shorter win")
        #expect(try score("ms", "MySite") > score("ms", "atoms"), "camel case word starts")
    }
}

@Suite struct RepositoryScannerTests {
    @Test func findsRepositoriesWithoutDescendingIntoThem() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gity-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for path in ["a/.git", "a/nested/.git", "b/c/.git", "node_modules/pkg/.git", "deep/1/2/3/4/.git"] {
            try fm.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
        }
        // Worktrees use a `.git` file rather than a folder.
        try fm.createDirectory(at: root.appending(path: "worktree"), withIntermediateDirectories: true)
        try "gitdir: /elsewhere".write(to: root.appending(path: "worktree/.git"), atomically: true, encoding: .utf8)

        let found = RepositoryScanner.scan([.init(url: root, maxDepth: 3)]).map(\.lastPathComponent).sorted()
        #expect(found == ["a", "c", "worktree"])
    }
}
