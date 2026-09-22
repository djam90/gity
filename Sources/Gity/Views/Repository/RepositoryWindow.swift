import AppKit
import SwiftUI

/// A repository window. Its URL can change when the user switches repositories in place,
/// which rebuilds the content (and its model) for the new repository.
struct RepositoryWindow: View {
    @Binding var url: URL

    var body: some View {
        RepositoryWindowContent(url: url) { url = $0 }
            .id(url)
    }
}

private struct RepositoryWindowContent: View {
    @State private var model: RepositoryModel
    let switchRepository: (URL) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    init(url: URL, switchRepository: @escaping (URL) -> Void) {
        let git = AppState.currentGitExecutableURL
        _model = State(initialValue: RepositoryModel(url: url, gitExecutableURL: git))
        self.switchRepository = switchRepository
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
        } detail: {
            RepositoryDetailView(model: model)
        }
        // The switcher shows the repository name, so the title is left empty. An empty title (rather
        // than `.toolbar(removing: .title)`) keeps the flexible space that pushes actions trailing.
        .navigationTitle("")
        .background(WindowsMenuTitle(title: model.name))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                RepositorySwitcherButton(model: model, switchRepository: switchRepository)
            }
            RepositoryToolbar(model: model)
        }
        .overlay {
            if let error = model.loadError, model.snapshot == nil {
                ContentUnavailableView {
                    Label("Can’t Open Repository", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                }
                .background(.background)
            }
        }
        .alert(
            model.operationError?.title ?? "",
            isPresented: Binding(
                get: { model.operationError != nil },
                set: { if !$0 { model.operationError = nil } }
            ),
            presenting: model.operationError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        .focusedSceneValue(\.repository, model)
        .task {
            dismissWindow(id: WindowID.welcome)
            await model.refresh()
            model.startWatching()
        }
        .onAppear {
            appState.openRepositoryURLs.insert(model.url)
            // Windows restored at launch count as opened, so they appear in the switcher.
            appState.recents.noteOpened(model.url)
        }
        .onDisappear {
            appState.openRepositoryURLs.remove(model.url)
            model.stopWatching()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // FSEvents covers most changes, but a refresh on activation is a cheap safety net.
            Task { await model.refresh() }
        }
    }
}

private struct RepositoryToolbar: ToolbarContent {
    let model: RepositoryModel

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await model.fetch() }
            } label: {
                if model.isFetching {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Fetch", systemImage: "arrow.down.circle")
                }
            }
            .help("Fetch all remotes")
            .disabled(model.isFetching || (model.snapshot?.remotes.isEmpty ?? true))

            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh")
        }

        ToolbarItem {
            Menu {
                Button("Show in Finder", systemImage: "folder") { model.revealInFinder() }
                Button("Open in Terminal", systemImage: "terminal") { model.openInTerminal() }
            } label: {
                Label("Open In", systemImage: "arrow.up.forward.app")
            }
            .help("Open repository in another app")
        }
    }
}

private struct RepositoryDetailView: View {
    let model: RepositoryModel

    var body: some View {
        switch model.selection {
        case .workingCopy:
            WorkingCopyView(model: model)
        case .some(let item):
            CommitHistoryView(model: model, item: item)
                .id(item)
        case nil:
            ContentUnavailableView("No Selection", systemImage: "sidebar.left", description: Text("Select a branch in the sidebar."))
        }
    }
}

/// Names the window in the Window menu, independently of its (empty) title.
private struct WindowsMenuTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            NSApp.changeWindowsItem(window, title: title, filename: false)
        }
    }
}
