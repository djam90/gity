import Foundation

/// Finds git working trees on disk by walking directories.
public enum RepositoryScanner {
    public struct Root: Hashable, Sendable {
        public let url: URL
        public let maxDepth: Int

        public init(url: URL, maxDepth: Int) {
            self.url = url
            self.maxDepth = maxDepth
        }
    }

    /// Folders that are large, never contain repositories worth listing, or are slow to walk.
    public static let skippedDirectoryNames: Set<String> = [
        "node_modules", "Pods", "Carthage", "DerivedData", "build", "Build", "dist", "target",
        "vendor", "venv", "site-packages", "Library", "VirtualBox VMs", "Parallels", "Google Drive",
        "Dropbox", "OneDrive", "Applications",
    ]

    /// Home folders macOS guards with privacy prompts (or that are huge media libraries).
    /// Walking them would pop up "Gity would like to access…" dialogs out of nowhere.
    public static let protectedHomeFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public", "Applications",
    ]

    public static func isRepository(_ url: URL) -> Bool {
        // `.git` is a directory normally, and a file for worktrees and submodules.
        FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
    }

    /// Visible, non-symlinked home subfolders outside the privacy-protected ones.
    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser, maxDepth: Int = 4) -> [Root] {
        subdirectories(of: home)
            .filter { !protectedHomeFolders.contains($0.lastPathComponent) }
            .map { Root(url: $0, maxDepth: maxDepth) }
    }

    /// Walks `roots` breadth-limited by each root's depth. Does not descend into repositories.
    public static func scan(_ roots: [Root], isCancelled: @Sendable () -> Bool = { false }) -> [URL] {
        var found: [URL] = []
        var visited = Set<String>()

        func visit(_ url: URL, depth: Int, maxDepth: Int) {
            guard !isCancelled(), visited.insert(url.path).inserted else { return }
            if isRepository(url) {
                found.append(url.standardizedFileURL)
                return
            }
            guard depth < maxDepth else { return }
            for child in subdirectories(of: url) {
                visit(child, depth: depth + 1, maxDepth: maxDepth)
            }
        }

        for root in roots {
            visit(root.url, depth: 0, maxDepth: root.maxDepth)
        }
        return found
    }

    private static let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]

    private static func subdirectories(of url: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter { child in
            guard let values = try? child.resourceValues(forKeys: Set(resourceKeys)) else { return false }
            return values.isDirectory == true
                && values.isSymbolicLink != true
                && values.isPackage != true
                && !skippedDirectoryNames.contains(child.lastPathComponent)
        }
    }
}

/// Folder-name search through Spotlight, for repositories outside the scanned locations.
public enum SpotlightSearch {
    public static func folders(matching query: String, in scope: URL, limit: Int = 200) async throws -> [URL] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
        let predicate = "kMDItemContentType == \"public.folder\" && kMDItemFSName == \"*\(escaped)*\"cd"
        let runner = GitRunner(executableURL: URL(fileURLWithPath: "/usr/bin/mdfind"), workingDirectory: scope)
        let data = try await runner.run(["-0", "-onlyin", scope.path, predicate])
        return data.split(separator: 0)
            .prefix(limit)
            .map { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self), isDirectory: true) }
    }
}
