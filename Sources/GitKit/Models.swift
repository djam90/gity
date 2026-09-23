import Foundation

/// What `HEAD` currently points at.
public enum HeadState: Hashable, Sendable {
    /// On a branch with at least one commit.
    case branch(String)
    /// Detached at the given commit SHA.
    case detached(String)
    /// On a branch that has no commits yet (fresh `git init`).
    case unborn(String)

    public var branchName: String? {
        switch self {
        case .branch(let name), .unborn(let name): name
        case .detached: nil
        }
    }
}

public struct Branch: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case local
        case remote(String)
    }

    public var id: String { refName }

    /// Full ref name, e.g. `refs/heads/feature/login`.
    public let refName: String
    public let kind: Kind
    /// Name relative to its namespace, e.g. `feature/login` (without the remote prefix for remote branches).
    public let name: String
    public let isHead: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let isUpstreamGone: Bool
    public let tipSHA: String
    public let tipSubject: String
    public let tipAuthor: String
    public let tipDate: Date?

    public init(
        refName: String, kind: Kind, name: String, isHead: Bool = false,
        upstream: String? = nil, ahead: Int = 0, behind: Int = 0, isUpstreamGone: Bool = false,
        tipSHA: String = "", tipSubject: String = "", tipAuthor: String = "", tipDate: Date? = nil
    ) {
        self.refName = refName
        self.kind = kind
        self.name = name
        self.isHead = isHead
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isUpstreamGone = isUpstreamGone
        self.tipSHA = tipSHA
        self.tipSubject = tipSubject
        self.tipAuthor = tipAuthor
        self.tipDate = tipDate
    }

    public var isRemote: Bool {
        if case .remote = kind { true } else { false }
    }

    /// Name as git prints it, e.g. `origin/feature/login` for remote branches.
    public var shortName: String {
        if case .remote(let remote) = kind { "\(remote)/\(name)" } else { name }
    }
}

public struct Remote: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let branches: [Branch]

    public init(name: String, branches: [Branch]) {
        self.name = name
        self.branches = branches
    }
}

public struct Tag: Identifiable, Hashable, Sendable {
    public var id: String { refName }
    public let refName: String
    public let name: String
    /// Commit the tag points at (peeled for annotated tags).
    public let targetSHA: String
    public let subject: String
    public let date: Date?

    public init(refName: String, name: String, targetSHA: String, subject: String, date: Date?) {
        self.refName = refName
        self.name = name
        self.targetSHA = targetSHA
        self.subject = subject
        self.date = date
    }
}

public struct Stash: Identifiable, Hashable, Sendable {
    public var id: String { selector }
    /// e.g. `stash@{0}`
    public let selector: String
    public let message: String
    public let date: Date?

    public init(selector: String, message: String, date: Date?) {
        self.selector = selector
        self.message = message
        self.date = date
    }
}

public struct Decoration: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case head
        case localBranch
        case remoteBranch
        case tag
        case other
    }

    public let kind: Kind
    public let name: String
    /// True for the branch `HEAD` points at (`HEAD -> main`).
    public let isCurrent: Bool

    public init(kind: Kind, name: String, isCurrent: Bool = false) {
        self.kind = kind
        self.name = name
        self.isCurrent = isCurrent
    }
}

public struct Commit: Identifiable, Hashable, Sendable {
    /// Reflog entries can list the same commit several times, so they are identified by selector.
    public var id: String { reflogSelector ?? sha }
    public let sha: String
    public let shortSHA: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let subject: String
    public let decorations: [Decoration]
    /// For reflog entries: the selector (`HEAD@{3}`) and what happened (`commit: Fix typo`).
    public let reflogSelector: String?
    public let reflogSubject: String?

    public init(
        sha: String, shortSHA: String, parents: [String], authorName: String, authorEmail: String,
        authorDate: Date, subject: String, decorations: [Decoration],
        reflogSelector: String? = nil, reflogSubject: String? = nil
    ) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.subject = subject
        self.decorations = decorations
        self.reflogSelector = reflogSelector
        self.reflogSubject = reflogSubject
    }

    public var isMerge: Bool { parents.count > 1 }
}

public struct FileChange: Identifiable, Hashable, Sendable {
    public enum Area: Hashable, Sendable, CaseIterable {
        case conflicted
        case staged
        case unstaged
        case untracked
    }

    public enum Kind: Hashable, Sendable {
        case modified
        case added
        case deleted
        case renamed
        case copied
        case typeChanged
        case untracked
        case conflicted
    }

    public var id: String { "\(area):\(path)" }
    public let path: String
    public let originalPath: String?
    public let kind: Kind
    public let area: Area

