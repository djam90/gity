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
    public var id: String { sha }
    public let sha: String
    public let shortSHA: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let subject: String
    public let decorations: [Decoration]

    public init(
        sha: String, shortSHA: String, parents: [String], authorName: String, authorEmail: String,
        authorDate: Date, subject: String, decorations: [Decoration]
    ) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.subject = subject
        self.decorations = decorations
    }
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

/// Everything the repository window needs to render its sidebar, fetched in one go.
public struct RepositorySnapshot: Equatable, Sendable {
    public var status: WorkingCopyStatus
    public var localBranches: [Branch]
    public var remotes: [Remote]
    public var tags: [Tag]
    public var stashes: [Stash]

    public init(status: WorkingCopyStatus, localBranches: [Branch], remotes: [Remote], tags: [Tag], stashes: [Stash]) {
        self.status = status
        self.localBranches = localBranches
        self.remotes = remotes
        self.tags = tags
        self.stashes = stashes
    }

    public var head: HeadState { status.head }

    public var currentBranch: Branch? {
        localBranches.first(where: \.isHead)
    }
}
