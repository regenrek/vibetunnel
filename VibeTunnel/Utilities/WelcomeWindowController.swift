import SwiftUI
import AppKit

/// Handles the presentation of the welcome screen window
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
        window.level = .floating
        
        super.init(window: window)
        
        // Listen for notification to show welcome screen
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowWelcomeNotification),
            name: .showWelcomeScreen,
            object: nil
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func show() {
        guard let window = window else { return }
        
        // Center window on the active screen (screen with mouse cursor)
        WindowCenteringHelper.centerOnActiveScreen(window)
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func handleShowWelcomeNotification() {
        show()
    }
}

// MARK: - Notification Extension
extension Notification.Name {
    static let showWelcomeScreen = Notification.Name("showWelcomeScreen")
}