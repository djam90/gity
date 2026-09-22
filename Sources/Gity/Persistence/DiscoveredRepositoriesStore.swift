import Foundation
import GitKit
import Observation

/// Repositories found by scanning the disk, cached in Application Support so Quick Open can
/// show them instantly. Rescanned in the background when the cache gets old.
@Observable
final class DiscoveredRepositoriesStore {
    private(set) var repositories: [URL] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    private let fileURL: URL
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(fileURL: URL = DiscoveredRepositoriesStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    static var defaultFileURL: URL {
        RecentRepositoriesStore.defaultFileURL
            .deletingLastPathComponent()
            .appending(path: "DiscoveredRepositories.json", directoryHint: .notDirectory)
    }

    /// Rescans unless the cache is younger than `maxAge`.
    func scanIfNeeded(maxAge: TimeInterval, recents: [RecentRepository]) {
        if let lastScan, Date.now.timeIntervalSince(lastScan) < maxAge { return }
        rescan(recents: recents)
    }

    func rescan(recents: [RecentRepository]) {
        guard !isScanning else { return }
        isScanning = true

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        // Also look around repositories the user has opened, even inside protected folders:
        // access there has already been granted, and related repos tend to sit side by side.
        let neighbours = Set(recents.map { $0.url.deletingLastPathComponent().standardizedFileURL })
            .filter { $0 != home && $0.path.hasPrefix(home.path) }
            .map { RepositoryScanner.Root(url: $0, maxDepth: 2) }
        let roots = RepositoryScanner.defaultRoots(home: home) + neighbours

        scanTask = Task.detached(priority: .utility) { [weak self] in
            let found = RepositoryScanner.scan(roots) { Task.isCancelled }
            await self?.finishScan(found)
        }
    }

    private func finishScan(_ found: [URL]) {
        repositories = found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        lastScan = .now
        isScanning = false
        save()
    }

    // MARK: - Persistence

    private struct Archive: Codable {
        var version = 1
        var lastScan: Date
        var paths: [String]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(Archive.self, from: data) else { return }
        lastScan = archive.lastScan
        repositories = archive.paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let archive = Archive(lastScan: lastScan ?? .now, paths: repositories.map(\.path))
            try encoder.encode(archive).write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Failed to save discovered repositories: \(error)")
        }
    }
}
