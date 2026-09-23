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

    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    init(url: URL, switchRepository: @escaping (URL) -> Void) {
        let model = RepositoryModel(url: url, gitExecutableURL: AppState.currentGitExecutableURL)
        model.switchRepository = switchRepository
        _model = State(initialValue: model)
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
                RepositorySwitcherButton(model: model)
            }
            ToolbarItem(placement: .navigation) {
                QuickOpenButton(repository: model)
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
        .sheet(item: $model.activeSheet) { sheet in
            RepositorySheetView(model: model, sheet: sheet)
        }
        .focusedSceneValue(\.repository, model)
        .task {
            dismissWindow(id: WindowID.welcome)
            await model.refresh()
            model.startWatching()
            model.startAutoFetch()
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

    @AppStorage(PreferenceKey.autostash) private var autostash = true
    @AppStorage(PreferenceKey.pullRebases) private var pullRebases = false

    private var hasRemotes: Bool { !(model.snapshot?.remotes.isEmpty ?? true) }
    private var hasBranch: Bool { model.currentBranch != nil }

    var body: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if let activity = model.activity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
            }
        }

        ToolbarItemGroup {
            Button {
                Task { await model.fetch() }
            } label: {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Fetch all remotes (⇧⌘F)")
            .disabled(model.isBusy || model.isFetching || !hasRemotes)

            Menu {
                Button("Pull (Merge)") { Task { await model.pull(rebase: false) } }
                Button("Pull (Rebase)") { Task { await model.pull(rebase: true) } }
                Divider()
                Toggle("Rebase by Default", isOn: $pullRebases)
                Toggle("Stash Local Changes Automatically", isOn: $autostash)
            } label: {
                Label("Pull", systemImage: "arrow.down")
            } primaryAction: {
                Task { await model.pull() }
            }
            .help(pullRebases ? "Pull with rebase (⇧⌘P)" : "Pull (⇧⌘P)")
            .disabled(model.isBusy || !hasBranch || !hasRemotes)

            Menu {
                Button("Push") { Task { await model.push() } }
                Button("Force Push…") { Task { await model.push(force: true) } }
            } label: {
                Label("Push", systemImage: "arrow.up")
            } primaryAction: {
                Task { await model.push() }
            }
            .help("Push the current branch (⇧⌘U)")
            .disabled(model.isBusy || !hasBranch || !hasRemotes)
        }

        ToolbarItemGroup {
            Button {
                model.activeSheet = .newBranch(startPoint: nil, startPointName: model.headDescription)
            } label: {
                Label("Branch", systemImage: "arrow.triangle.branch")
            }
            .help("Create a branch (⇧⌘N)")
            .disabled(model.isBusy || model.headReference == nil)

            Button {
                model.activeSheet = .stash
            } label: {
                Label("Stash", systemImage: "archivebox")
            }
            .help("Stash uncommitted changes (⌥⌘S)")
            .disabled(model.isBusy || (model.snapshot?.status.changes.isEmpty ?? true))
        }

        ToolbarItem {
            Menu {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                Divider()
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
        // A VStack rather than a safe area inset: split views ignore insets and would slide under the banner.
        VStack(spacing: 0) {
            PendingOperationBanner(model: model)
            content
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .workingCopy:
            WorkingCopyView(model: model)
        case .stash(let selector):
            StashDetailView(model: model, selector: selector)
                .id(selector)
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
