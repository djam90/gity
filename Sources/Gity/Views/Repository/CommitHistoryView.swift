import AppKit
import GitKit
import SwiftUI

/// Header plus commit list for a branch, tag, stash or the whole repository.
struct CommitHistoryView: View {
    let model: RepositoryModel
    let item: SidebarItem

    @State private var commits: [Commit] = []
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var selectedCommits = Set<Commit.ID>()

    var body: some View {
        VStack(spacing: 0) {
            RefHeaderView(model: model, item: item, commitCount: hasLoaded ? commits.count : nil)
            Divider()
            if let loadError {
                ContentUnavailableView("Couldn’t Load History", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxHeight: .infinity)
            } else if hasLoaded, commits.isEmpty {
                ContentUnavailableView("No Commits Yet", systemImage: "clock", description: Text("Commits will appear here once you make them."))
                    .frame(maxHeight: .infinity)
            } else {
                VSplitView {
                    commitTable
                        .frame(minHeight: 140, idealHeight: 280, maxHeight: .infinity)
                    commitDetail
                        .frame(minHeight: 240, idealHeight: 420, maxHeight: .infinity)
                }
            }
        }
        .task(id: model.revision) {
            await load()
        }
    }

    private var commitTable: some View {
        Table(commits, selection: $selectedCommits) {
            TableColumn("Description") { commit in
                HStack(spacing: 6) {
                    ForEach(commit.decorations.filter { $0.kind != .head }, id: \.self) { decoration in
                        DecorationPill(decoration: decoration)
                    }
                    Text(commit.subject)
                        .lineLimit(1)
                }
            }
            TableColumn("Author") { commit in
                Text(commit.authorName)
                    .lineLimit(1)
                    .help(commit.authorEmail)
            }
            .width(min: 90, ideal: 150, max: 240)
            TableColumn("Date") { commit in
                Text(commit.authorDate.relativeOrAbsolute)
                    .foregroundStyle(.secondary)
                    .help(commit.authorDate.formatted(date: .complete, time: .standard))
            }
            .width(min: 80, ideal: 130, max: 180)
            TableColumn("Commit") { commit in
                Text(commit.shortSHA)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 100)
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: Commit.ID.self) { ids in
            Button("Copy SHA") { copy(ids.sorted().joined(separator: "\n")) }
                .disabled(ids.isEmpty)
            Button("Copy Subject") {
                copy(commits.filter { ids.contains($0.id) }.map(\.subject).joined(separator: "\n"))
            }
            .disabled(ids.isEmpty)
        }
        .overlay {
            if !hasLoaded {
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var commitDetail: some View {
        let selected = commits.filter { selectedCommits.contains($0.id) }
        if selected.count == 1, let commit = selected.first {
            CommitDetailView(model: model, commit: commit)
                .id(commit.id)
        } else if selected.isEmpty {
            ContentUnavailableView("No Commit Selected", systemImage: "circle.dashed", description: Text("Select a commit to see its changes."))
        } else {
            ContentUnavailableView("\(selected.count) Commits Selected", systemImage: "square.stack")
        }
    }

    private func load() async {
        do {
            let loaded = try await model.commits(for: item)
            guard !Task.isCancelled else { return }
            commits = loaded
            loadError = nil
            // Start with the newest commit's details, as Tower and Xcode do.
            selectedCommits.formIntersection(loaded.map(\.id))
            if selectedCommits.isEmpty, let first = loaded.first {
                selectedCommits = [first.id]
            }
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Header

private struct RefHeaderView: View {
    let model: RepositoryModel
    let item: SidebarItem
    let commitCount: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if isCurrentBranch {
                        Text("Current")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(.tint)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if case .ref(let refName) = item, let branch = model.branch(refName), !branch.isHead {
                Button("Check Out") {
                    Task { await model.checkout(branch) }
                }
                .disabled(model.isSwitchingBranch)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var isCurrentBranch: Bool {
        if case .ref(let refName) = item { return model.branch(refName)?.isHead ?? false }
        return false
    }

    private var symbol: String {
        switch item {
        case .history: "clock"
        case .stash: "archivebox"
        case .workingCopy: "square.and.pencil"
        case .ref(let refName):
            if model.tag(refName) != nil { "tag" }
            else if model.branch(refName)?.isRemote == true { "cloud" }
            else { "arrow.triangle.branch" }
        }
    }

    private var title: String {
        switch item {
        case .history: "History"
        case .workingCopy: "Working Copy"
        case .stash(let selector): model.stash(selector)?.message ?? selector
        case .ref(let refName):
            model.branch(refName)?.shortName ?? model.tag(refName)?.name ?? refName
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        switch item {
        case .history:
            parts.append("All branches and tags")
        case .ref(let refName):
            if let branch = model.branch(refName) {
                if let upstream = branch.upstream {
                    if branch.isUpstreamGone {
                        parts.append("Upstream \(upstream) is gone")
                    } else {
                        var tracking = "Tracking \(upstream)"
                        if branch.ahead > 0 || branch.behind > 0 {
                            tracking += " · \(branch.ahead) ahead, \(branch.behind) behind"
                        }
                        parts.append(tracking)
                    }
                } else if !branch.isRemote {
                    parts.append("No upstream branch")
                }
                if let date = branch.tipDate {
                    parts.append("Updated \(date.relativeOrAbsolute)")
                }
            } else if let tag = model.tag(refName) {
                parts.append("Tag at \(tag.targetSHA.prefix(7))")
                if !tag.subject.isEmpty { parts.append(tag.subject) }
            }
        case .stash(let selector):
            parts.append(selector)
            if let date = model.stash(selector)?.date { parts.append(date.relativeOrAbsolute) }
        case .workingCopy:
            break
        }
        if let commitCount {
            parts.append(commitCount >= 500 ? "500+ commits" : "\(commitCount) commit\(commitCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Decorations

private struct DecorationPill: View {
    let decoration: Decoration

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(decoration.name)
                .lineLimit(1)
        }
        .font(.caption.weight(decoration.isCurrent ? .semibold : .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            if decoration.isCurrent {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(color.opacity(0.5))
            }
        }
        .fixedSize()
    }

    private var symbol: String {
        switch decoration.kind {
        case .localBranch: decoration.isCurrent ? "checkmark" : "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        case .head, .other: "circle"
        }
    }

    private var color: Color {
        switch decoration.kind {
        case .localBranch: .accentColor
        case .remoteBranch: .purple
        case .tag: .orange
        case .head, .other: .secondary
        }
    }
}

extension Date {
    /// "5 minutes ago" for the last week, otherwise a short absolute date.
    var relativeOrAbsolute: String {
        if abs(timeIntervalSinceNow) < 7 * 24 * 60 * 60 {
            return formatted(.relative(presentation: .named))
        }
        return formatted(date: .abbreviated, time: .omitted)
    }
}
