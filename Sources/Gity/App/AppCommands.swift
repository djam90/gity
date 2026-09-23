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

            Button("Quick Open…") {
                appState.toggleQuickOpen(from: repository, openWindow: openWindow)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

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

        CommandGroup(replacing: .undoRedo) {
            Button(repository?.undoActionName.map { "Undo \($0)" } ?? "Undo") {
                performUndo(redo: false)
            }
            .keyboardShortcut("z")
            Button(repository?.redoActionName.map { "Redo \($0)" } ?? "Redo") {
                performUndo(redo: true)
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandMenu("Repository") {
            Group {
                Button("Switch Repository…") {
                    repository?.isShowingRepositorySwitcher = true
                }
                .keyboardShortcut("o", modifiers: [.command, .option])

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

                Button("Pull") {
                    Task { await repository?.pull() }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(repository?.currentBranch == nil)

                Button("Push") {
                    Task { await repository?.push() }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(repository?.currentBranch == nil)

                Divider()

                Button("New Branch…") {
                    guard let repository else { return }
                    repository.activeSheet = .newBranch(startPoint: nil, startPointName: repository.headDescription)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(repository?.headReference == nil)

                Button("Stash Changes…") {
                    repository?.activeSheet = .stash
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(repository?.snapshot?.status.changes.isEmpty ?? true)

                Divider()

                Button("Show Working Copy") { repository?.selection = .workingCopy }
                    .keyboardShortcut("1")
                Button("Show History") { repository?.selection = .history }
                    .keyboardShortcut("2")
                Button("Show Reflog") { repository?.selection = .reflog }
                    .keyboardShortcut("3")

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

extension AppCommands {
    /// Text being edited keeps its own undo; otherwise ⌘Z undoes the last git operation, like Tower.
    private func performUndo(redo: Bool) {
        let isEditingText = NSApp.keyWindow?.firstResponder is NSTextView
        let textUndo = NSApp.keyWindow?.firstResponder?.undoManager
        if let repository, !isEditingText || !(redo ? textUndo?.canRedo ?? false : textUndo?.canUndo ?? false) {
            if redo ? repository.redoActionName != nil : repository.undoActionName != nil {
                redo ? repository.redo() : repository.undo()
                return
            }
        }
        NSApp.sendAction(Selector(redo ? "redo:" : "undo:"), to: nil, from: nil)
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
