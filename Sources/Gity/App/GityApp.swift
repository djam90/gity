import AppKit
import SwiftUI

@main
struct GityApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var appState: AppState { appDelegate.appState }

    var body: some Scene {
        // Listed first so it is the window shown at launch when nothing is restored.
        Window("Welcome to Gity", id: WindowID.welcome) {
            WelcomeView()
                .handlesExternalOpenRequests()
                .environment(appState)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .containerBackground(.background, for: .window)
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commands {
            AppCommands(appState: appState)
        }

        // One window per repository, keyed by its root URL so reopening focuses the existing window.
        // Windows are restored across launches automatically.
        WindowGroup("Repository", id: WindowID.repository, for: URL.self) { $url in
            if let url = Binding($url) {
                RepositoryWindow(url: url)
                    .handlesExternalOpenRequests()
                    .environment(appState)
            }
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when running the bare executable (e.g. `swift run`) rather than the .app bundle.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        #if DEBUG
        WindowSnapshotter.startIfRequested()
        #endif
    }

    /// Folders dropped on the Dock icon or passed via `open -a Gity <folder>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        appState.pendingOpenURLs += urls
    }
}

private struct ExternalOpenRequestHandler: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: appState.pendingOpenURLs, initial: true) { _, urls in
                guard !urls.isEmpty else { return }
                // Whichever window sees the request first consumes it.
                appState.pendingOpenURLs.removeAll()
                for url in urls {
                    Task { await appState.open(url, openWindow: openWindow) }
                }
            }
    }
}

extension View {
    /// Opens repositories requested from outside the app (Dock, Finder, `open`).
    func handlesExternalOpenRequests() -> some View {
        modifier(ExternalOpenRequestHandler())
    }
}
