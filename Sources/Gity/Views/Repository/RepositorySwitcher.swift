import AppKit
import SwiftUI

/// Toolbar button showing the current repository and branch; opens the repository switcher.
struct RepositorySwitcherButton: View {
    @Bindable var model: RepositoryModel

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            model.isShowingRepositorySwitcher.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.url.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(model.headDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch repository (⌥⌘O)")
        .background {
            FastPopover(isPresented: $model.isShowingRepositorySwitcher) {
                RepositorySwitcher(
                    repository: model,
                    openWindow: openWindow,
                    close: { model.isShowingRepositorySwitcher = false }
                )
                .environment(appState)
            }
        }
    }
}

/// Searchable list of recent repositories, navigable with the keyboard.
private struct RepositorySwitcher: View {
    let repository: RepositoryModel
    /// Passed in because this view is hosted in its own AppKit popover.
    let openWindow: OpenWindowAction
    let close: () -> Void

    private var currentURL: URL { repository.url }

    @Environment(AppState.self) private var appState

    @State private var query = ""
    @State private var highlightedID: RecentRepository.ID?
    @FocusState private var isSearchFocused: Bool

    private var matches: [RecentRepository] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let all = appState.recents.repositories
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.displayPath.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear {
            isSearchFocused = true
            highlightedID = matches.first?.id
        }
        .onChange(of: query) {
            highlightedID = matches.first?.id
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search Repositories", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit { activate(highlightedID) }
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
        }
        .font(.title3)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var results: some View {
        let matches = matches
        if matches.isEmpty {
            Text(appState.recents.repositories.isEmpty ? "No Recent Repositories" : "No Matches")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches) { repository in
                            row(for: repository)
                                .id(repository.id)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: highlightedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(for repository: RecentRepository) -> some View {
        let isCurrent = repository.path == currentURL.path
        let isHighlighted = repository.id == highlightedID
        let isOpenElsewhere = !isCurrent && appState.openRepositoryURLs.contains { $0.path == repository.path }

        return HStack(spacing: 10) {
            Image(nsImage: repository.exists ? NSWorkspace.shared.icon(forFile: repository.path) : NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .frame(width: 28, height: 28)
                .opacity(repository.exists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(repository.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(repository.displayPath)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if isCurrent {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
            } else if isOpenElsewhere {
                Text("Open")
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .help("Already open in another window")
            } else if !repository.exists {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("This repository can’t be found")
            }
        }
        .foregroundStyle(isHighlighted ? .white : .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
        .onHover { if $0 { highlightedID = repository.id } }
        .onTapGesture { activate(repository.id) }
        .contextMenu {
            Button("Open in New Window") {
                close()
                Task { await appState.open(repository, openWindow: openWindow) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repository.url])
            }
            .disabled(!repository.exists)
            Divider()
            Button("Remove from Recents") {
                appState.recents.remove([repository.id])
            }
            .disabled(isCurrent)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                close()
                appState.showOpenPanel(openWindow: openWindow)
            } label: {
                Label("Open Repository…", systemImage: "folder")
            }
            Spacer()
            Button {
                close()
                openWindow(id: WindowID.welcome)
            } label: {
                Label("Welcome Window", systemImage: "square.grid.2x2")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func moveHighlight(by offset: Int) {
        let ids = matches.map(\.id)
        guard !ids.isEmpty else { return }
        let index = highlightedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        highlightedID = ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// Switches this window to the repository, or focuses the window already showing it.
    private func activate(_ id: RecentRepository.ID?) {
        guard let recent = appState.recents.repositories.first(where: { $0.id == id }) else { return }
        close()
        Task { await appState.open(.recent(recent), in: repository, openWindow: openWindow) }
    }
}

/// An `NSPopover` that appears with a short fade instead of the standard, slower popover animation.
private struct FastPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ anchor: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = { isPresented = false }

        if isPresented, !coordinator.popover.isShown {
            // Clicking the anchor button while open closes the transient popover on mouse down,
            // then the button toggles it back on. Treat that as a close.
            if Date.now.timeIntervalSince(coordinator.lastClosed) < 0.3 {
                DispatchQueue.main.async { isPresented = false }
                return
            }
            let host = NSHostingController(rootView: content())
            host.sizingOptions = .preferredContentSize
            coordinator.popover.contentViewController = host
            // Present on the next runloop turn so the anchor has its final frame.
            DispatchQueue.main.async {
                guard anchor.window != nil else { return }
                coordinator.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                guard let window = host.view.window else { return }
                window.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    window.animator().alphaValue = 1
                }
            }
        } else if !isPresented, coordinator.popover.isShown {
            coordinator.popover.close()
        }
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        let popover = NSPopover()
        var onClose: (() -> Void)?
        var lastClosed = Date.distantPast

        override init() {
            super.init()
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self
        }

        func popoverDidClose(_ notification: Notification) {
            lastClosed = .now
            onClose?()
        }
    }
}
