import AppKit
import Foundation
import SwiftUI

/// Helper to open the Settings window programmatically when SettingsLink cannot be used
@MainActor
enum SettingsOpener {
    /// Opens the Settings window using the environment action via notification
    /// This is needed for cases where we can't use SettingsLink (e.g., from notifications)
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        
        // Post notification to trigger openSettings environment action
        NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
    }
    
    /// Opens the Settings window and navigates to a specific tab
    static func openSettingsTab(_ tab: SettingsTab) {
        openSettings()
        
        Task {
            // Small delay to ensure the settings window is fully initialized
            try? await Task.sleep(for: .milliseconds(100))
            NotificationCenter.default.post(
                name: .openSettingsTab,
                object: tab
            )
        }
    }
}

// MARK: - Hidden Window View

/// A hidden window view that enables Settings to work in MenuBarExtra-only apps
/// This is a workaround for FB10184971
struct HiddenWindowView: View {
    @Environment(\.openSettings) private var openSettings
    
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                // Configure the window to be invisible
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "HiddenWindow" }) {
                        // Position window offscreen
                        if let screen = NSScreen.main {
                            let screenFrame = screen.frame
                            window.setFrame(NSRect(x: screenFrame.midX, y: screenFrame.minY - 1000, width: 1, height: 1), display: false)
                        }
                        
                        window.backgroundColor = .clear
                        window.isOpaque = false
                        window.hasShadow = false
                        window.level = .submenu - 1
                        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenDisallowsTiling]
                        window.isExcludedFromWindowsMenu = true
                        window.ignoresMouseEvents = true
                        window.styleMask = [.borderless]
                        window.orderOut(nil)
                    }
                }
                
                // Listen for settings open requests
                NotificationCenter.default.addObserver(
                    forName: .openSettingsRequest,
                    object: nil,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        openSettings()
                    }
                }
            }
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let openSettingsRequest = Notification.Name("openSettingsRequest")
}