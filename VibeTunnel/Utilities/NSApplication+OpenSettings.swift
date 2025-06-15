import AppKit

extension NSApplication {
    /// Opens the Settings window programmatically.
    ///
    /// This extension provides a reliable way to open the Settings window on macOS.
    /// It uses internal AppKit APIs to trigger the Settings action, which is more
    /// reliable than attempting to find and show the window manually.
    func openSettings() {
        // Use the internal AppKit selector to show the Settings window
        // This is the same action that's triggered by Cmd+,
        if responds(to: Selector(("showSettingsWindow:"))) {
            performSelector(onMainThread: Selector(("showSettingsWindow:")), with: nil, waitUntilDone: false)
        }
    }
}
