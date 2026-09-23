import GitKit
import SwiftUI

/// Commit message box under the working copy's file list, like Tower's: a summary line,
/// an optional description, an amend option and the commit button (⌘↩).
struct CommitComposer: View {
    let model: RepositoryModel

    @FocusState private var focusedField: Field?

    private enum Field {
        case summary
        case description
    }

    // MARK: - Message parts

    /// The first line of the message.
    private var summary: Binding<String> {
        Binding {
            String(model.commitMessage.prefix { $0 != "\n" })
        } set: { newValue in
            let summary = newValue.replacingOccurrences(of: "\n", with: " ")
            model.commitMessage = Self.join(summary, description.wrappedValue)
        }
    }

    /// Everything after the first line and the blank line that follows it.
    private var description: Binding<String> {
        Binding {
            let rest = model.commitMessage.drop { $0 != "\n" }
            return String(rest.drop { $0 == "\n" })
        } set: { newValue in
            model.commitMessage = Self.join(summary.wrappedValue, newValue)
        }
    }

    private static func join(_ summary: String, _ description: String) -> String {
        description.isEmpty ? summary : summary + "\n\n" + description
    }

    // MARK: - State

    private var operation: PendingOperation? { model.snapshot?.pendingOperation }
    private var isMerging: Bool { operation?.kind == .merge }
    private var hasConflicts: Bool { model.snapshot?.hasConflicts ?? false }
    private var isUnborn: Bool {
        if case .unborn = model.snapshot?.head { true } else { false }
    }

    private var commitTitle: String {
        if model.isAmending { return "Amend Commit" }
        if isMerging { return "Commit Merge" }
        let count = model.stagedChanges.count
        return count == 0 ? "Commit" : "Commit \(count) File\(count == 1 ? "" : "s")"
    }

    private var canCommit: Bool {
        !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isBusy
            && !hasConflicts
    }

    private var summaryLength: Int { summary.wrappedValue.count }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    TextField("Summary", text: summary)
                        .textFieldStyle(.plain)
                        .fontWeight(.medium)
                        .focused($focusedField, equals: .summary)
                        .onSubmit { focusedField = .description }
                    if summaryLength > 50 {
                        // Git tools truncate long summaries; 50 is the common guideline, 72 the limit.
                        Text("\(summaryLength)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(summaryLength > 72 ? .red : .orange)
                            .help("Summaries are best kept under 50 characters")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)

                Divider()

                TextEditor(text: description)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .description)
                    .frame(height: 64)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
                    .overlay(alignment: .topLeading) {
                        if description.wrappedValue.isEmpty {
                            Text("Description")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focusedField == nil ? AnyShapeStyle(.separator) : AnyShapeStyle(.tint.opacity(0.6)))
            }

            HStack {
                Toggle("Amend", isOn: Binding(
                    get: { model.isAmending },
                    set: { amending in Task { await model.setAmending(amending) } }
                ))
                .toggleStyle(.checkbox)
                .disabled(isUnborn || isMerging)
                .help("Add the staged changes to the last commit and edit its message")

                Spacer()

                Button(commitTitle) {
                    Task { await model.commit() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommit)
                .help(hasConflicts ? "Resolve conflicts before committing" : "Commit (⌘↩)")
            }
        }
        .padding(10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: operation, initial: true) {
            model.adoptPreparedMessage()
        }
    }
}
