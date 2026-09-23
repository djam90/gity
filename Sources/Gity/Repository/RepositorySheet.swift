import Foundation
import GitKit

/// Sheets a repository window can show. Set `RepositoryModel.activeSheet` to present one.
enum RepositorySheet: Identifiable {
    /// - Parameters:
    ///   - startPoint: Revision to branch from; nil for `HEAD`.
    ///   - startPointName: How the start point is described, e.g. "main" or "a1b2c3d".
    case newBranch(startPoint: String?, startPointName: String)
    case renameBranch(Branch)
    case newTag(target: String, targetName: String)
    /// Choosing where to push a branch that has no upstream yet.
    case push(branch: String)
    case stash
    case editMessage(MessageEditRequest)
    case interactiveRebase(Commit)
    case fileInspector(FileInspectorRequest)

    var id: String {
        switch self {
        case .newBranch(let startPoint, _): "newBranch:\(startPoint ?? "HEAD")"
        case .renameBranch(let branch): "renameBranch:\(branch.refName)"
        case .newTag(let target, _): "newTag:\(target)"
        case .push(let branch): "push:\(branch)"
        case .stash: "stash"
        case .editMessage(let request): "editMessage:\(request.id)"
        case .interactiveRebase(let commit): "rebase:\(commit.sha)"
        case .fileInspector(let request): "inspector:\(request.id)"
        }
    }
}

/// Editing a commit message before rewording or squashing.
struct MessageEditRequest: Identifiable {
    let id = UUID()
    let title: String
    let confirmTitle: String
    let message: String
    let save: (String) async -> Void
}

/// File history and blame for one file.
struct FileInspectorRequest: Identifiable {
    enum Mode: Hashable {
        case history
        case blame
    }

    let id = UUID()
    let path: String
    /// Blame at this commit; nil for the working copy.
    let revision: String?
    var mode: Mode = .history
}

/// Unfinished commit messages, per repository, so they survive switching repositories or quitting.
enum CommitDrafts {
    private static let key = "commitDrafts"

    static func load(for repository: URL) -> String {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[repository.path] ?? ""
    }

    static func save(_ message: String, for repository: URL) {
        var drafts = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard drafts.removeValue(forKey: repository.path) != nil else { return }
        } else {
            drafts[repository.path] = message
        }
        UserDefaults.standard.set(drafts, forKey: key)
    }
}
