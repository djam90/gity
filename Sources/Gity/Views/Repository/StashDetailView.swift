import GitKit
import SwiftUI

/// A stash's changes, with buttons to apply or delete it.
struct StashDetailView: View {
    let model: RepositoryModel
    let selector: String

    @State private var sections: [FileSection]?
    @State private var loadError: String?

    private var stash: Stash? { model.stash(selector) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let loadError {
                ContentUnavailableView("Couldn’t Load Stash", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxHeight: .infinity)
            } else if let sections {
                if sections.isEmpty {
                    ContentUnavailableView("No Changed Files", systemImage: "archivebox")
                        .frame(maxHeight: .infinity)
                } else {
                    ChangesBrowser(model: model, sections: sections)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.revision) {
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(stash?.message ?? selector)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text([selector, stash?.date?.relativeOrAbsolute].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let stash {
                Button("Delete…") { Task { await model.drop(stash) } }
                Button("Apply") { Task { await model.apply(stash, pop: false) } }
                    .help("Apply the changes and keep the stash")
                Button("Apply and Delete") { Task { await model.apply(stash, pop: true) } }
                    .buttonStyle(.borderedProminent)
                    .help("Apply the changes, then delete the stash (git stash pop)")
            }
        }
        .disabled(model.isBusy)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func load() async {
        do {
            guard let commit = try await model.stashCommit(selector) else {
                sections = []
                return
            }
            var loaded = [FileSection]()
            let files = try await model.changedFiles(in: commit)
            if !files.isEmpty {
                loaded.append(FileSection(id: "changes", title: "Changes", targets: files.map { DiffTarget(source: .commit(commit, $0)) }))
            }
            // A stash made with untracked files keeps them in a third, parentless commit.
            if commit.parents.count > 2 {
                let untrackedCommit = Commit(
                    sha: commit.parents[2], shortSHA: String(commit.parents[2].prefix(7)), parents: [],
                    authorName: commit.authorName, authorEmail: commit.authorEmail, authorDate: commit.authorDate,
                    subject: commit.subject, decorations: []
                )
                let untracked = try await model.changedFiles(in: untrackedCommit)
                if !untracked.isEmpty {
                    loaded.append(FileSection(
                        id: "untracked",
                        title: "Untracked Files",
                        targets: untracked.map { DiffTarget(source: .commit(untrackedCommit, $0)) }
                    ))
                }
            }
            sections = loaded
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
