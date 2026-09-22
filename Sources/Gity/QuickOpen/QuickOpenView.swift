import AppKit
import SwiftUI

/// Spotlight-style repository finder: recent repositories plus every repository on this Mac.
struct QuickOpenView: View {
    static let size = CGSize(width: 680, height: 440)

    @Bindable var model: QuickOpenModel
    let close: () -> Void

    @Environment(AppState.self) private var appState
    @FocusState private var isSearchFocused: Bool

    private var results: QuickOpenModel.Results {
        model.results(recents: appState.recents.repositories, discovered: appState.discovered.repositories)
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            searchField(results)
            Divider()
            resultList(results)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .onChange(of: model.presentationCount, initial: true) {
            isSearchFocused = true
        }
        .onChange(of: results.all.map(\.id)) { _, ids in
            if model.highlightedID.map({ !ids.contains($0) }) ?? true {
                model.highlightedID = ids.first
            }
        }
        .task(id: model.query) {
            // Debounce: Spotlight is only a fallback, no need to query on every keystroke.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.searchSpotlight(recents: appState.recents.repositories)
        }
    }

    // MARK: - Search field

    private func searchField(_ results: QuickOpenModel.Results) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Open Repository", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($isSearchFocused)
                .onKeyPress(.downArrow) { moveHighlight(by: 1, in: results.all); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1, in: results.all); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    guard let item = results.all.first(where: { $0.id == model.highlightedID }) ?? results.all.first else {
                        return .handled
                    }
                    if press.modifiers.contains(.command) {
                        reveal(item)
                    } else {
                        open(item, inNewWindow: press.modifiers.contains(.option))
                    }
                    return .handled
                }
            if appState.discovered.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .help("Looking for repositories on this Mac…")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
    }

    // MARK: - Results

    @ViewBuilder
    private func resultList(_ results: QuickOpenModel.Results) -> some View {
        if results.all.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "No recent repositories" : "No repositories match “\(model.query)”")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: .sectionHeaders) {
                        section("Recent", items: results.recent)
                        section("On This Mac", items: results.onThisMac)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .onChange(of: model.highlightedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [QuickOpenItem]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    QuickOpenRow(
                        item: item,
                        isHighlighted: item.id == model.highlightedID,
                        isOpen: appState.openRepositoryURLs.contains { $0.path == item.url.path }
                    )
                    .id(item.id)
                    .onHover { if $0 { model.highlightedID = item.id } }
                    .onTapGesture { open(item) }
                }
            } header: {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint(key: "↩", label: "Open")
            KeyHint(key: "⌥↩", label: "New Window")
            KeyHint(key: "⌘↩", label: "Show in Finder")
            KeyHint(key: "esc", label: "Close")
            Spacer()
            Text(indexDescription)
                .foregroundStyle(.secondary)
            Button("Rescan") {
                appState.discovered.rescan(recents: appState.recents.repositories)
            }
            .buttonStyle(.link)
            .disabled(appState.discovered.isScanning)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var indexDescription: String {
        let count = appState.discovered.repositories.count
        if appState.discovered.isScanning, count == 0 { return "Searching this Mac…" }
        return "\(count) repositor\(count == 1 ? "y" : "ies") on this Mac"
    }

    // MARK: - Actions

    private func moveHighlight(by offset: Int, in items: [QuickOpenItem]) {
        guard !items.isEmpty else { return }
        let index = model.highlightedID.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
        model.highlightedID = items[min(max(index + offset, 0), items.count - 1)].id
    }

    private func open(_ item: QuickOpenItem, inNewWindow: Bool = false) {
        close()
        guard let openWindow = model.openWindow else { return }
        let reference: AppState.RepositoryReference = item.recent.map { .recent($0) } ?? .url(item.url)
        let window = inNewWindow ? nil : model.targetRepository
        Task { await appState.open(reference, in: window, openWindow: openWindow) }
    }

    private func reveal(_ item: QuickOpenItem) {
        close()
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}

private struct QuickOpenRow: View {
    let item: QuickOpenItem
    let isHighlighted: Bool
    let isOpen: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlightedName)
                    .font(.system(size: 14))
                    .lineLimit(1)
                Text(item.displayPath)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isOpen {
                Text("Open")
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(isHighlighted ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
        }
        .contentShape(Rectangle())
    }

    /// The name with matched characters in bold (and tinted when not highlighted).
    private var highlightedName: AttributedString {
        let matched = Set(item.matchedIndices)
        var result = AttributedString()
        for (offset, character) in item.name.enumerated() {
            var run = AttributedString(String(character))
            if matched.contains(offset) {
                run.font = .system(size: 14, weight: .bold)
                if !isHighlighted {
                    run.foregroundColor = .accentColor
                }
            }
            result += run
        }
        return result
    }
}

private struct KeyHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced().weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

/// Toolbar button that opens Quick Open.
struct QuickOpenButton: View {
    let repository: RepositoryModel

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            appState.toggleQuickOpen(from: repository, openWindow: openWindow)
        } label: {
            Label("Quick Open", systemImage: "magnifyingglass")
        }
        .help("Quick Open (⇧⌘O)")
    }
}
