import AppKit
import Foundation

extension SettingsOpener {
    /// Opens settings with focus toggle workaround - most reliable method
    static func openSettingsWithFocusToggle() {
        // Store current activation policy
        let currentPolicy = NSApp.activationPolicy()
        
        // Switch to regular app mode
        NSApp.setActivationPolicy(.regular)
        
        // Try the direct menu item approach first
        let openedViaMenu = openSettingsViaMenuItem()
        
        if !openedViaMenu {
            // Fallback to notification approach
            NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
        }
        
        // Wait for window and apply focus toggle trick
        Task { @MainActor in
            // Give time for window creation
            try? await Task.sleep(for: .milliseconds(200))
            
            guard let settingsWindow = findSettingsWindow() else {
                NSApp.setActivationPolicy(currentPolicy)
                return
            }
            
            // Step 1: Initial window setup
            WindowCenteringHelper.centerOnActiveScreen(settingsWindow)
            settingsWindow.level = .floating
            settingsWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            
            // Step 2: Use NSRunningApplication for more reliable activation
            if #available(macOS 14.0, *) {
                NSRunningApplication.current.activate(options: .activateAllWindows)
            } else {
                NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
            }
            
            // Step 3: Make window key
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            
            // Step 4: Focus toggle trick - activate Dock then back to us
            if let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
                dockApp.activate(options: [])
                
                try? await Task.sleep(for: .milliseconds(100))
                
                // Activate our app again
                if #available(macOS 14.0, *) {
                    NSRunningApplication.current.activate(options: .activateAllWindows)
                } else {
                    NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
                }
                settingsWindow.makeKeyAndOrderFront(nil)
            }
            
            // Step 5: Reset window level after ensuring focus
            try? await Task.sleep(for: .milliseconds(200))
            settingsWindow.level = .normal
            settingsWindow.collectionBehavior = []
            
            // Set up close observer
            setupWindowCloseObserver(for: settingsWindow, initialPolicy: currentPolicy)
        }
    }
    
    private static func setupWindowCloseObserver(for window: NSWindow, initialPolicy: NSApplication.ActivationPolicy) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Check if this is the last window
                let visibleWindows = NSApp.windows.filter { $0.isVisible && $0 != window }
                if visibleWindows.isEmpty {
                    NSApp.setActivationPolicy(initialPolicy)
                }
            }
        }
    }
}