import Foundation
import Testing
@testable import GitKit

/// A throwaway repository with real git, for testing operations end to end.
struct TestRepository {
    let url: URL
    let client: GitClient

    init() async throws {
        url = FileManager.default.temporaryDirectory.appending(path: "gity-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        client = GitClient(repositoryURL: url, executableURL: try #require(GitExecutable.locate()))
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try await git("config", "commit.gpgsign", "false")
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func git(_ arguments: String...) async throws -> String {
        try await client.runner.string(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ path: String, _ contents: String) throws {
        try contents.write(to: url.appending(path: path), atomically: true, encoding: .utf8)
    }

    func read(_ path: String) throws -> String {
        try String(contentsOf: url.appending(path: path), encoding: .utf8)
    }

    func commitAll(_ message: String) async throws {
        try await git("add", "--all")
        try await git("commit", "-q", "-m", message)
    }

    func subjects() async throws -> [String] {
        try await git("log", "--format=%s").split(separator: "\n").map(String.init)
    }
}

@Suite struct PatchTests {
    private static let original = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"

    @Test func stagesSelectedLinesOnly() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("file.txt", Self.original)
        try await repo.commitAll("init")

        // Lines 2 and 9 are close enough to share a hunk, so this also covers partial hunks.
        var lines = Self.original.split(separator: "\n").map(String.init)
        lines[1] = "line 2 changed"
        lines[8] = "line 9 changed"
        try repo.write("file.txt", lines.joined(separator: "\n") + "\n")

        let change = FileChange(path: "file.txt", kind: .modified, area: .unstaged)
        let diff = try await repo.client.diff(for: change)
        // Select only the change to line 2 (its deletion and addition).
        let selected = Set(diff.hunks.enumerated().flatMap { hunkIndex, hunk in
            hunk.lines.enumerated().compactMap { index, line in
                line.text.hasPrefix("line 2") && line.kind != .context ? DiffLineID(hunk: hunkIndex, line: index) : nil
            }
        })
        #expect(selected.count == 2)
        let patch = try #require(PatchBuilder.patch(from: diff, selecting: selected, direction: .forward))
        try await repo.client.apply(patch: patch, toIndex: true, reverse: false)

        let staged = try await repo.git("show", ":file.txt")
        #expect(staged.contains("line 2 changed"))
        #expect(!staged.contains("line 9 changed"))
        #expect(try repo.read("file.txt").contains("line 9 changed"), "working copy untouched")

        // Now unstage it again from the staged diff.
        let stagedDiff = try await repo.client.diff(for: FileChange(path: "file.txt", kind: .modified, area: .staged))
        let all = Set(stagedDiff.hunks.indices.flatMap { PatchBuilder.changedLines(inHunk: $0, of: stagedDiff) })
        let reverse = try #require(PatchBuilder.patch(from: stagedDiff, selecting: all, direction: .reverse))
        try await repo.client.apply(patch: reverse, toIndex: true, reverse: true)
        #expect(try await repo.git("diff", "--cached").isEmpty)
    }

    @Test func discardsOneOfTwoHunks() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try repo.write("file.txt", long)
        try await repo.commitAll("init")

        var lines = long.split(separator: "\n").map(String.init)
        lines[2] = "top changed"
        lines.insert("inserted near bottom", at: 35)
        try repo.write("file.txt", lines.joined(separator: "\n") + "\n")

        let diff = try await repo.client.diff(for: FileChange(path: "file.txt", kind: .modified, area: .unstaged))
        #expect(diff.hunks.count == 2)
        // Discarding = reverse-applying to the working tree.
        let patch = try #require(PatchBuilder.patch(from: diff, selecting: PatchBuilder.changedLines(inHunk: 0, of: diff), direction: .reverse))
        try await repo.client.apply(patch: patch, toIndex: false, reverse: true)

        let contents = try repo.read("file.txt")
        #expect(!contents.contains("top changed"))
        #expect(contents.contains("line 3\n"))
        #expect(contents.contains("inserted near bottom"))
    }

    @Test func stagesPartOfANewFile() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("readme.txt", "hi\n")
        try await repo.commitAll("init")
        try repo.write("new.txt", "a\nb\nc\n")

        let diff = try await repo.client.diff(for: FileChange(path: "new.txt", kind: .untracked, area: .untracked))
        let first = try #require(diff.hunks.first?.lines.firstIndex { $0.text == "a" })
        let patch = try #require(PatchBuilder.patch(from: diff, selecting: [DiffLineID(hunk: 0, line: first)], direction: .forward))
        try await repo.client.apply(patch: patch, toIndex: true, reverse: false)
        #expect(try await repo.git("show", ":new.txt") == "a")
    }

