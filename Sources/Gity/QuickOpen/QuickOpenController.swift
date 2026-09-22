import AppKit
import SwiftUI

/// Owns the Quick Open panel. The panel is built once and reused, so showing it is instant.
final class QuickOpenController: NSObject, NSWindowDelegate {
    let model = QuickOpenModel()
    private var panel: QuickOpenPanel?

    /// Builds the panel ahead of time so the first ⇧⌘O doesn't pay for SwiftUI setup.
    func prepare(appState: AppState) {
        _ = panel(for: appState)
    }

    func show(appState: AppState, from repository: RepositoryModel?, openWindow: OpenWindowAction?) {
        let panel = panel(for: appState)
        model.openWindow = openWindow
        model.targetRepository = repository
        model.prepareForShowing()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        appState.discovered.scanIfNeeded(maxAge: 10 * 60, recents: appState.recents.repositories)
    }

    func toggle(appState: AppState, from repository: RepositoryModel?, openWindow: OpenWindowAction) {
        if panel?.isVisible == true {
            close()
        } else {
            show(appState: appState, from: repository, openWindow: openWindow)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func panel(for appState: AppState) -> QuickOpenPanel {
        if let panel { return panel }
        let panel = QuickOpenPanel(
            contentRect: NSRect(origin: .zero, size: QuickOpenView.size),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // No fade or zoom: Quick Open should be there the moment the shortcut is pressed.
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView:
            QuickOpenView(model: model, close: { [weak self] in self?.close() })
                .environment(appState)
        )
        self.panel = panel
        return panel
    }

    /// Centered over the active window (or screen), a fifth of the way down, like Spotlight.
    private func position(_ panel: NSPanel) {
        let reference = NSApp.keyWindow.flatMap { $0 == panel ? nil : $0.frame }
            ?? NSApp.mainWindow?.frame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let size = QuickOpenView.size
        let origin = NSPoint(
            x: reference.midX - size.width / 2,
            y: reference.maxY - reference.height * 0.2 - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

final class QuickOpenPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
