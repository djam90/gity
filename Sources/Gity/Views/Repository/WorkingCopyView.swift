import GitKit
import SwiftUI

/// Uncommitted changes, with unstaged changes above staged ones like Tower.
/// Space stages or unstages the selected files.
struct WorkingCopyView: View {
    let model: RepositoryModel

    private var sections: [FileSection] {
        let changes = model.snapshot?.status.changes ?? []
        func targets(_ areas: Set<FileChange.Area>) -> [DiffTarget] {
            changes
                .filter { areas.contains($0.area) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .map { DiffTarget(source: .workingCopy($0)) }
        }

        return [
            FileSection(id: "conflicted", title: "Conflicts", targets: targets([.conflicted]), stagingAction: .stage),
            // Untracked files are just changes that have never been staged.
            FileSection(id: "changes", title: "Changes", targets: targets([.unstaged, .untracked]), stagingAction: .stage),
            FileSection(id: "staged", title: "Staged", targets: targets([.staged]), stagingAction: .unstage),
        ]
        .filter { !$0.targets.isEmpty }
    }

    var body: some View {
        let sections = sections
        if sections.isEmpty {
            ContentUnavailableView(
                "Working Copy Clean",
                systemImage: "checkmark.seal",
                description: Text("There are no uncommitted changes.")
            )
        } else {
            ChangesBrowser(model: model, sections: sections, reloadToken: model.revision)
        }
    }
}
