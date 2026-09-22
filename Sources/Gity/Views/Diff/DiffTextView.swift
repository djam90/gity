import GitKit
import SwiftUI

/// A diff flattened into rows once, so the view can lazily render them.
struct DiffDocument {
    enum Row: Identifiable {
        case hunkHeader(id: Int, text: String)
        case line(id: Int, DiffLine)

        var id: Int {
            switch self {
            case .hunkHeader(let id, _), .line(let id, _): id
            }
        }
    }

    let diff: FileDiff
    let rows: [Row]
    /// Width of the line number columns, in digits.
    let gutterDigits: Int

    init(diff: FileDiff) {
        self.diff = diff
        var rows: [Row] = []
        var maxNumber = 0
        for hunk in diff.hunks {
            rows.append(.hunkHeader(id: rows.count, text: hunk.header))
            for line in hunk.lines {
                rows.append(.line(id: rows.count, line))
                maxNumber = max(maxNumber, line.oldNumber ?? 0, line.newNumber ?? 0)
            }
        }
        self.rows = rows
        self.gutterDigits = max(3, String(maxNumber).count)
    }
}

/// Unified diff with old/new line number gutters. Lines do not wrap; the view scrolls horizontally.
struct DiffTextView: View {
    let document: DiffDocument

    @State private var viewportWidth: CGFloat = 0

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
            .textSelection(.enabled)
            .padding(.bottom, 8)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func rowView(_ row: DiffDocument.Row) -> some View {
        switch row {
        case .hunkHeader(_, let text):
            HStack(spacing: 0) {
                Color.clear.frame(width: gutterWidth * 2 + 18)
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }

        case .line(_, let line):
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
        guard line.text.count > Self.maxLineLength else { return line.text.isEmpty ? " " : line.text }
        return String(line.text.prefix(Self.maxLineLength)) + " …"
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
