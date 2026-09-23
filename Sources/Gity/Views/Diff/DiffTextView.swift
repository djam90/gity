import AppKit
import GitKit
import SwiftUI

/// A diff flattened into rows once, so the view can lazily render them.
struct DiffDocument {
    enum Row: Identifiable {
        case hunkHeader(id: Int, text: String, hunk: Int)
        case line(id: Int, DiffLine, DiffLineID)

        var id: Int {
            switch self {
            case .hunkHeader(let id, _, _), .line(let id, _, _): id
            }
        }
    }

    /// Changes with every load, so views can reset state tied to the previous diff.
    let id = UUID()
    let diff: FileDiff
    let rows: [Row]
    /// Width of the line number columns, in digits.
    let gutterDigits: Int

    init(diff: FileDiff) {
        self.diff = diff
        var rows: [Row] = []
        var maxNumber = 0
        for (hunkIndex, hunk) in diff.hunks.enumerated() {
            rows.append(.hunkHeader(id: rows.count, text: hunk.header, hunk: hunkIndex))
            for (lineIndex, line) in hunk.lines.enumerated() {
                rows.append(.line(id: rows.count, line, DiffLineID(hunk: hunkIndex, line: lineIndex)))
                maxNumber = max(maxNumber, line.oldNumber ?? 0, line.newNumber ?? 0)
            }
        }
        self.rows = rows
        self.gutterDigits = max(3, String(maxNumber).count)
    }
}

/// What can be done with hunks and lines of a working copy diff.
struct DiffLineActions {
    enum Mode {
        /// Unstaged changes: stage or discard.
        case unstaged
        /// A new file: stage only (discarding it is done for the whole file).
        case untracked
        /// Staged changes: unstage.
        case staged
    }

    let mode: Mode
    /// Called with the chosen lines; `discard` is true for Discard, false for Stage/Unstage.
    let perform: (Set<DiffLineID>, _ discard: Bool) -> Void
}

/// Unified diff with old/new line number gutters. Lines do not wrap; the view scrolls horizontally.
/// With `lineActions`, hunks get Stage/Unstage/Discard buttons and clicking lines selects them
/// (Shift-click for a range) so just those lines can be staged, like Tower.
struct DiffTextView: View {
    let document: DiffDocument
    var lineActions: DiffLineActions?

    @State private var viewportWidth: CGFloat = 0
    @State private var selectedLines = Set<DiffLineID>()
    @State private var selectionAnchor: DiffLineID?

    private static let font = Font.system(size: 12, design: .monospaced)
    /// Very long lines (minified files) make text layout crawl; nobody reads past this anyway.
    private static let maxLineLength = 1_000

    private var gutterWidth: CGFloat { CGFloat(document.gutterDigits) * 7.5 + 12 }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(document.rows) { row in
                    rowView(row)
                        .frame(minWidth: viewportWidth, alignment: .leading)
                }
            }
            .font(Self.font)
            .modifier(TextSelectionIf(enabled: lineActions == nil))
            .padding(.bottom, 8)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: document.id) {
            selectedLines = []
            selectionAnchor = nil
        }
        .onKeyPress(.escape) {
            guard !selectedLines.isEmpty else { return .ignored }
            selectedLines = []
            return .handled
        }
    }

    @ViewBuilder
    private func rowView(_ row: DiffDocument.Row) -> some View {
        switch row {
        case .hunkHeader(_, let text, let hunk):
            HStack(spacing: 0) {
                if let lineActions {
                    hunkButtons(hunk: hunk, actions: lineActions)
                        .fixedSize()
                        .frame(minWidth: gutterWidth * 2 + 18, alignment: .leading)
                        .padding(.trailing, 10)
                } else {
                    Color.clear.frame(width: gutterWidth * 2 + 18)
                }
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }

        case .line(_, let line, let lineID):
            let isSelectable = lineActions != nil && (line.kind == .addition || line.kind == .deletion)
            let isSelected = selectedLines.contains(lineID)
            HStack(spacing: 0) {
                lineNumber(line.oldNumber)
                lineNumber(line.newNumber)
                Text(marker(for: line.kind))
                    .foregroundStyle(markerColor(for: line.kind))
                    .frame(width: 18)
                Text(displayText(for: line))
                    .foregroundStyle(line.kind == .noNewlineMarker ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .italic(line.kind == .noNewlineMarker)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 16)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
            .background(background(for: line.kind))
            .overlay {
                if isSelected {
                    Color.accentColor.opacity(0.22)
                        .overlay(alignment: .leading) { Color.accentColor.frame(width: 3) }
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isSelectable else { return }
                select(lineID)
            }
        }
    }

    // MARK: - Line staging

    @ViewBuilder
    private func hunkButtons(hunk: Int, actions: DiffLineActions) -> some View {
        let selectedInHunk = selectedLines.filter { $0.hunk == hunk }
        let lines = selectedInHunk.isEmpty ? PatchBuilder.changedLines(inHunk: hunk, of: document.diff) : selectedInHunk
        let noun = selectedInHunk.isEmpty ? "Hunk" : selectedInHunk.count == 1 ? "Line" : "Lines"
        HStack(spacing: 4) {
            switch actions.mode {
            case .unstaged, .untracked:
                Button("Stage \(noun)") { perform(actions, lines, discard: false) }
                if actions.mode == .unstaged {
                    Button("Discard \(noun)") { perform(actions, lines, discard: true) }
                }
            case .staged:
                Button("Unstage \(noun)") { perform(actions, lines, discard: false) }
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .buttonStyle(.bordered)
        .padding(.leading, 6)
    }

    private func perform(_ actions: DiffLineActions, _ lines: Set<DiffLineID>, discard: Bool) {
        actions.perform(lines, discard)
        selectedLines.subtract(lines)
    }

    /// Click toggles a line; Shift-click selects the changed lines between the last click and this one.
    private func select(_ lineID: DiffLineID) {
        if NSEvent.modifierFlags.contains(.shift), let anchor = selectionAnchor, anchor.hunk == lineID.hunk {
            let range = min(anchor.line, lineID.line)...max(anchor.line, lineID.line)
            let changed = PatchBuilder.changedLines(inHunk: lineID.hunk, of: document.diff)
            selectedLines.formUnion(changed.filter { range.contains($0.line) })
        } else if selectedLines.contains(lineID) {
            selectedLines.remove(lineID)
            selectionAnchor = lineID
        } else {
            selectedLines.insert(lineID)
            selectionAnchor = lineID
        }
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: gutterWidth, alignment: .trailing)
            .padding(.trailing, 0)
            .selectionDisabled()
    }

    private func displayText(for line: DiffLine) -> String {
        let text = line.text.replacingOccurrences(of: "\t", with: "    ")
        guard text.count > Self.maxLineLength else { return text.isEmpty ? " " : text }
        return String(text.prefix(Self.maxLineLength)) + " …"
    }

    private func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "−"
        case .context, .noNewlineMarker: ""
        }
    }

    private func markerColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: .green
        case .deletion: .red
        case .context, .noNewlineMarker: .secondary
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.13)
        case .deletion: .red.opacity(0.13)
        case .context, .noNewlineMarker: .clear
        }
    }
}

/// Text selection conflicts with clicking lines to select them for staging, so it's only on when read-only.
private struct TextSelectionIf: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}
