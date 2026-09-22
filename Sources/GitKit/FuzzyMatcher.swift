import Foundation

public struct FuzzyMatch: Equatable, Sendable {
    public let score: Int
    /// Character offsets in the candidate that matched the query, for highlighting.
    public let indices: [Int]
}

/// Subsequence matching in the style of editor "quick open" panels: every query character
/// must appear in order, and matches at word starts or in runs score higher.
public enum FuzzyMatcher {
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let needle = query.filter { !$0.isWhitespace }.map(folded)
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, indices: []) }
        let original = Array(candidate)
        let haystack = original.map(folded)

        var best: FuzzyMatch?
        for start in haystack.indices where haystack[start] == needle[0] {
            var indices = [start]
            var position = start + 1
            for character in needle.dropFirst() {
                while position < haystack.count, haystack[position] != character {
                    position += 1
                }
                guard position < haystack.count else { break }
                indices.append(position)
                position += 1
            }
            // If matching from this start ran out of characters, later starts will too.
            guard indices.count == needle.count else { break }

            let score = score(indices, in: original)
            if score > best?.score ?? .min {
                best = FuzzyMatch(score: score, indices: indices)
            }
        }
        return best
    }

    private static func folded(_ character: Character) -> Character {
        String(character).lowercased().first ?? character
    }

    private static func score(_ indices: [Int], in characters: [Character]) -> Int {
        var score = 0
        for (offset, index) in indices.enumerated() {
            score += 10
            if offset == 0 {
                // Where the match starts matters most: the very beginning, then a word start.
                if index == 0 {
                    score += 25
                } else if isWordStart(index, in: characters) {
                    score += 15
                }
            } else if index == indices[offset - 1] + 1 {
                // Runs of consecutive characters beat letters scattered across words.
                score += 20
            } else {
                score -= min(index - indices[offset - 1] - 1, 10)
                if isWordStart(index, in: characters) {
                    score += 10
                }
            }
        }
        // Between otherwise equal matches, prefer the shorter candidate.
        return score - (characters.count - indices.count) / 3
    }

    private static func isWordStart(_ index: Int, in characters: [Character]) -> Bool {
        let previous = characters[index - 1]
        let current = characters[index]
        if " -_./".contains(previous) { return true }
        if previous.isLowercase, current.isUppercase { return true }
        if previous.isLetter, current.isNumber { return true }
        return false
    }
}
