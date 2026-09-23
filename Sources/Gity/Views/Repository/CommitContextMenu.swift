import AppKit
import GitKit
import SwiftUI

/// Actions on commits in a history list: branching, cherry-picking, resetting and rewriting.
struct CommitContextMenu: View {
    let model: RepositoryModel
    let commits: [Commit]
    /// Commits on the current branch's first-parent line, which rewriting actions can change.
    let rewritable: Set<String>

    private var currentName: String { model.currentBranch.map { "“\($0.name)”" } ?? "HEAD" }

    var body: some View {
        if commits.count == 1, let commit = commits.first {
            singleCommitItems(commit)
        } else if commits.count > 1 {
            let onBranch = commits.allSatisfy { rewritable.contains($0.sha) }
            Button("Cherry-Pick \(commits.count) Commits onto \(currentName)") {
                Task { await model.cherryPick(commits) }
            }
            .disabled(onBranch || model.currentBranch == nil)
            Divider()
        }
        if !commits.isEmpty {
            Button(commits.count == 1 ? "Copy SHA" : "Copy SHAs") {
                copy(commits.map(\.sha).joined(separator: "\n"))
            }
            Button(commits.count == 1 ? "Copy Subject" : "Copy Subjects") {
                copy(commits.map(\.subject).joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder
    private func singleCommitItems(_ commit: Commit) -> some View {
        let isOnBranch = rewritable.contains(commit.sha)
        let hasBranch = model.currentBranch != nil

        Button("Check Out \(commit.shortSHA)…") {
            Task { await model.checkoutDetached(commit.sha, name: "commit \(commit.shortSHA)") }
        }
        Button("New Branch Here…") {
            model.activeSheet = .newBranch(startPoint: commit.sha, startPointName: commit.shortSHA)
        }
        Button("New Tag Here…") {
            model.activeSheet = .newTag(target: commit.sha, targetName: commit.shortSHA)
        }

        Divider()

        if !isOnBranch {
            Button("Cherry-Pick onto \(currentName)") { Task { await model.cherryPick([commit]) } }
                .disabled(!hasBranch)
        }
        Button("Revert Commit") { Task { await model.revert(commit) } }
            .disabled(!hasBranch)
            .help("Make a new commit that undoes this commit’s changes")
        Menu("Reset \(currentName) to Here") {
            Button("Soft: Keep Changes Staged") { Task { await model.reset(to: commit, mode: .soft) } }
            Button("Mixed: Keep Changes Unstaged") { Task { await model.reset(to: commit, mode: .mixed) } }
            Button("Hard: Discard All Changes…") { Task { await model.reset(to: commit, mode: .hard) } }
        }
        .disabled(!hasBranch)

        if isOnBranch, !commit.isMerge {
            Divider()
            Button("Edit Message…") { Task { await model.editMessage(of: commit) } }
            Button("Squash into Parent…") { Task { await model.squashIntoParent(commit) } }
                .disabled(commit.parents.first.map { !rewritable.contains($0) } ?? true)
            Button("Delete Commit…") { Task { await model.dropCommit(commit) } }
            Button("Interactive Rebase from Here…") { Task { await model.startInteractiveRebase(from: commit) } }
                .help("Reorder, squash, reword or delete this commit and the ones after it")
        }

        Divider()
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
