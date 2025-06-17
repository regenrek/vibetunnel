import AppKit
import SwiftUI

/// Handles the presentation of the welcome screen window.
///
/// Manages the lifecycle and presentation of the onboarding welcome window,
/// including window configuration, positioning, and notification-based showing.
/// Configured as a floating panel with transparent titlebar for modern appearance.
@MainActor
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private init() {
        let welcomeView = WelcomeView()
        let hostingController = NSHostingController(rootView: welcomeView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setFrameAutosaveName("WelcomeWindow")
        window.isReleasedWhenClosed = false
        // Use normal window level instead of floating
        window.level = .normal

        super.init(window: window)

        // Listen for notification to show welcome screen
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowWelcomeNotification),
            name: .showWelcomeScreen,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }

        // Center window on the active screen (screen with mouse cursor)
        WindowCenteringHelper.centerOnActiveScreen(window)

        window.makeKeyAndOrderFront(nil)
        // Use normal activation without forcing to front
        NSApp.activate(ignoringOtherApps: false)
    }

    @objc
    private func handleShowWelcomeNotification() {
        show()
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    static let showWelcomeScreen = Notification.Name("showWelcomeScreen")
}
