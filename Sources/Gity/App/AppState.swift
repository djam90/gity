import AppKit
import GitKit
import Observation
import SwiftUI

enum WindowID {
    static let welcome = "welcome"
    static let repository = "repository"
}

enum PreferenceKey {
    static let gitExecutablePath = "gitExecutablePath"
    /// Whether Pull rebases instead of merging.
    static let pullRebases = "pullRebases"
    /// Whether pull, merge and rebase stash local changes first and restore them afterwards.
    static let autostash = "autostash"
    /// Minutes between background fetches; 0 turns them off.
    static let autoFetchMinutes = "autoFetchMinutes"
}

/// App-wide state shared by every window: recent repositories and the open/create flows.
@Observable
final class AppState {
    let recents = RecentRepositoriesStore()
    let discovered = DiscoveredRepositoriesStore()
    @ObservationIgnored let quickOpen = QuickOpenController()

    /// Folders the system asked us to open, consumed by the first window that sees them.
    var pendingOpenURLs: [URL] = []

    /// Roots of repositories currently shown in a window, so switching to one focuses that window
    /// instead of showing the same repository twice.
    var openRepositoryURLs: Set<URL> = []

    /// The user's configured git, falling back to the first one installed.
    static var currentGitExecutableURL: URL? {
        GitExecutable.locate(preferredPath: UserDefaults.standard.string(forKey: PreferenceKey.gitExecutablePath))
    }

    // MARK: - Opening

    /// - Parameter repository: The window Quick Open was invoked from; picking a repository replaces it.
    func toggleQuickOpen(from repository: RepositoryModel?, openWindow: OpenWindowAction) {
        quickOpen.toggle(appState: self, from: repository, openWindow: openWindow)
    }

    enum RepositoryReference {
        case recent(RecentRepository)
        case url(URL)
    }

    /// Shows a repository in `window`, replacing what it shows. Falls back to opening a new window
    /// when there is no window to replace, and focuses the existing window if the repository is
    /// already open elsewhere so it never appears twice.
    func open(_ reference: RepositoryReference, in window: RepositoryModel?, openWindow: OpenWindowAction) async {
        let root: URL? = switch reference {
        case .recent(let recent): await resolve(recent)
        case .url(let url): await resolveRoot(containing: url)
        }
        guard let root else { return }
        recents.noteOpened(root)

        if window?.url.path == root.path { return }
        let isOpenElsewhere = openRepositoryURLs.contains { $0.path == root.path }
        if let window, let switchRepository = window.switchRepository, !isOpenElsewhere {
            switchRepository(root)
        } else {
            openWindow(id: WindowID.repository, value: root)
        }
    }

    func showOpenPanel(openWindow: OpenWindowAction) {
        let panel = NSOpenPanel()
        panel.title = "Open Repository"
        panel.message = "Choose a folder containing a Git repository."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            Task { await open(url, openWindow: openWindow) }
        }
    }

    /// Opens a recent repository in its own window (or focuses the window already showing it).
    func open(_ recent: RecentRepository, openWindow: OpenWindowAction) async {
        guard let root = await resolve(recent) else { return }
        show(root, openWindow: openWindow)
    }

    /// Validates that `url` is inside a git working tree, then opens (or focuses) a window for its root.
    @discardableResult
    func open(_ url: URL, openWindow: OpenWindowAction) async -> Bool {
        guard let root = await resolveRoot(containing: url) else { return false }
        show(root, openWindow: openWindow)
        return true
    }

    private func show(_ root: URL, openWindow: OpenWindowAction) {
        recents.noteOpened(root)
        // WindowGroup(for:) focuses the existing window if this root is already open.
        openWindow(id: WindowID.repository, value: root)
    }

    /// Working tree root for a recent entry, or nil after explaining the problem to the user.
    func resolve(_ recent: RecentRepository) async -> URL? {
        let url = recents.resolvedURL(for: recent)
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "“\(recent.name)” can’t be found"
            alert.informativeText = "The repository may have been moved or deleted. Do you want to remove it from the recent list?"
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                recents.remove([recent.id])
            }
            return nil
        }
        return await resolveRoot(containing: url)
    }

    /// Working tree root containing `url`, or nil after explaining the problem to the user.
    func resolveRoot(containing url: URL) async -> URL? {
        guard let git = requireGit() else { return nil }
        do {
            return try await GitClient.workingTreeRoot(containing: url, executableURL: git)
        } catch {
            presentError(
                title: "“\(url.lastPathComponent)” isn’t a Git repository",
                message: "Choose a folder that contains a Git repository, or create a new repository instead."
            )
            return nil
        }
    }

    // MARK: - Creating

    func showCreatePanel(openWindow: OpenWindowAction) {
        let panel = NSOpenPanel()
        panel.title = "Create Repository"
        panel.message = "Choose a folder to initialize as a new Git repository."
        panel.prompt = "Create"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url, let git = requireGit() else { return }

        Task {
            do {
                try await GitClient.initializeRepository(at: url, executableURL: git)
                await open(url, openWindow: openWindow)
            } catch {
                presentError(title: "Couldn’t create repository", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func requireGit() -> URL? {
        if let git = Self.currentGitExecutableURL { return git }
        presentError(
            title: "Git isn’t installed",
            message: "Install the Xcode Command Line Tools by running “xcode-select --install” in Terminal, or set a custom Git path in Settings."
        )
        return nil
    }

    func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
