import Foundation
import GitKit

/// A single file whose diff can be shown: either a working copy entry or a file in a commit.
struct DiffTarget: Identifiable, Hashable {
    enum Source: Hashable {
        case workingCopy(FileChange)
        case commit(Commit, CommitFileChange)
    }

    let source: Source

    var id: String {
        switch source {
        case .workingCopy(let change): "wc:\(change.id)"
        case .commit(let commit, let file): "\(commit.sha):\(file.path)"
        }
    }

    var path: String {
        switch source {
        case .workingCopy(let change): change.path
        case .commit(_, let file): file.path
        }
    }

    var originalPath: String? {
        switch source {
        case .workingCopy(let change): change.originalPath
        case .commit(_, let file): file.originalPath
        }
    }

    var kind: FileChange.Kind {
        switch source {
        case .workingCopy(let change): change.kind
        case .commit(_, let file): file.kind
        }
    }

    var workingCopyChange: FileChange? {
        if case .workingCopy(let change) = source { change } else { nil }
    }

    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

struct FileSection: Identifiable {
    /// What the section header button (and the space bar) does to files in this section.
    enum StagingAction {
        case stage
        case unstage
    }

    let id: String
    let title: String
    let targets: [DiffTarget]
    var stagingAction: StagingAction? = nil
}
