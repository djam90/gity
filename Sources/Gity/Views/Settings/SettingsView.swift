import GitKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
        }
        .scenePadding()
        .frame(width: 500)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(PreferenceKey.gitExecutablePath) private var gitExecutablePath = ""
    @State private var gitVersion: String?

    var body: some View {
        Form {
            Section {
                TextField("Git executable", text: $gitExecutablePath, prompt: Text(detectedPath ?? "Not found"))
                    .textFieldStyle(.roundedBorder)
                LabeledContent("Using") {
                    Text(gitVersion ?? "Git not found")
                        .foregroundStyle(gitVersion == nil ? .red : .secondary)
                }
            } header: {
                Text("Git")
            } footer: {
                Text("Leave empty to use the first Git found in Homebrew or the Xcode Command Line Tools.")
                    .foregroundStyle(.secondary)
            }

            Section("Recent Repositories") {
                LabeledContent("\(appState.recents.repositories.count) of \(RecentRepositoriesStore.maximumCount) remembered") {
                    Button("Clear…", role: .destructive) {
                        appState.recents.removeAll()
                    }
                    .disabled(appState.recents.repositories.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: gitExecutablePath) {
            gitVersion = nil
            guard let git = GitExecutable.locate(preferredPath: gitExecutablePath) else { return }
            let version = try? await GitClient.version(executableURL: git)
            gitVersion = version.map { "\($0) at \(git.path)" }
        }
    }

    private var detectedPath: String? {
        GitExecutable.locate()?.path
    }
}
