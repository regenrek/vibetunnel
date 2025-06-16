import AppKit
import SwiftUI

/// Window controller for the About window
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    private init() {}

    func showWindow() {
        // Check if About window is already open
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create new About window
        let aboutView = AboutView()
        let hostingController = NSHostingController(rootView: aboutView)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.identifier = NSUserInterfaceItemIdentifier("AboutWindow")
        newWindow.title = "About VibeTunnel"
        newWindow.styleMask = [.titled, .closable, .miniaturizable]
        newWindow.setContentSize(NSSize(width: 570, height: 600))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false

        // Store reference to window
        self.window = newWindow

        // Show window
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