    @Test func buildsNothingWithoutSelection() {
        let diff = GitParser.diff("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(PatchBuilder.patch(from: diff, selecting: [], direction: .forward) == nil)
        #expect(diff.headerLines == ["diff --git a/x b/x", "--- a/x", "+++ b/x"])
        #expect(diff.hunks[0].oldStart == 1 && diff.hunks[0].newStart == 1)
    }
}

@Suite struct OperationTests {
    @Test func commitsAndAmendsWithMessagesFromStdin() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        try await repo.git("add", "a.txt")
        try await repo.client.commit(message: "First line\n\nBody with “quotes” and 'apostrophes'")
        #expect(try await repo.client.headMessage() == "First line\n\nBody with “quotes” and 'apostrophes'")

        try repo.write("b.txt", "b\n")
        try await repo.git("add", "b.txt")
        try await repo.client.commit(message: "Amended", amend: true)
        #expect(try await repo.subjects() == ["Amended"])
        #expect(try await repo.git("show", "--name-only", "--format=").split(separator: "\n").sorted() == ["a.txt", "b.txt"])
    }

    @Test func detectsAndResolvesMergeConflicts() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("file.txt", "base\n")
        try await repo.commitAll("base")
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("file.txt", "feature\n")
        try await repo.commitAll("feature change")
        try await repo.git("switch", "-q", "main")
        try repo.write("file.txt", "main\n")
        try await repo.commitAll("main change")

        await #expect(throws: GitError.self) { try await repo.client.merge("feature", autostash: true) }
        var snapshot = try await repo.client.snapshot()
        #expect(snapshot.pendingOperation?.kind == .merge)
        #expect(snapshot.pendingOperation?.message?.contains("Merge branch 'feature'") == true)
        #expect(snapshot.hasConflicts)

        try await repo.client.resolveConflict(path: "file.txt", using: .theirs)
        #expect(try repo.read("file.txt") == "feature\n")
        try await repo.client.commitWithPreparedMessage()
        snapshot = try await repo.client.snapshot()
        #expect(snapshot.pendingOperation == nil)
        #expect(try await repo.subjects().first == "Merge branch 'feature'")
    }

    @Test func abortsARebase() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("file.txt", "base\n")
        try await repo.commitAll("base")
        try await repo.git("switch", "-q", "-c", "feature")
        try repo.write("file.txt", "feature\n")
        try await repo.commitAll("feature change")
        try await repo.git("switch", "-q", "main")
        try repo.write("file.txt", "main\n")
        try await repo.commitAll("main change")
        try await repo.git("switch", "-q", "feature")

        await #expect(throws: GitError.self) { try await repo.client.rebase(onto: "main", autostash: true) }
        let pending = try #require(try await repo.client.snapshot().pendingOperation)
        #expect(pending.kind == .rebase && pending.branchName == "feature" && pending.step == 1 && pending.totalSteps == 1)
        try await repo.client.abortOperation(.rebase)
        #expect(try await repo.client.snapshot().pendingOperation == nil)
        #expect(try repo.read("file.txt") == "feature\n")
    }

    @Test func pullsWithRebaseAndAutostash() async throws {
        let origin = try await TestRepository()
        defer { origin.remove() }
        try origin.write("file.txt", "one\n")
        try await origin.commitAll("one")

        let clone = try await TestRepository()
        defer { clone.remove() }
        try await clone.git("remote", "add", "origin", origin.url.path)
        try await clone.git("fetch", "-q", "origin")
        try await clone.git("switch", "-q", "-c", "work", "--track", "origin/main")

        try origin.write("file.txt", "one\ntwo\n")
        try await origin.commitAll("two")
        try clone.write("other.txt", "local\n")
        try await clone.commitAll("local commit")
        try clone.write("file.txt", "one\ndirty\n")

        try await clone.client.pull(rebase: true, autostash: true)
        #expect(try await clone.subjects() == ["local commit", "two", "one"])
        #expect(try clone.read("file.txt").contains("dirty"), "local changes restored after the pull")
    }

    @Test func stashesAndRestoresADroppedStash() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("file.txt", "one\n")
        try await repo.commitAll("one")
        try repo.write("file.txt", "two\n")
        try repo.write("new.txt", "new\n")

        try await repo.client.stash(message: "WIP stuff", includeUntracked: true)
        var snapshot = try await repo.client.snapshot()
        #expect(snapshot.status.changes.isEmpty)
        #expect(snapshot.stashes.map(\.message) == ["On main: WIP stuff"])

        let sha = try #require(await repo.client.objectName(ofRef: "stash@{0}"))
        try await repo.client.dropStash("stash@{0}")
        try await repo.client.storeStash(sha, message: "On main: WIP stuff")
        try await repo.client.applyStash("stash@{0}", pop: true)
        snapshot = try await repo.client.snapshot()
        #expect(snapshot.stashes.isEmpty)
        #expect(try repo.read("file.txt") == "two\n")
        #expect(try repo.read("new.txt") == "new\n")
    }
}

