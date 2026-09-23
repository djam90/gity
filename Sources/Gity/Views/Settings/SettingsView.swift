import GitKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Workflow", systemImage: "arrow.triangle.branch") {
                WorkflowSettingsView()
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

private struct WorkflowSettingsView: View {
    @AppStorage(PreferenceKey.pullRebases) private var pullRebases = false
    @AppStorage(PreferenceKey.autostash) private var autostash = true
    @AppStorage(PreferenceKey.autoFetchMinutes) private var autoFetchMinutes = 10

    var body: some View {
        Form {
            Section {
                Picker("Pull", selection: $pullRebases) {
                    Text("Merge").tag(false)
                    Text("Rebase").tag(true)
                }
                .pickerStyle(.radioGroup)
                Toggle("Stash local changes automatically", isOn: $autostash)
            } header: {
                Text("Pull, Merge and Rebase")
            } footer: {
                Text("Rebasing keeps history linear by replaying your commits on top of the remote ones. With automatic stashing, uncommitted changes are set aside first and restored afterwards.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Fetch in the background", selection: $autoFetchMinutes) {
                    Text("Never").tag(0)
                    Text("Every 5 Minutes").tag(5)
                    Text("Every 10 Minutes").tag(10)
                    Text("Every 30 Minutes").tag(30)
                    Text("Every Hour").tag(60)
                }
            } header: {
                Text("Remotes")
            } footer: {
                Text("Keeps ahead and behind counts up to date. Open repositories are fetched shortly after opening and then on this schedule.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
