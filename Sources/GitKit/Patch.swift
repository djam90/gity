import Foundation

/// Identifies a line in a `FileDiff` by hunk and line index.
public struct DiffLineID: Hashable, Comparable, Sendable {
    public let hunk: Int
    public let line: Int

    public init(hunk: Int, line: Int) {
        self.hunk = hunk
        self.line = line
    }

    public static func < (lhs: DiffLineID, rhs: DiffLineID) -> Bool {
        (lhs.hunk, lhs.line) < (rhs.hunk, rhs.line)
    }
}

/// Builds patches from part of a diff, for staging, unstaging or discarding individual hunks and lines.
public enum PatchBuilder {
    public enum Direction: Sendable {
        /// The patch will be applied as is (staging lines of an unstaged diff).
        case forward
        /// The patch will be applied with `--reverse` (unstaging lines of a staged diff, or
        /// discarding lines of an unstaged diff).
        case reverse
    }

    /// Every added or removed line in `hunk`.
    public static func changedLines(inHunk hunk: Int, of diff: FileDiff) -> Set<DiffLineID> {
        guard diff.hunks.indices.contains(hunk) else { return [] }
        return Set(diff.hunks[hunk].lines.indices.compactMap { index in
            let kind = diff.hunks[hunk].lines[index].kind
            return kind == .addition || kind == .deletion ? DiffLineID(hunk: hunk, line: index) : nil
        })
    }

    /// A patch containing only the `selected` added and removed lines.
    ///
    /// Unselected lines are neutralised so the patch still applies to the side it will be applied
    /// to: going forward, the patch applies to the old side, so unselected removals become context
    /// and unselected additions disappear. In reverse it applies to the new side, so the opposite.
    /// - Returns: `nil` when no changed line is selected or the diff can't be turned into a patch.
    public static func patch(from diff: FileDiff, selecting selected: Set<DiffLineID>, direction: Direction) -> String? {
        guard !diff.isBinary, !diff.isCombined, !diff.isTruncated, !diff.headerLines.isEmpty else { return nil }

        // For a new file this includes `new file mode` and `--- /dev/null`, which git needs to create it.
        var output = diff.headerLines
        var offset = 0
        var hasChanges = false

        for (hunkIndex, hunk) in diff.hunks.enumerated() {
            var body: [String] = []
            var oldCount = 0
            var newCount = 0
            var hunkHasChanges = false
            /// Whether the previous line made it into the patch, for "\ No newline" markers.
            var previousKept = false

            for (lineIndex, line) in hunk.lines.enumerated() {
                let isSelected = selected.contains(DiffLineID(hunk: hunkIndex, line: lineIndex))
                switch line.kind {
                case .context:
                    body.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    previousKept = true
                case .addition:
                    if isSelected {
                        body.append("+" + line.text)
                        newCount += 1
                        hunkHasChanges = true
                        previousKept = true
                    } else if direction == .reverse {
                        body.append(" " + line.text)
                        oldCount += 1
                        newCount += 1
                        previousKept = true
                    } else {
                        previousKept = false
                    }
                case .deletion:
                    if isSelected {
                        body.append("-" + line.text)
                        oldCount += 1
                        hunkHasChanges = true
                        previousKept = true
                    } else if direction == .forward {
                        body.append(" " + line.text)
                        oldCount += 1
                        newCount += 1
                        previousKept = true
                    } else {
                        previousKept = false
                    }
                case .noNewlineMarker:
                    if previousKept {
                        body.append("\\ No newline at end of file")
                    }
                }
            }

            guard hunkHasChanges else { continue }
            hasChanges = true
            // The side the patch applies to keeps its start line (its lines are all still there);
            // the other side follows from the hunks before it. An empty side starts at the line
            // before, which is 0 at the top of the file.
            let oldStart: Int
            let newStart: Int
            switch direction {
            case .forward:
                oldStart = hunk.oldStart
                newStart = oldStart + offset + (oldCount == 0 ? 1 : 0) - (newCount == 0 ? 1 : 0)
            case .reverse:
                newStart = hunk.newStart
                oldStart = newStart - offset + (newCount == 0 ? 1 : 0) - (oldCount == 0 ? 1 : 0)
            }
            output.append("@@ -\(max(oldStart, 0)),\(oldCount) +\(max(newStart, 0)),\(newCount) @@")
            output += body
            offset += newCount - oldCount
        }

        guard hasChanges else { return nil }
        return output.joined(separator: "\n") + "\n"
    }
}
