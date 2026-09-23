import AppKit

/// Native confirmation alerts, shown as a sheet on the key window.
enum Confirmation {
    struct Result {
        let confirmed: Bool
        /// State of the optional checkbox.
        let isChecked: Bool
    }

    /// - Parameters:
    ///   - checkbox: Adds a checkbox under the message (e.g. "Also delete the remote branch").
    @discardableResult
    static func ask(
        _ title: String,
        message: String,
        confirmTitle: String,
        isDestructive: Bool = false,
        checkbox: String? = nil,
        isCheckedByDefault: Bool = false
    ) async -> Result {
        #if DEBUG
        // Lets debug scripts run destructive steps without clicking through alerts.
        if ProcessInfo.processInfo.environment["GITY_DEBUG_AUTOCONFIRM"] != nil {
            return Result(confirmed: true, isChecked: isCheckedByDefault)
        }
        #endif
        let alert = NSAlert()
        alert.alertStyle = isDestructive ? .critical : .informational
        alert.messageText = title
        alert.informativeText = message
        let confirmButton = alert.addButton(withTitle: confirmTitle)
        confirmButton.hasDestructiveAction = isDestructive
        alert.addButton(withTitle: "Cancel")
        if let checkbox {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = checkbox
            alert.suppressionButton?.state = isCheckedByDefault ? .on : .off
        }

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return Result(
            confirmed: response == .alertFirstButtonReturn,
            isChecked: alert.suppressionButton?.state == .on
        )
    }
}

/// Adds patterns to the repository's top-level `.gitignore`.
enum GitIgnore {
    /// Pattern matching exactly `path` (relative to the repository root).
    static func pattern(forPath path: String, isDirectory: Bool = false) -> String {
        "/" + escaped(path) + (isDirectory ? "/" : "")
    }

    /// Pattern matching every file with `path`'s extension, anywhere.
    static func pattern(forExtensionOf path: String) -> String? {
        let pathExtension = (path as NSString).pathExtension
        return pathExtension.isEmpty ? nil : "*." + escaped(pathExtension)
    }

    static func append(_ pattern: String, inRepositoryAt root: URL) throws {
        let file = root.appending(path: ".gitignore")
        var contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let existing = Set(contents.split(whereSeparator: \.isNewline).map(String.init))
        guard !existing.contains(pattern) else { return }
        if !contents.isEmpty, !contents.hasSuffix("\n") { contents += "\n" }
        contents += pattern + "\n"
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Escapes characters gitignore treats as wildcards or comments.
    private static func escaped(_ path: String) -> String {
        var result = ""
        for character in path {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        if result.hasPrefix("#") || result.hasPrefix("!") { result = "\\" + result }
        if result.hasSuffix(" ") { result = String(result.dropLast()) + "\\ " }
        return result
    }
}
