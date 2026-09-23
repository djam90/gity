import GitKit
import SwiftUI

/// Presents whichever sheet the repository model asks for.
struct RepositorySheetView: View {
    let model: RepositoryModel
    let sheet: RepositorySheet

    var body: some View {
        switch sheet {
        case .newBranch(let startPoint, let startPointName):
            NewBranchSheet(model: model, startPoint: startPoint, startPointName: startPointName)
        case .renameBranch(let branch):
            RenameBranchSheet(model: model, branch: branch)
        case .newTag(let target, let targetName):
            NewTagSheet(model: model, target: target, targetName: targetName)
        case .push(let branch):
            PushSheet(model: model, branch: branch)
        case .stash:
            StashSheet(model: model)
        case .editMessage(let request):
            EditMessageSheet(request: request)
        case .interactiveRebase(let commit):
            InteractiveRebaseSheet(model: model, commit: commit)
        case .fileInspector(let request):
            FileInspectorView(model: model, request: request)
        }
    }
}

/// Title, content and Cancel / confirm buttons, in the standard macOS sheet layout.
struct SheetScaffold<Content: View>: View {
    let title: String
    var message: String?
    let confirmTitle: String
    var canConfirm = true
    var isDestructive = false
    var width: CGFloat = 440
    let confirm: () async -> Bool
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: isDestructive ? .destructive : nil) {
                    isWorking = true
                    Task {
                        if await confirm() { dismiss() }
                        isWorking = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm || isWorking)
            }
        }
        .padding(20)
        .frame(width: width)
    }
}

// MARK: - Branches

/// Checks a branch name with git as it's typed.
private struct BranchNameValidation: ViewModifier {
    let model: RepositoryModel
    let name: String
    var allowedExisting: String?
    @Binding var problem: String?

    func body(content: Content) -> some View {
        content.task(id: name) {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                problem = nil
                return
            }
            if trimmed != allowedExisting, model.snapshot?.localBranches.contains(where: { $0.name == trimmed }) == true {
                problem = "A branch named “\(trimmed)” already exists."
            } else if let git = model.git, await git.isValidBranchName(trimmed) == false {
                problem = "“\(trimmed)” isn’t a valid branch name."
            } else {
                problem = nil
            }
        }
    }
}

struct NewBranchSheet: View {
    let model: RepositoryModel
    let startPoint: String?
    let startPointName: String

    @State private var name = ""
    @State private var checkout = true
    @State private var problem: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SheetScaffold(
            title: "New Branch",
            message: "Starts at \(startPointName).",
            confirmTitle: "Create Branch",
            canConfirm: !trimmedName.isEmpty && problem == nil
        ) {
            await model.createBranch(trimmedName, at: startPoint, checkout: checkout)
        } content: {
            Form {
                TextField("Name", text: $name, prompt: Text("feature/new-idea"))
                if let problem {
                    Text(problem).foregroundStyle(.red).font(.callout)
                }
                Toggle("Check out the new branch", isOn: $checkout)
            }
            .modifier(BranchNameValidation(model: model, name: name, problem: $problem))
        }
    }
}

struct RenameBranchSheet: View {
    let model: RepositoryModel
    let branch: Branch

    @State private var name: String
    @State private var problem: String?

    init(model: RepositoryModel, branch: Branch) {
        self.model = model
        self.branch = branch
        _name = State(initialValue: branch.name)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SheetScaffold(
            title: "Rename Branch",
            message: branch.upstream.map { "The upstream branch \($0) keeps its name." },
            confirmTitle: "Rename",
            canConfirm: !trimmedName.isEmpty && trimmedName != branch.name && problem == nil
        ) {
            await model.renameBranch(branch, to: trimmedName)
        } content: {
            Form {
                TextField("Name", text: $name)
                if let problem {
                    Text(problem).foregroundStyle(.red).font(.callout)
                }
            }
            .modifier(BranchNameValidation(model: model, name: name, allowedExisting: branch.name, problem: $problem))
        }
    }
}

