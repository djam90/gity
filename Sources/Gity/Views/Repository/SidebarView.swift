import AppKit
import GitKit
import SwiftUI

struct SidebarView: View {
    @Bindable var model: RepositoryModel

    @SceneStorage("sidebar.branchesExpanded") private var branchesExpanded = true
    @SceneStorage("sidebar.remotesExpanded") private var remotesExpanded = true
    @SceneStorage("sidebar.tagsExpanded") private var tagsExpanded = false
    @SceneStorage("sidebar.stashesExpanded") private var stashesExpanded = true

    /// A branch dropped onto the current branch, asking whether to merge or rebase.
    @State private var droppedBranch: Branch?

    private var isFiltering: Bool { !model.filterText.trimmingCharacters(in: .whitespaces).isEmpty }
    private var currentName: String { model.currentBranch?.name ?? "HEAD" }
    private var dropTitle: String { droppedBranch.map { "Integrate “\($0.shortName)” into “\(currentName)”?" } ?? "" }

    /// Drop target on the current branch: drag another branch onto it to merge or rebase, like Tower.
    private func acceptingBranchDrops<Content: View>(_ content: Content) -> some View {
        content.dropDestination(for: String.self) { refNames, _ in
            guard let refName = refNames.first, let branch = model.branch(refName), !branch.isHead else { return false }
            droppedBranch = branch
            return true
        }
    }