    public init(path: String, originalPath: String? = nil, kind: Kind, area: Area) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.area = area
    }
}

/// Parsed output of `git status --porcelain=v2 --branch`.
public struct WorkingCopyStatus: Equatable, Sendable {
    public var head: HeadState
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var changes: [FileChange]

    public init(head: HeadState, upstream: String? = nil, ahead: Int = 0, behind: Int = 0, changes: [FileChange] = []) {
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
    }
}

/// A merge, rebase, cherry-pick or revert that stopped part-way, usually because of conflicts.
public struct PendingOperation: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case merge
        case rebase
        case cherryPick
        case revert
    }

    public let kind: Kind
    /// Rebases: the branch being rebased, e.g. `feature`.
    public let branchName: String?
    /// Rebases: the current step and the total number of steps.
    public let step: Int?
    public let totalSteps: Int?
    /// The message git prepared for the resulting commit (`MERGE_MSG`).
    public let message: String?

    public init(kind: Kind, branchName: String? = nil, step: Int? = nil, totalSteps: Int? = nil, message: String? = nil) {
        self.kind = kind
        self.branchName = branchName
        self.step = step
        self.totalSteps = totalSteps
        self.message = message
    }

    public var title: String {
        switch kind {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-Pick"
        case .revert: "Revert"
        }
    }
}

/// Everything the repository window needs to render its sidebar, fetched in one go.
public struct RepositorySnapshot: Equatable, Sendable {
    public var status: WorkingCopyStatus
    public var localBranches: [Branch]
    public var remotes: [Remote]
    public var tags: [Tag]
    public var stashes: [Stash]
    public var pendingOperation: PendingOperation?

    public init(
        status: WorkingCopyStatus, localBranches: [Branch], remotes: [Remote], tags: [Tag], stashes: [Stash],
        pendingOperation: PendingOperation? = nil
    ) {
        self.status = status
        self.localBranches = localBranches
        self.remotes = remotes
        self.tags = tags
        self.stashes = stashes
        self.pendingOperation = pendingOperation
    }

    public var hasConflicts: Bool {
        status.changes.contains { $0.area == .conflicted }
    }

    public var head: HeadState { status.head }

    public var currentBranch: Branch? {
        localBranches.first(where: \.isHead)
    }
}

/// One line of `git blame` output.
public struct BlameLine: Identifiable, Hashable, Sendable {
    public var id: Int { lineNumber }
    public let sha: String
    public let lineNumber: Int
    public let text: String

    public init(sha: String, lineNumber: Int, text: String) {
        self.sha = sha
        self.lineNumber = lineNumber
        self.text = text
    }

    /// Lines changed in the working copy are attributed to the all-zero SHA.
    public var isUncommitted: Bool { sha.allSatisfy { $0 == "0" } }
}

public struct BlameCommit: Hashable, Sendable {
    public let sha: String
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let summary: String

    public init(sha: String, authorName: String, authorEmail: String, authorDate: Date, summary: String) {
        self.sha = sha
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.summary = summary
    }
}

public struct Blame: Hashable, Sendable {
    public var lines: [BlameLine]
    public var commits: [String: BlameCommit]

    public init(lines: [BlameLine] = [], commits: [String: BlameCommit] = [:]) {
        self.lines = lines
        self.commits = commits
    }
}

/// A commit that touched a file, with the file's path in that commit (it may have been renamed since).
public struct FileHistoryEntry: Identifiable, Hashable, Sendable {
    public var id: String { commit.sha }
    public let commit: Commit
    public let path: String
    public let originalPath: String?
    public let kind: FileChange.Kind

    public init(commit: Commit, path: String, originalPath: String? = nil, kind: FileChange.Kind) {
        self.commit = commit
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
    }
}

/// One line of an interactive rebase plan, oldest commit first.
public struct RebaseStep: Identifiable, Hashable, Sendable {
    public enum Action: String, Hashable, Sendable, CaseIterable {
        case pick
        case reword
        case squash
        case fixup
        case drop
    }

    public var id: String { sha }
    public let sha: String
    public var action: Action
    /// Replaces the resulting commit's message. For a commit followed by squashes, the message of the combined commit.
    public var message: String?

    public init(sha: String, action: Action = .pick, message: String? = nil) {
        self.sha = sha
        self.action = action
        self.message = message
    }
}

public enum ResetMode: String, Hashable, Sendable {
    /// Keep changes staged.
    case soft
    /// Keep changes unstaged.
    case mixed
    /// Throw changes away.
    case hard
    /// Like hard, but refuses to overwrite local changes.
    case keep
}
