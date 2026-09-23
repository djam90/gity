import GitKit
import SwiftUI

/// Shown above the detail view while a merge, rebase, cherry-pick or revert is stopped, or
/// files are conflicted: says what's going on and offers to continue or abort.
struct PendingOperationBanner: View {
    let model: RepositoryModel

    private var conflictCount: Int {
        model.snapshot?.status.changes.filter { $0.area == .conflicted }.count ?? 0
    }

    var body: some View {
        let operation = model.snapshot?.pendingOperation
        if operation != nil || conflictCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: conflictCount > 0 ? "exclamationmark.triangle.fill" : "pause.circle.fill")
                    .font(.title3)
                    .foregroundStyle(conflictCount > 0 ? .orange : .accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(operation))
                        .fontWeight(.semibold)
                    Text(detail(operation))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if conflictCount > 0, model.selection != .workingCopy {
                    Button("Show Conflicts") { model.selection = .workingCopy }
                }
                if let operation {
                    if operation.kind == .rebase {
                        Button("Skip Commit") { Task { await model.skipRebaseStep() } }
                            .help("Leave out the commit the rebase stopped at")
                    }
                    Button("Abort") { Task { await model.abortPendingOperation() } }
                    Button("Continue") { Task { await model.continuePendingOperation() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(conflictCount > 0)
                        .help(conflictCount > 0 ? "Resolve all conflicts first" : "Continue the \(operation.title.lowercased())")
                }
            }
            .disabled(model.isBusy)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(conflictCount > 0 ? AnyShapeStyle(Color.orange.opacity(0.12)) : AnyShapeStyle(Color.accentColor.opacity(0.1)))
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func title(_ operation: PendingOperation?) -> String {
        guard let operation else { return "Conflicts after applying changes" }
        switch operation.kind {
        case .rebase:
            let branch = operation.branchName.map { " “\($0)”" } ?? ""
            if let step = operation.step, let total = operation.totalSteps {
                return "Rebasing\(branch), commit \(step) of \(total)"
            }
            return "Rebasing\(branch)"
        case .merge: return "Merge in progress"
        case .cherryPick: return "Cherry-pick in progress"
        case .revert: return "Revert in progress"
        }
    }

    private func detail(_ operation: PendingOperation?) -> String {
        if conflictCount > 0 {
            let files = "\(conflictCount) conflicted file\(conflictCount == 1 ? "" : "s")"
            if operation == nil {
                return "\(files). Resolve them, then mark them as resolved by staging them."
            }
            return "\(files). Resolve them from the Working Copy, then continue."
        }
        switch operation?.kind {
        case .merge: return "All conflicts are resolved. Continue to commit the merge."
        case .rebase: return "Stopped to let you make changes. Continue when you’re done."
        default: return "All conflicts are resolved. Continue to commit."
        }
    }
}
