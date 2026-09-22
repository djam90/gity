import Foundation
import GitKit
import Observation
import SwiftUI

struct QuickOpenItem: Identifiable, Equatable {
    let url: URL
    let recent: RecentRepository?
    /// Offsets in `name` that matched the query.
    let matchedIndices: [Int]
    let score: Int

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }
}

@Observable
final class QuickOpenModel {
    var query = ""
    var highlightedID: QuickOpenItem.ID?
    /// Bumped on every show so the view can refocus the search field.
    private(set) var presentationCount = 0
    /// Extra repositories found by Spotlight for the current query.
    private(set) var spotlightResults: [URL] = []

    @ObservationIgnored var openWindow: OpenWindowAction?
    /// The repository window Quick Open was invoked from, which a chosen repository replaces.
    @ObservationIgnored weak var targetRepository: RepositoryModel?

    func prepareForShowing() {
        query = ""
        highlightedID = nil
        spotlightResults = []
        presentationCount += 1
    }

    // MARK: - Results

    struct Results {
        var recent: [QuickOpenItem] = []
        var onThisMac: [QuickOpenItem] = []
        var all: [QuickOpenItem] { recent + onThisMac }
    }

    func results(recents: [RecentRepository], discovered: [URL]) -> Results {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            return Results(recent: recents.map { QuickOpenItem(url: $0.url, recent: $0, matchedIndices: [], score: 0) })
        }

        var seen = Set<String>()
        var recent: [QuickOpenItem] = []
        for (rank, repository) in recents.enumerated() where seen.insert(repository.path).inserted {
            // Recently used repositories win ties, the most recent ones a little more.
            if let item = item(for: repository.url, recent: repository, query: query, bonus: 30 - min(rank, 20)) {
                recent.append(item)
            }
        }

        var others: [QuickOpenItem] = []
        for url in discovered + spotlightResults where seen.insert(url.path).inserted {
            if let item = item(for: url, recent: nil, query: query, bonus: 0) {
                others.append(item)
            }
        }

        let byScore: (QuickOpenItem, QuickOpenItem) -> Bool = {
            $0.score != $1.score ? $0.score > $1.score : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Results(recent: recent.sorted(by: byScore), onThisMac: Array(others.sorted(by: byScore).prefix(50)))
    }

    private func item(for url: URL, recent: RecentRepository?, query: String, bonus: Int) -> QuickOpenItem? {
        let name = url.lastPathComponent
        if let match = FuzzyMatcher.match(query, in: name) {
            return QuickOpenItem(url: url, recent: recent, matchedIndices: match.indices, score: match.score + bonus)
        }
        // Fall back to the path (e.g. "work/api"), ranked below any name match.
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        if let match = FuzzyMatcher.match(query, in: path) {
            return QuickOpenItem(url: url, recent: recent, matchedIndices: [], score: match.score / 2 - 40 + bonus)
        }
        return nil
    }

    // MARK: - Spotlight

    /// Looks for repositories outside the scanned folders whose folder name contains the query.
    func searchSpotlight(recents: [RecentRepository]) async {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            spotlightResults = []
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let folders = try? await SpotlightSearch.folders(matching: query, in: home) else { return }

        let recentPaths = recents.map(\.path)
        let found = await Task.detached(priority: .userInitiated) {
            folders.filter { Self.mayProbe($0, home: home, recentPaths: recentPaths) && RepositoryScanner.isRepository($0) }
        }.value
        guard !Task.isCancelled else { return }
        spotlightResults = found
    }

    /// Checking for `.git` inside Desktop, Documents etc. triggers a privacy prompt, which would be
    /// jarring mid-search. Only probe there if the user already opened a repository in that folder.
    private nonisolated static func mayProbe(_ url: URL, home: URL, recentPaths: [String]) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        let homeComponents = home.standardizedFileURL.pathComponents
        guard components.starts(with: homeComponents), components.count > homeComponents.count else { return false }
        let relative = components.dropFirst(homeComponents.count)
        if relative.contains(where: { $0.hasPrefix(".") || RepositoryScanner.skippedDirectoryNames.contains($0) }) {
            return false
        }
        guard let top = relative.first, RepositoryScanner.protectedHomeFolders.contains(top) else { return true }
        let topPath = home.appending(path: top).path + "/"
        return recentPaths.contains { $0.hasPrefix(topPath) }
    }
}