    var body: some View {
        List(selection: $model.selection) {
            Section("Workspace") {
                Label("Working Copy", systemImage: "square.and.pencil")
                    .badge(model.snapshot?.status.changes.count ?? 0)
                    .tag(SidebarItem.workingCopy)
                Label("History", systemImage: "clock")
                    .tag(SidebarItem.history)
                Label("Reflog", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarItem.reflog)
                    .help("Every commit HEAD has pointed at recently, to find lost work")
            }

            if let snapshot = model.snapshot {
                if isFiltering {
                    filteredSections(snapshot)
                } else {
                    branchSections(snapshot)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.filterText, placement: .sidebar, prompt: "Filter")
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first {
                SidebarContextMenu(model: model, item: item)
            }
        } primaryAction: { items in
            // Double-click a branch to check it out, like Tower and Xcode.
            guard case .ref(let refName)? = items.first, let branch = model.branch(refName) else { return }
            Task { await model.checkout(branch) }
        }
        .onDeleteCommand {
            // Delete key: delete the selected branch, tag or stash, after confirming.
            switch model.selection {
            case .ref(let refName):
                if let branch = model.branch(refName) {
                    Task { await model.delete(branch) }
                } else if let tag = model.tag(refName) {
                    Task { await model.delete(tag) }
                }
            case .stash(let selector):
                if let stash = model.stash(selector) { Task { await model.drop(stash) } }
            default:
                break
            }
        }
        .confirmationDialog(
            dropTitle,
            isPresented: Binding(get: { droppedBranch != nil }, set: { if !$0 { droppedBranch = nil } }),
            presenting: droppedBranch
        ) { branch in
            Button("Merge “\(branch.shortName)” into “\(currentName)”") {
                Task { await model.merge(branch.refName, name: branch.shortName) }
            }
            Button("Rebase “\(currentName)” onto “\(branch.shortName)”") {
                Task { await model.rebase(onto: branch.refName, name: branch.shortName) }
            }
        }
        .overlay {
            if model.snapshot == nil, model.loadError == nil {
                ProgressView()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func branchSections(_ snapshot: RepositorySnapshot) -> some View {
        Section("Branches", isExpanded: $branchesExpanded) {
            if case .unborn(let name) = snapshot.head, snapshot.localBranches.isEmpty {
                // A fresh repository has a current branch that does not exist as a ref yet.
                BranchRow(title: name, branch: nil, isCurrent: true)
                    .foregroundStyle(.secondary)
                    .help("This branch has no commits yet")
            }
            // The checked out branch always comes first, with its full name even if it lives in a folder.
            if let current = snapshot.currentBranch {
                acceptingBranchDrops(
                    BranchRow(title: current.name, branch: current, isCurrent: true)
                        .tag(SidebarItem.ref(current.refName))
                )
            }
            OutlineGroup(model.localBranchTree, children: \.children) { node in
                BranchNodeRow(node: node)
            }
        }

        if !snapshot.remotes.isEmpty {
            Section("Remotes", isExpanded: $remotesExpanded) {
                ForEach(snapshot.remotes) { remote in
                    DisclosureGroup {
                        OutlineGroup(model.remoteBranchTrees[remote.name] ?? [], children: \.children) { node in
                            BranchNodeRow(node: node)
                        }
                    } label: {
                        Label(remote.name, systemImage: "cloud")
                    }
                }
            }
        }

        if !snapshot.tags.isEmpty {
            Section("Tags", isExpanded: $tagsExpanded) {
                ForEach(snapshot.tags) { tag in
                    TagRow(tag: tag)
                }
            }
        }

        if !snapshot.stashes.isEmpty {
            Section("Stashes", isExpanded: $stashesExpanded) {
                ForEach(snapshot.stashes) { stash in
                    StashRow(stash: stash)
                }
            }
        }
    }

    /// While filtering, show a flat list of matches with full names instead of the folder tree.
    @ViewBuilder
    private func filteredSections(_ snapshot: RepositorySnapshot) -> some View {
        let query = model.filterText.trimmingCharacters(in: .whitespaces)
        let locals = snapshot.localBranches
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.isHead && !$1.isHead }
        let remotes = snapshot.remotes.flatMap(\.branches).filter { $0.shortName.localizedCaseInsensitiveContains(query) }
        let tags = snapshot.tags.filter { $0.name.localizedCaseInsensitiveContains(query) }

        if !locals.isEmpty {
            Section("Branches") {
                ForEach(locals) { BranchRow(title: $0.name, branch: $0, isCurrent: $0.isHead).tag(SidebarItem.ref($0.refName)).draggable($0.refName) }
            }
        }
        if !remotes.isEmpty {
            Section("Remotes") {
                ForEach(remotes) { BranchRow(title: $0.shortName, branch: $0, isCurrent: false).tag(SidebarItem.ref($0.refName)).draggable($0.refName) }
            }
        }
        if !tags.isEmpty {
            Section("Tags") {
                ForEach(tags) { TagRow(tag: $0) }
            }
        }
        if locals.isEmpty, remotes.isEmpty, tags.isEmpty {
            Text("No Matches")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .selectionDisabled()
        }
    }
}

// MARK: - Rows

private struct BranchNodeRow: View {
    let node: RefTreeNode<Branch>

    var body: some View {
        if let branch = node.item {
            BranchRow(title: node.name, branch: branch, isCurrent: branch.isHead)
                .tag(SidebarItem.ref(branch.refName))
                .draggable(branch.refName)
        } else {
            Label(node.name, systemImage: "folder")
                .selectionDisabled()
        }
    }
}

struct BranchRow: View {
    let title: String
    let branch: Branch?
    let isCurrent: Bool

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let branch {
                    TrackingBadge(branch: branch)
                }
            }
        } icon: {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .help(helpText)
    }

    private var helpText: String {
        guard let branch else { return title }
        var lines = [branch.shortName]
        if let upstream = branch.upstream {
            lines.append(branch.isUpstreamGone ? "Upstream \(upstream) is gone" : "Tracking \(upstream)")
        }
        if !branch.tipSubject.isEmpty {
            lines.append("\(branch.tipSHA.prefix(7)) \(branch.tipSubject)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Compact ahead/behind indicator, e.g. `↑2 ↓1`.
struct TrackingBadge: View {
    let branch: Branch

    var body: some View {
        HStack(spacing: 4) {
            if branch.isUpstreamGone {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if branch.ahead > 0 {
                Text("↑\(branch.ahead)")
            }
            if branch.behind > 0 {
                Text("↓\(branch.behind)")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

private struct TagRow: View {
    let tag: Tag

    var body: some View {
        Label(tag.name, systemImage: "tag")
            .lineLimit(1)
            .help(tag.subject.isEmpty ? tag.name : "\(tag.name)\n\(tag.subject)")
            .tag(SidebarItem.ref(tag.refName))
    }
}

private struct StashRow: View {
    let stash: Stash

    var body: some View {
        Label(stash.message, systemImage: "archivebox")
            .lineLimit(1)
            .truncationMode(.tail)
            .help("\(stash.selector)\n\(stash.message)")
            .tag(SidebarItem.stash(stash.selector))
    }
}
