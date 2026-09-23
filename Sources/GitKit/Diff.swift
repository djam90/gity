import Foundation

public struct DiffOptions: Hashable, Sendable {
    public var ignoreWhitespace: Bool
    public var contextLines: Int

    public init(ignoreWhitespace: Bool = false, contextLines: Int = 3) {
        self.ignoreWhitespace = ignoreWhitespace
        self.contextLines = contextLines
    }

    var arguments: [String] {
        ["-U\(max(0, contextLines))"] + (ignoreWhitespace ? ["--ignore-all-space"] : [])
    }
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case context
        case addition
        case deletion
        /// `\ No newline at end of file`
        case noNewlineMarker
    }

    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffHunk: Hashable, Sendable {
    /// The full `@@ -a,b +c,d @@ context` line.
    public let header: String
    public let lines: [DiffLine]
    /// Start lines from the header, as written (`0` for an empty side).
    public let oldStart: Int
    public let newStart: Int

    public init(header: String, lines: [DiffLine], oldStart: Int = 1, newStart: Int = 1) {
        self.header = header
        self.lines = lines
        self.oldStart = oldStart
        self.newStart = newStart
    }
}

public struct FileDiff: Hashable, Sendable {
    /// Lines before the first hunk (`diff --git`, `index`, `---`, `+++`…), needed to build patches.
    public var headerLines: [String] = []
    /// True for combined diffs (conflicts), which can't be turned into patches.
    public var isCombined = false
    public var hunks: [DiffHunk]
    public var isBinary: Bool
    /// Counted over the whole diff, even when `isTruncated`.
    public var additions: Int
    public var deletions: Int
    /// Number of diff lines (excluding hunk headers) in the whole diff.
    public var lineCount: Int
    /// True when parsing stopped at `maxLines`; `hunks` then holds only the beginning.
    public var isTruncated: Bool

    public init(hunks: [DiffHunk] = [], isBinary: Bool = false, additions: Int = 0, deletions: Int = 0, lineCount: Int = 0, isTruncated: Bool = false) {
        self.hunks = hunks
        self.isBinary = isBinary
        self.additions = additions
        self.deletions = deletions
        self.lineCount = lineCount
        self.isTruncated = isTruncated
    }

    public var isEmpty: Bool { hunks.isEmpty && !isBinary }
}

/// A file touched by a commit.
public struct CommitFileChange: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let kind: FileChange.Kind

    public init(path: String, originalPath: String? = nil, kind: FileChange.Kind) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
    }
}

extension GitParser {
    /// Parses unified diff output for a single file. Also understands combined diffs (`@@@`),
    /// which git produces for conflicted files.
    /// - Parameter maxLines: Stop storing lines after this many (counts still cover everything).
    public static func diff(_ output: String, maxLines: Int? = nil) -> FileDiff {
        var result = FileDiff()
        var isInHunk = false
        var hunkHeader: String?
        var hunkLines: [DiffLine] = []
        var markerWidth = 1
        var oldNumber = 0
        var newNumber = 0
        var starts = (old: 0, new: 0)

        func finishHunk() {
            if let hunkHeader {
                result.hunks.append(DiffHunk(header: hunkHeader, lines: hunkLines, oldStart: starts.old, newStart: starts.new))
            }
            hunkHeader = nil
            hunkLines = []
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine

            if line.hasPrefix("@@") {
                finishHunk()
                isInHunk = true
                // `@@` for normal diffs, `@@@` for combined diffs with two parents.
                markerWidth = max(1, line.prefix { $0 == "@" }.count - 1)
                result.isCombined = markerWidth > 1
                starts = parseHunkStarts(line)
                (oldNumber, newNumber) = (max(starts.old, 1), max(starts.new, 1))
                if !result.isTruncated {
                    hunkHeader = String(line)
                }
                continue
            }

            guard isInHunk, let first = line.first, isHunkPrefix(first) else {
                // File headers, or the end of a hunk (e.g. the next `diff --git`).
                if isInHunk {
                    finishHunk()
                    isInHunk = false
                }
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    result.isBinary = true
                }
                if result.hunks.isEmpty, !line.isEmpty {
                    result.headerLines.append(String(line))
                }
                continue
            }

            let diffLine: DiffLine
            if first == "\\" {
                diffLine = DiffLine(kind: .noNewlineMarker, text: String(line.dropFirst(2)), oldNumber: nil, newNumber: nil)
            } else {
                let markers = line.prefix(markerWidth)
                // Kept verbatim (tabs, trailing spaces) so lines can be turned back into patches.
                let text = String(line.dropFirst(markerWidth))
                if markers.contains("+") {
                    diffLine = DiffLine(kind: .addition, text: text, oldNumber: nil, newNumber: newNumber)
                    newNumber += 1
                    result.additions += 1
                } else if markers.contains("-") {
                    diffLine = DiffLine(kind: .deletion, text: text, oldNumber: oldNumber, newNumber: nil)
                    oldNumber += 1
                    result.deletions += 1
                } else {
                    diffLine = DiffLine(kind: .context, text: text, oldNumber: oldNumber, newNumber: newNumber)
                    oldNumber += 1
                    newNumber += 1
                }
                result.lineCount += 1
            }

            if result.isTruncated { continue }
            if let maxLines, result.lineCount > maxLines {
                finishHunk()
                result.isTruncated = true
                continue
            }
            hunkLines.append(diffLine)
        }
        finishHunk()
        return result
    }

    private static func isHunkPrefix(_ character: Character) -> Bool {
        character == " " || character == "+" || character == "-" || character == "\\"
    }

    /// Extracts start line numbers from `@@ -a,b +c,d @@` or `@@@ -a,b -c,d +e,f @@@`, as written.
    static func parseHunkStarts(_ header: Substring) -> (old: Int, new: Int) {
        var old: Int?
        var new = 0
        for token in header.split(separator: " ").dropFirst() {
            if token.hasPrefix("@") { break }
            let start = Int(token.dropFirst().prefix { $0 != "," }) ?? 0
            if token.hasPrefix("-"), old == nil { old = start }
            if token.hasPrefix("+") { new = start }
        }
        return (old ?? 0, new)
    }

    /// Parses `git diff --name-status -z` output.
    public static func nameStatus(_ data: Data) -> [CommitFileChange] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var result: [CommitFileChange] = []
        var index = 0
        while index < tokens.count {
            let status = tokens[index]
            index += 1
            guard let code = status.first else { continue }
            if code == "R" || code == "C" {
                guard index + 1 < tokens.count else { break }
                result.append(CommitFileChange(path: tokens[index + 1], originalPath: tokens[index], kind: code == "R" ? .renamed : .copied))
                index += 2
            } else {
                guard index < tokens.count else { break }
                let kind: FileChange.Kind = switch code {
                case "A": .added
                case "D": .deleted
                case "T": .typeChanged
                case "U": .conflicted
                default: .modified
                }
                result.append(CommitFileChange(path: tokens[index], kind: kind))
                index += 1
            }
        }
        return result
    }
}
