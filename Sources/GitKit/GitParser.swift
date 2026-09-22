import Foundation

/// Pure functions that turn git's machine-readable output into models.
/// Kept free of process handling so they can be unit tested with fixture strings.
public enum GitParser {
    static let fieldSeparator: Character = "\u{1f}"
    static let recordSeparator: Character = "\u{1e}"

    // MARK: - Refs

    /// Format passed to `git for-each-ref`. Fields are separated by ASCII unit separators.
    public static let refFormat = [
        "%(refname)",
        "%(objectname)",
        "%(*objectname)",
        "%(HEAD)",
        "%(upstream:short)",
        "%(upstream:track)",
        "%(creatordate:unix)",
        "%(authorname)",
        "%(taggername)",
        "%(symref)",
        "%(contents:subject)",
    ].joined(separator: "%1f")

    public struct Refs: Equatable, Sendable {
        public var localBranches: [Branch] = []
        public var remotes: [Remote] = []
        public var tags: [Tag] = []
    }

    /// Parses `git for-each-ref --format=<refFormat>` output.
    /// - Parameter remoteNames: output of `git remote`, used to split `refs/remotes/<remote>/<branch>`
    ///   correctly even when remote names contain slashes.
    public static func refs(_ output: String, remoteNames: [String]) -> Refs {
        var local: [Branch] = []
        var remoteBranches: [String: [Branch]] = [:]
        var tags: [Tag] = []

        // Longest names first so `upstream/fork` wins over `upstream`.
        let sortedRemotes = remoteNames.sorted { $0.count > $1.count }

        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 11 else { continue }

            let refName = fields[0]
            let objectName = fields[1]
            let peeledObjectName = fields[2]
            let isHead = fields[3] == "*"
            let upstream = fields[4].isEmpty ? nil : fields[4]
            let tracking = trackingCounts(fields[5])
            let date = TimeInterval(fields[6]).map(Date.init(timeIntervalSince1970:))
            let author = fields[7].isEmpty ? fields[8] : fields[7]
            let isSymref = !fields[9].isEmpty
            let subject = fields[10...].joined(separator: String(fieldSeparator))

            if let name = refName.dropPrefix("refs/heads/") {
                local.append(Branch(
                    refName: refName, kind: .local, name: name, isHead: isHead,
                    upstream: upstream, ahead: tracking.ahead, behind: tracking.behind, isUpstreamGone: tracking.gone,
                    tipSHA: objectName, tipSubject: subject, tipAuthor: author, tipDate: date
                ))
            } else if let remotePath = refName.dropPrefix("refs/remotes/") {
                // Skip `origin/HEAD`, which is a symbolic pointer rather than a real branch.
                guard !isSymref else { continue }
                let remote = sortedRemotes.first { remotePath.hasPrefix($0 + "/") }
                    ?? String(remotePath.prefix { $0 != "/" })
                let name = String(remotePath.dropFirst(remote.count + 1))
                guard !name.isEmpty else { continue }
                remoteBranches[remote, default: []].append(Branch(
                    refName: refName, kind: .remote(remote), name: name,
                    tipSHA: objectName, tipSubject: subject, tipAuthor: author, tipDate: date
                ))
            } else if let name = refName.dropPrefix("refs/tags/") {
                tags.append(Tag(
                    refName: refName, name: name,
                    targetSHA: peeledObjectName.isEmpty ? objectName : peeledObjectName,
                    subject: subject, date: date
                ))
            }
        }

