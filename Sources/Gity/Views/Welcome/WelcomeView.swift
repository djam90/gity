import AppKit
import SwiftUI

/// Xcode-style launch window: actions on the left, recent repositories on the right.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            WelcomeHero(appState: appState, openWindow: openWindow)
                .frame(width: 460)
            RecentRepositoriesList(appState: appState, openWindow: openWindow)
                .frame(width: 300)
        }
        // Content sits below the hidden title bar; the recents background still extends up behind it.
        .frame(height: 430)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath }
            for url in folders {
                Task { await appState.open(url, openWindow: openWindow) }
            }
            return !folders.isEmpty
        } isTargeted: {
            isDropTargeted = $0
        }
    }
}

private struct WelcomeHero: View {
    let appState: AppState
    let openWindow: OpenWindowAction

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

            Text("Gity")
                .font(.system(size: 36, weight: .bold))
                .padding(.top, 6)

            Text("Version \(Bundle.main.shortVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Spacer(minLength: 28)

            VStack(spacing: 8) {
                WelcomeActionButton(
                    title: "Open Existing Repository…",
                    subtitle: "Browse for a local Git repository",
                    systemImage: "folder"
                ) {
                    appState.showOpenPanel(openWindow: openWindow)
                }
                WelcomeActionButton(
                    title: "Create New Repository…",
                    subtitle: "Initialize Git in a new or existing folder",
                    systemImage: "plus.square.on.square"
                ) {
                    appState.showCreatePanel(openWindow: openWindow)
                }
            }
            .padding(.horizontal, 56)

            Spacer(minLength: 20)

            Text("Tip: drop a folder on this window to open it.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct WelcomeActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .fontWeight(.semibold)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.08 : 0.04))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct RecentRepositoriesList: View {
    let appState: AppState
    let openWindow: OpenWindowAction

    @State private var selection = Set<RecentRepository.ID>()

    private var recents: RecentRepositoriesStore { appState.recents }

    var body: some View {
        List(selection: $selection) {
            ForEach(recents.repositories) { repository in
                RecentRepositoryRow(repository: repository)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial, ignoresSafeAreaEdges: .all)
        .contextMenu(forSelectionType: RecentRepository.ID.self) { ids in
            Button("Open") { open(ids) }
            Button("Show in Finder") {
                let urls = recents.repositories.filter { ids.contains($0.id) && $0.exists }.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Divider()
            Button("Remove from Recents") { recents.remove(ids) }
        } primaryAction: { ids in
            open(ids)
        }
        .onDeleteCommand {
            recents.remove(selection)
        }
        .overlay {
            if recents.repositories.isEmpty {
                ContentUnavailableView(
                    "No Recent Repositories",
                    systemImage: "clock",
                    description: Text("Repositories you open will appear here.")
                )
            }
        }
    }

    private func open(_ ids: Set<RecentRepository.ID>) {
        for repository in recents.repositories where ids.contains(repository.id) {
            Task { await appState.open(repository, openWindow: openWindow) }
        }
    }
}

private struct RecentRepositoryRow: View {
    let repository: RecentRepository

    var body: some View {
        let exists = repository.exists
        HStack(spacing: 10) {
            Image(nsImage: exists ? NSWorkspace.shared.icon(forFile: repository.path) : NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .frame(width: 32, height: 32)
                .opacity(exists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(repository.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !exists {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("This repository can’t be found")
            }
        }
        .padding(.vertical, 4)
        .help(repository.path)
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }
}
