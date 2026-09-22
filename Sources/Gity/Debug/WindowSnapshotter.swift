#if DEBUG
import AppKit

/// Debug aid: when `GITY_SNAPSHOT_DIR` is set, periodically writes each visible window to a PNG.
/// Lets tooling inspect the UI without Screen Recording permission (apps may always draw their own views).
enum WindowSnapshotter {
    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["GITY_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible {
                    // The content view's superview is the frame view, which includes the toolbar.
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = window.title.isEmpty ? "window-\(window.windowNumber)" : window.title
                    let file = directory.appending(path: name.replacingOccurrences(of: "/", with: "-") + ".png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
            }
        }
    }
}
#endif