        // Include remotes that have not been fetched yet so they still show up.
        let allRemoteNames = Set(remoteNames).union(remoteBranches.keys)
        let remotes = allRemoteNames
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Remote(name: $0, branches: remoteBranches[$0] ?? []) }

        // Newest tags first; that is almost always what people are looking for.
        tags.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        return Refs(localBranches: local, remotes: remotes, tags: tags)
    }

    /// Parses `%(upstream:track)` values like `[ahead 2, behind 1]` or `[gone]`.
    public static func trackingCounts(_ value: String) -> (ahead: Int, behind: Int, gone: Bool) {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        guard !trimmed.isEmpty else { return (0, 0, false) }
        if trimmed == "gone" { return (0, 0, true) }

        var ahead = 0
        var behind = 0
        for part in trimmed.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            switch words[0] {
            case "ahead": ahead = count
            case "behind": behind = count
            default: break
            }
        }
        return (ahead, behind, false)
    }

    // MARK: - Status

    /// Parses `git status --porcelain=v2 --branch -z`.
    public static func status(_ data: Data) -> WorkingCopyStatus {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }

        var oid: String?
        var headName: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changes: [FileChange] = []

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1

            if let header = token.dropPrefix("# ") {
                let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": oid = parts[1]
                case "branch.head": headName = parts[1]
                case "branch.upstream": upstream = parts[1]
                case "branch.ab":
                    for value in parts[1].split(separator: " ") {
                        if value.hasPrefix("+") { ahead = Int(value.dropFirst()) ?? 0 }
                        if value.hasPrefix("-") { behind = Int(value.dropFirst()) ?? 0 }
                    }
                default: break
                }
                continue
            }

            guard let type = token.first else { continue }
            switch type {
            case "1":
                // 1 XY sub mH mI mW hH hI <path>
                let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                changes += entries(xy: fields[1], path: String(fields[8]), originalPath: nil)
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore <path>, followed by a NUL-separated original path
                let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                let original = index < tokens.count ? tokens[index] : nil
                index += 1
                changes += entries(xy: fields[1], path: String(fields[9]), originalPath: original)
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 <path>
                let fields = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                changes.append(FileChange(path: String(fields[10]), kind: .conflicted, area: .conflicted))
            case "?":
                changes.append(FileChange(path: String(token.dropFirst(2)), kind: .untracked, area: .untracked))
            default:
                continue
            }
        }

        let head: HeadState
        switch (headName, oid) {
        case ("(detached)", let oid?): head = .detached(oid)
        case (let name?, "(initial)"): head = .unborn(name)
        case (let name?, _): head = .branch(name)
        default: head = .detached(oid ?? "")
        }

        return WorkingCopyStatus(head: head, upstream: upstream, ahead: ahead, behind: behind, changes: changes)
    }

    private static func entries(xy: Substring, path: String, originalPath: String?) -> [FileChange] {
        let codes = Array(xy)
        guard codes.count == 2 else { return [] }
        var result: [FileChange] = []
        if let kind = changeKind(codes[0]) {
            result.append(FileChange(path: path, originalPath: originalPath, kind: kind, area: .staged))
        }
        if let kind = changeKind(codes[1]) {
            result.append(FileChange(path: path, originalPath: originalPath, kind: kind, area: .unstaged))
        }
        return result
    }

    private static func changeKind(_ code: Character) -> FileChange.Kind? {
        switch code {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        default: nil
        }
    }

    // MARK: - Log

    /// Format passed to `git log`. Records end with an ASCII record separator.
    public static let logFormat = ["%H", "%h", "%P", "%an", "%ae", "%at", "%D", "%s"].joined(separator: "%x1f") + "%x1e"

    /// Parses `git log --decorate=full --format=<logFormat>` output.
    public static func commits(_ output: String) -> [Commit] {
        output.split(separator: recordSeparator).compactMap { record in
            let fields = record.drop { $0.isNewline }
                .split(separator: fieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 8 else { return nil }
            return Commit(
                sha: fields[0],
                shortSHA: fields[1],
                parents: fields[2].split(separator: " ").map(String.init),
                authorName: fields[3],
                authorEmail: fields[4],
                authorDate: Date(timeIntervalSince1970: TimeInterval(fields[5]) ?? 0),
                subject: fields[7...].joined(separator: String(fieldSeparator)),
                decorations: decorations(fields[6])
            )
        }
    }

    /// Parses a full-name `%D` decoration list, e.g.
    /// `HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1.0`.
    public static func decorations(_ value: String) -> [Decoration] {
        guard !value.isEmpty else { return [] }
        var result: [Decoration] = []
        for rawItem in value.components(separatedBy: ", ") {
            var item = rawItem
            if let target = item.dropPrefix("HEAD -> ") {
                result.append(Decoration(kind: .head, name: "HEAD"))
                item = target
                if let name = item.dropPrefix("refs/heads/") {
                    result.append(Decoration(kind: .localBranch, name: name, isCurrent: true))
                    continue
                }
            }

            if item == "HEAD" {
                result.append(Decoration(kind: .head, name: "HEAD"))
            } else if let name = item.dropPrefix("tag: ")?.dropPrefix("refs/tags/") ?? item.dropPrefix("tag: ") {
                result.append(Decoration(kind: .tag, name: name))
            } else if let name = item.dropPrefix("refs/heads/") {
                result.append(Decoration(kind: .localBranch, name: name))
            } else if let name = item.dropPrefix("refs/remotes/") {
                // `origin/HEAD` adds noise next to `origin/main`.
                guard !name.hasSuffix("/HEAD") else { continue }
                result.append(Decoration(kind: .remoteBranch, name: name))
            } else {
                result.append(Decoration(kind: .other, name: item))
            }
        }
        return result
    }

    // MARK: - Stashes

    public static let stashFormat = "%gd%x1f%ct%x1f%gs"

    public static func stashes(_ output: String) -> [Stash] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: fieldSeparator, maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { return nil }
            return Stash(
                selector: fields[0],
                message: fields[2],
                date: TimeInterval(fields[1]).map(Date.init(timeIntervalSince1970:))
            )
        }
    }
}

extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
