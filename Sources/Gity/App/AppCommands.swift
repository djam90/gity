import AppKit
import SwiftUI

struct AppCommands: Commands {
    let appState: AppState

    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.repository) private var repository

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Repository…") {
                appState.showCreatePanel(openWindow: openWindow)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Open Repository…") {
                appState.showOpenPanel(openWindow: openWindow)
            }
            .keyboardShortcut("o")

            Menu("Open Recent") {
                ForEach(appState.recents.repositories) { recent in
                    Button(recent.name) {
                        Task { await appState.open(recent, openWindow: openWindow) }
                    }
                }
                Divider()
                Button("Clear Menu") {
                    appState.recents.removeAll()
                }
                .disabled(appState.recents.repositories.isEmpty)
            }
        }

        CommandMenu("Repository") {
            Group {
                Button("Switch Repository…") {
                    repository?.isShowingRepositorySwitcher = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Refresh") {
                    Task { await repository?.refresh() }
                }
                .keyboardShortcut("r")

                Button("Fetch All Remotes") {
                    Task { await repository?.fetch() }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(repository?.snapshot?.remotes.isEmpty ?? true)

                Divider()

                Button("Show in Finder") {
                    repository?.revealInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Open in Terminal") {
                    repository?.openInTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
            }
            .disabled(repository == nil)
        }

        CommandGroup(before: .windowList) {
            Button("Welcome to Gity") {
                openWindow(id: WindowID.welcome)
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])
            Divider()
        }
    }
}

struct RepositoryFocusedValueKey: FocusedValueKey {
    typealias Value = RepositoryModel
}

extension FocusedValues {
    var repository: RepositoryModel? {
        get { self[RepositoryFocusedValueKey.self] }
        set { self[RepositoryFocusedValueKey.self] = newValue }
    }
}
