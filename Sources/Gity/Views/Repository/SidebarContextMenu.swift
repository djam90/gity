import AppKit
import GitKit
import SwiftUI

/// Context menu for sidebar items: branch, tag and stash management.
struct SidebarContextMenu: View {
    let model: RepositoryModel
    let item: SidebarItem

    var body: some View {
        switch item {
        case .ref(let refName):
            if let branch = model.branch(refName) {
                if branch.isRemote {
                    remoteBranchMenu(branch)
                } else {
                    localBranchMenu(branch)
                }
            } else if let tag = model.tag(refName) {
                tagMenu(tag)
            }
        case .stash(let selector):
            if let stash = model.stash(selector) {
                stashMenu(stash)
            }
        case .workingCopy, .history, .reflog:
            Button("Show in Finder") { model.revealInFinder() }
            Button("Open in Terminal") { model.openInTerminal() }
        }
    }

    private var currentName: String? { model.currentBranch?.name }

    // MARK: - Branches

    @ViewBuilder
    private func localBranchMenu(_ branch: Branch) -> some View {
        Button("Check Out “\(branch.name)”") { run { await model.checkout(branch) } }
            .disabled(branch.isHead)
        integrationItems(for: branch)
        Divider()
        Button("New Branch from “\(branch.name)”…") {
            model.activeSheet = .newBranch(startPoint: branch.refName, startPointName: branch.name)
        }
        Button("New Tag at “\(branch.name)”…") {
            model.activeSheet = .newTag(target: branch.tipSHA, targetName: branch.name)
        }
        Button("Rename “\(branch.name)”…") { model.activeSheet = .renameBranch(branch) }
        Button("Delete “\(branch.name)”…") { run { await model.delete(branch) } }
            .disabled(branch.isHead)
        Divider()
        upstreamMenu(for: branch)
        if branch.isHead {
            Button("Push “\(branch.name)”") { run { await model.push() } }
        }
        Divider()
        copyItems(name: branch.name, sha: branch.tipSHA)
    }

    @ViewBuilder
    private func remoteBranchMenu(_ branch: Branch) -> some View {
        Button("Check Out as Local Branch") { run { await model.checkout(branch) } }
        integrationItems(for: branch)
        Divider()
        Button("New Branch from “\(branch.shortName)”…") {
            model.activeSheet = .newBranch(startPoint: branch.refName, startPointName: branch.shortName)
        }
        Button("Delete “\(branch.shortName)” from Remote…") { run { await model.delete(branch) } }
        Divider()
        copyItems(name: branch.shortName, sha: branch.tipSHA)
    }

    /// Merge and rebase items relative to the current branch.
    @ViewBuilder
    private func integrationItems(for branch: Branch) -> some View {
        if let currentName, !branch.isHead {
            Divider()
            Button("Merge “\(branch.shortName)” into “\(currentName)”") {
                run { await model.merge(branch.refName, name: branch.shortName) }
            }
            Button("Rebase “\(currentName)” onto “\(branch.shortName)”") {
                run { await model.rebase(onto: branch.refName, name: branch.shortName) }
            }
        }
    }

    @ViewBuilder
    private func upstreamMenu(for branch: Branch) -> some View {
        let remoteBranches = model.snapshot?.remotes.flatMap(\.branches) ?? []
        Menu("Track Remote Branch") {
            ForEach(remoteBranches) { remoteBranch in
                Toggle(remoteBranch.shortName, isOn: Binding(
                    get: { branch.upstream == remoteBranch.shortName },
                    set: { _ in run { await model.setUpstream(of: branch, to: remoteBranch) } }
                ))
            }
            if branch.upstream != nil {
                Divider()
                Button("Stop Tracking \(branch.upstream ?? "")") {
                    run { await model.setUpstream(of: branch, to: nil) }
                }
            }
        }
        .disabled(remoteBranches.isEmpty)
    }

    // MARK: - Tags

    @ViewBuilder
    private func tagMenu(_ tag: Tag) -> some View {
        Button("Check Out “\(tag.name)”…") { run { await model.checkoutDetached(tag.refName, name: "tag “\(tag.name)”") } }
        if let currentName {
            Button("Merge “\(tag.name)” into “\(currentName)”") { run { await model.merge(tag.refName, name: tag.name) } }
        }
        Divider()
        Button("New Branch from “\(tag.name)”…") {
            model.activeSheet = .newBranch(startPoint: tag.refName, startPointName: tag.name)
        }
        let remotes = model.snapshot?.remotes ?? []
        if remotes.count == 1, let remote = remotes.first {
            Button("Push to “\(remote.name)”") { run { await model.push(tag, to: remote.name) } }
        } else if !remotes.isEmpty {
            Menu("Push To") {
                ForEach(remotes) { remote in
                    Button(remote.name) { run { await model.push(tag, to: remote.name) } }
                }
            }
        }
        Button("Delete “\(tag.name)”…") { run { await model.delete(tag) } }
        Divider()
        copyItems(name: tag.name, sha: tag.targetSHA)
    }

    // MARK: - Stashes

    @ViewBuilder
    private func stashMenu(_ stash: Stash) -> some View {
        Button("Apply Stash") { run { await model.apply(stash, pop: false) } }
        Button("Apply and Delete Stash") { run { await model.apply(stash, pop: true) } }
        Divider()
        Button("Delete Stash…") { run { await model.drop(stash) } }
        Divider()
        Button("Copy Stash Name") { copy(stash.selector) }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func copyItems(name: String, sha: String) -> some View {
        Button("Copy Name") { copy(name) }
        Button("Copy Commit SHA") { copy(sha) }
    }

    private func run(_ action: @escaping () async -> Void) {
        Task { await action() }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