// MARK: - Tags

struct NewTagSheet: View {
    let model: RepositoryModel
    let target: String
    let targetName: String

    @State private var name = ""
    @State private var message = ""
    @State private var problem: String?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SheetScaffold(
            title: "New Tag",
            message: "Tags \(targetName). Add a message to create an annotated tag.",
            confirmTitle: "Create Tag",
            canConfirm: !trimmedName.isEmpty && problem == nil
        ) {
            await model.createTag(trimmedName, at: target, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        } content: {
            Form {
                TextField("Name", text: $name, prompt: Text("v1.0.0"))
                if let problem {
                    Text(problem).foregroundStyle(.red).font(.callout)
                }
                TextField("Message", text: $message, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(3...6)
            }
            .task(id: name) {
                if trimmedName.isEmpty {
                    problem = nil
                } else if model.snapshot?.tags.contains(where: { $0.name == trimmedName }) == true {
                    problem = "A tag named “\(trimmedName)” already exists."
                } else if let git = model.git, await git.isValidTagName(trimmedName) == false {
                    problem = "“\(trimmedName)” isn’t a valid tag name."
                } else {
                    problem = nil
                }
            }
        }
    }
}

// MARK: - Push

/// First push of a branch: pick the remote and the name there, and track it.
struct PushSheet: View {
    let model: RepositoryModel
    let branch: String

    @State private var remote: String
    @State private var remoteName: String
    @State private var track = true

    init(model: RepositoryModel, branch: String) {
        self.model = model
        self.branch = branch
        let remotes = model.snapshot?.remotes.map(\.name) ?? []
        _remote = State(initialValue: remotes.contains("origin") ? "origin" : remotes.first ?? "")
        _remoteName = State(initialValue: branch)
    }

    var body: some View {
        SheetScaffold(
            title: "Push “\(branch)”",
            message: "This branch hasn’t been pushed yet.",
            confirmTitle: "Push",
            canConfirm: !remote.isEmpty && !remoteName.trimmingCharacters(in: .whitespaces).isEmpty
        ) {
            await model.push(branch: branch, to: remote, as: remoteName.trimmingCharacters(in: .whitespaces), track: track)
        } content: {
            Form {
                Picker("Remote", selection: $remote) {
                    ForEach(model.snapshot?.remotes ?? []) { remote in
                        Text(remote.name).tag(remote.name)
                    }
                }
                TextField("Branch on remote", text: $remoteName)
                Toggle("Track this remote branch", isOn: $track)
                    .help("Pull and push will use it from now on")
            }
        }
    }
}

// MARK: - Stash

struct StashSheet: View {
    let model: RepositoryModel

    @State private var message = ""
    @AppStorage("stash.includeUntracked") private var includeUntracked = true

    var body: some View {
        SheetScaffold(
            title: "Stash Changes",
            message: "Saves your uncommitted changes and cleans the working copy. Apply the stash later from the sidebar.",
            confirmTitle: "Stash"
        ) {
            await model.stash(message: message.trimmingCharacters(in: .whitespaces), includeUntracked: includeUntracked)
        } content: {
            Form {
                TextField("Message", text: $message, prompt: Text("Optional"))
                Toggle("Include untracked files", isOn: $includeUntracked)
            }
        }
    }
}

// MARK: - Messages

struct EditMessageSheet: View {
    let request: MessageEditRequest

    @State private var message: String

    init(request: MessageEditRequest) {
        self.request = request
        _message = State(initialValue: request.message)
    }

    var body: some View {
        SheetScaffold(
            title: request.title,
            confirmTitle: request.confirmTitle,
            canConfirm: !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            width: 520
        ) {
            await request.save(message.trimmingCharacters(in: .whitespacesAndNewlines))
            return true
        } content: {
            TextEditor(text: $message)
                .font(.body.monospaced())
                .frame(height: 180)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
        }
    }
}
