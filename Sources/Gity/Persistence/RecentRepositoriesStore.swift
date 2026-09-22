import Foundation
import Observation

struct RecentRepository: Codable, Identifiable, Hashable {
    var id: UUID
    /// Last known path. Kept alongside the bookmark so we can still show something if resolution fails.
    var path: String
    /// File bookmark, so repositories that are moved or renamed in Finder are still found.
    var bookmark: Data?
    var lastOpened: Date

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }

    /// Path with the home directory abbreviated to `~`.
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Most recently opened repositories, persisted as JSON in Application Support.
///
/// Small, user-owned app state like this belongs in Application Support rather than
/// UserDefaults (which is meant for preferences). Writes are atomic so a crash can never
/// leave a half-written file behind.
@Observable
final class RecentRepositoriesStore {
    private(set) var repositories: [RecentRepository] = []

    static let maximumCount = 20

    private let fileURL: URL

    init(fileURL: URL = RecentRepositoriesStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    static var defaultFileURL: URL {
        let identifier = Bundle.main.bundleIdentifier ?? "com.gity.Gity"
        return URL.applicationSupportDirectory
            .appending(path: identifier, directoryHint: .isDirectory)
            .appending(path: "RecentRepositories.json", directoryHint: .notDirectory)
    }

    /// Moves `url` to the top of the list, adding it if needed.
    func noteOpened(_ url: URL) {
        let path = url.standardizedFileURL.path
        // Compare resolved paths so `/tmp/x` and `/private/tmp/x` count as the same repository.
        let canonicalPath = Self.canonicalPath(path)
        var entry = repositories.first { Self.canonicalPath($0.path) == canonicalPath }
            ?? RecentRepository(id: UUID(), path: path, bookmark: nil, lastOpened: .now)
        entry.lastOpened = .now
        entry.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

        entry.path = path
        repositories.removeAll { $0.id == entry.id || Self.canonicalPath($0.path) == canonicalPath }
        repositories.insert(entry, at: 0)
        if repositories.count > Self.maximumCount {
            repositories.removeLast(repositories.count - Self.maximumCount)
        }
        save()
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func remove(_ ids: Set<RecentRepository.ID>) {
        repositories.removeAll { ids.contains($0.id) }
        save()
    }

    func removeAll() {
        repositories.removeAll()
        save()
    }

    /// Resolves the bookmark, updating the stored path if the folder was moved or renamed.
    func resolvedURL(for repository: RecentRepository) -> URL {
        guard let bookmark = repository.bookmark else { return repository.url }

        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &isStale) else {
            return repository.url
        }

        let resolvedPath = resolved.standardizedFileURL.path
        if isStale || resolvedPath != repository.path,
           let index = repositories.firstIndex(where: { $0.id == repository.id }) {
            repositories[index].path = resolvedPath
            repositories[index].bookmark = try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            save()
        }
        return resolved
    }

    // MARK: - Persistence

    private struct Archive: Codable {
        var version = 1
        var repositories: [RecentRepository]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            repositories = try decoder.decode(Archive.self, from: data).repositories
        } catch {
            // A corrupt file should not prevent the app from launching; start fresh.
            repositories = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Archive(repositories: repositories)).write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Failed to save recent repositories: \(error)")
        }
    }
}