@Suite struct InteractiveRebaseTests {
    private func makeHistory() async throws -> TestRepository {
        let repo = try await TestRepository()
        for name in ["a", "b", "c", "d"] {
            try repo.write("\(name).txt", "\(name)\n")
            try await repo.commitAll("add \(name)")
        }
        return repo
    }

    @Test func writesTodoWithMessagesAsExecAmends() throws {
        var files: [String] = []
        let todo = try RebasePlan.todo(for: [
            RebaseStep(sha: "a1", action: .pick),
            RebaseStep(sha: "b2", action: .reword, message: "New"),
            RebaseStep(sha: "c3", action: .squash),
            RebaseStep(sha: "d4", action: .drop),
        ]) { index, message in
            files.append(message)
            return "/tmp/m\(index)"
        }
        #expect(todo == """
            pick a1
            pick b2
            fixup c3
            drop d4
            exec git commit --amend --allow-empty --no-verify --quiet --file='/tmp/m4'

            """)
        #expect(files == ["New"])
    }

    @Test func rewordsSquashesDropsAndReorders() async throws {
        let repo = try await makeHistory()
        defer { repo.remove() }
        let commits = try await repo.client.log(["HEAD"])
        let b = try #require(commits.first { $0.subject == "add b" })
        let plan = try await repo.client.commitsForRebase(from: b)
        #expect(plan.map(\.subject) == ["add b", "add c", "add d"])

        // d first, then b reworded with c squashed into it.
        let steps = [
            RebaseStep(sha: plan[2].sha, action: .pick),
            RebaseStep(sha: plan[0].sha, action: .reword, message: "b and c"),
            RebaseStep(sha: plan[1].sha, action: .squash),
        ]
        try await repo.client.interactiveRebase(steps: steps, base: b.parents.first, autostash: true)
        #expect(try await repo.subjects() == ["b and c", "add d", "add a"])
        #expect(try await repo.client.snapshot().pendingOperation == nil)
    }

    @Test func rebasesFromTheRootCommit() async throws {
        let repo = try await makeHistory()
        defer { repo.remove() }
        let commits = try await repo.client.log(["HEAD"])
        let root = try #require(commits.last)
        let plan = try await repo.client.commitsForRebase(from: root)
        #expect(plan.count == 4)
        var steps = plan.map { RebaseStep(sha: $0.sha) }
        steps[3].action = .drop
        try await repo.client.interactiveRebase(steps: steps, base: nil, autostash: true)
        #expect(try await repo.subjects() == ["add c", "add b", "add a"])
    }
}

@Suite struct HistoryParsingTests {
    @Test func followsRenamesInFileHistory() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("old.txt", "content\nmore\nlines\n")
        try await repo.commitAll("create")
        try await repo.git("mv", "old.txt", "new.txt")
        try await repo.commitAll("rename")
        try repo.write("new.txt", "content\nmore\nlines\nand more\n")
        try await repo.commitAll("edit")

        let history = try await repo.client.fileHistory(path: "new.txt")
        #expect(history.map(\.commit.subject) == ["edit", "rename", "create"])
        #expect(history.map(\.path) == ["new.txt", "new.txt", "old.txt"])
        #expect(history[1].kind == .renamed && history[1].originalPath == "old.txt")
        #expect(history[2].kind == .added)
    }

    @Test func blamesLinesIncludingUncommittedOnes() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("file.txt", "one\ntwo\n")
        try await repo.commitAll("first")
        try repo.write("file.txt", "one\ntwo\nthree\n")
        try await repo.commitAll("second")
        try repo.write("file.txt", "one\nTWO\nthree\n")

        let blame = try await repo.client.blame(path: "file.txt")
        #expect(blame.lines.map(\.text) == ["one", "TWO", "three"])
        #expect(blame.lines.map(\.lineNumber) == [1, 2, 3])
        #expect(blame.lines[1].isUncommitted)
        #expect(blame.commits[blame.lines[0].sha]?.summary == "first")
        #expect(blame.commits[blame.lines[2].sha]?.summary == "second")
        #expect(blame.commits[blame.lines[0].sha]?.authorEmail == "test@example.com")
    }

    @Test func readsTheReflog() async throws {
        let repo = try await TestRepository()
        defer { repo.remove() }
        try repo.write("a.txt", "a\n")
        try await repo.commitAll("one")
        try repo.write("a.txt", "b\n")
        try await repo.commitAll("two")
        try await repo.git("reset", "-q", "--hard", "HEAD~1")

        let reflog = try await repo.client.reflog()
        #expect(reflog.map(\.reflogSelector) == ["HEAD@{0}", "HEAD@{1}", "HEAD@{2}"])
        #expect(reflog[0].reflogSubject?.hasPrefix("reset: moving to") == true)
        #expect(reflog[1].subject == "two")
    }
}
