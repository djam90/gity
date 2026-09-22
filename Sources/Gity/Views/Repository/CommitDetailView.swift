import AppKit
import GitKit
import SwiftUI

/// Message, metadata and changed files of a single commit.
struct CommitDetailView: View {
    let model: RepositoryModel
    let commit: Commit

    @State private var files: [CommitFileChange]?
    @State private var message: String?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            CommitInfoHeader(commit: commit, message: message, fileCount: files?.count)
            Divider()
            if let loadError {
                ContentUnavailableView("Couldn’t Load Commit", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxHeight: .infinity)
            } else if let files {
                if files.isEmpty {
                    ContentUnavailableView("No Changed Files", systemImage: "doc", description: Text("This commit doesn’t change any files."))
                        .frame(maxHeight: .infinity)
                } else {
                    ChangesBrowser(model: model, sections: [
                        FileSection(
                            id: "files",
                            title: "Changed Files",
                            targets: files.map { DiffTarget(source: .commit(commit, $0)) }
                        ),
                    ])
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            async let files = model.changedFiles(in: commit)
            async let message = model.message(of: commit)
            do {
                self.files = try await files
                self.message = try await message
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}

private struct CommitInfoHeader: View {
    let commit: Commit
    let message: String?
    let fileCount: Int?

    /// The message without its first line, which is already shown as the title.
    private var body_: String {
        guard let message else { return "" }
        return message
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AuthorAvatar(name: commit.authorName, email: commit.authorEmail)

            VStack(alignment: .leading, spacing: 4) {
                Text(commit.subject)
                    .font(.headline)
                    .textSelection(.enabled)

                if !body_.isEmpty {
                    ScrollView {
                        Text(body_)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 80)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Text(commit.authorName)
                        .help(commit.authorEmail)
                    Text("·")
                    Text(commit.authorDate.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commit.sha, forType: .string)
                    } label: {
                        Label(commit.shortSHA, systemImage: "doc.on.doc")
                            .font(.caption.monospaced())
                    }
                    .buttonStyle(.link)
                    .help("Copy full SHA")
                    if commit.parents.count > 1 {
                        Text("·")
                        Text("Merge, compared with first parent \(commit.parents[0].prefix(7))")
                    }
                    if let fileCount {
                        Text("·")
                        Text("\(fileCount) file\(fileCount == 1 ? "" : "s") changed")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Initials on a color derived from the email, so each author gets a stable color.
struct AuthorAvatar: View {
    let name: String
    let email: String

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var color: Color {
        // djb2: `hashValue` is randomized per launch, which would change colors every run.
        let hash = email.lowercased().utf8.reduce(UInt64(5381)) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
        return Self.palette[Int(hash % UInt64(Self.palette.count))]
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(color.gradient, in: Circle())
            .help("\(name) <\(email)>")
    }
}
