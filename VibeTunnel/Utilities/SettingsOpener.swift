import AppKit
import Foundation
import SwiftUI

/// Helper to open the Settings window programmatically when SettingsLink cannot be used
@MainActor
enum SettingsOpener {
    /// SwiftUI's hardcoded settings window identifier
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"
    
    /// Opens the Settings window using the environment action via notification
    /// This is needed for cases where we can't use SettingsLink (e.g., from notifications)
    static func openSettings() {
        // Temporarily switch to regular app to ensure window comes to front
        let currentPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Try the direct menu item approach first (from VibeMeter)
        if openSettingsViaMenuItem() {
            // Successfully opened via menu item
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                focusSettingsWindow()
                
                // Restore activation policy after a delay
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.setActivationPolicy(currentPolicy)
            }
        } else {
            // Fallback to notification approach
            NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
            
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                focusSettingsWindow()
                
                // Restore activation policy after a delay
                try? await Task.sleep(for: .milliseconds(200))
                NSApp.setActivationPolicy(currentPolicy)
            }
        }
    }
    
    /// Opens settings via the native menu item (more reliable)
    private static func openSettingsViaMenuItem() -> Bool {
        let kAppMenuInternalIdentifier = "app"
        let kSettingsLocalizedStringKey = "Settings\\U2026"
        
        if let internalItemAction = NSApp.mainMenu?.item(
            withInternalIdentifier: kAppMenuInternalIdentifier)?.submenu?.item(
            withLocalizedTitle: kSettingsLocalizedStringKey)?.internalItemAction {
            internalItemAction()
            return true
        }
        return false
    }
    
    /// Focuses the settings window without level manipulation
    static func focusSettingsWindow() {
        // First try the SwiftUI settings window identifier
        if let settingsWindow = NSApp.windows.first(where: { 
            $0.identifier?.rawValue == settingsWindowIdentifier 
        }) {
            bringWindowToFront(settingsWindow)
        } else if let settingsWindow = NSApp.windows.first(where: { window in
            // Fallback to title-based search
            window.isVisible && 
            window.styleMask.contains(.titled) && 
            (window.title.localizedCaseInsensitiveContains("settings") ||
             window.title.localizedCaseInsensitiveContains("preferences"))
        }) {
            bringWindowToFront(settingsWindow)
        }
    }
    
    /// Brings a window to front using the most reliable method
    private static func bringWindowToFront(_ window: NSWindow) {
        // Ensure window is on screen
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        
        // Center window on the active screen
        WindowCenteringHelper.centerOnActiveScreen(window)
        
        // Multiple methods to ensure window comes to front
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.level = .floating  // Temporarily set to floating level
        
        // Reset level after a short delay
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            window.level = .normal
        }
        
        NSApp.activate(ignoringOtherApps: true)
        
        // Setup window close observer to restore activation policy
        setupWindowCloseObserver(for: window)
    }
    
    /// Observes when settings window closes to restore activation policy
    private static func setupWindowCloseObserver(for window: NSWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                // Check if this is the last window
                let visibleWindows = NSApp.windows.filter { $0.isVisible && $0 != window }
                if visibleWindows.isEmpty {
                    // Restore menu bar app behavior
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
    
    /// Opens the Settings window and navigates to a specific tab
    static func openSettingsTab(_ tab: SettingsTab) {
        openSettings()
        
        Task {
            // Small delay to ensure the settings window is fully initialized
            try? await Task.sleep(for: .milliseconds(150))
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
                        WindowCenteringHelper.positionOffScreen(window)
                        
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
                        
                        // Additional check to bring settings to front after environment action
                        try? await Task.sleep(for: .milliseconds(150))
                        SettingsOpener.focusSettingsWindow()
                    }
                }
            }
    }
}

// MARK: - Notification Extensions

extension Notification.Name {
    static let openSettingsRequest = Notification.Name("openSettingsRequest")
}

// MARK: - NSMenuItem Extensions (Private)

extension NSMenuItem {
    /// An internal SwiftUI menu item identifier that should be a public property on `NSMenuItem`.
    fileprivate var internalIdentifier: String? {
        guard let id = Mirror.firstChild(
            withLabel: "id", in: self)?.value
        else {
            return nil
        }
        
        return "\(id)"
    }
    
    /// A callback which is associated directly with this `NSMenuItem`.
    fileprivate var internalItemAction: (() -> Void)? {
        guard
            let platformItemAction = Mirror.firstChild(
                withLabel: "platformItemAction", in: self)?.value,
            let typeErasedCallback = Mirror.firstChild(
                in: platformItemAction)?.value
        else {
            return nil
        }
        
        return Mirror.firstChild(
            in: typeErasedCallback)?.value as? () -> Void
    }
}

// MARK: - NSMenu Extensions (Private)

extension NSMenu {
    /// Get the first `NSMenuItem` whose internal identifier string matches the given value.
    fileprivate func item(withInternalIdentifier identifier: String) -> NSMenuItem? {
        items.first(where: {
            $0.internalIdentifier?.elementsEqual(identifier) ?? false
        })
    }
    
    /// Get the first `NSMenuItem` whose title is equivalent to the localized string referenced
    /// by the given localized string key in the localization table identified by the given table name
    /// from the bundle located at the given bundle path.
    fileprivate func item(
        withLocalizedTitle localizedTitleKey: String,
        inTable tableName: String = "MenuCommands",
        fromBundle bundlePath: String = "/System/Library/Frameworks/AppKit.framework") -> NSMenuItem? {
        guard let localizationResource = Bundle(path: bundlePath) else {
            return nil
        }
        
        return item(withTitle: NSLocalizedString(
            localizedTitleKey,
            tableName: tableName,
            bundle: localizationResource,
            comment: ""))
    }
}

// MARK: - Mirror Extensions (Helper)

private extension Mirror {
    /// The unconditional first child of the reflection subject.
    var firstChild: Child? { children.first }
    
    /// The first child of the reflection subject whose label matches the given string.
    func firstChild(withLabel label: String) -> Child? {
        children.first(where: {
            $0.label?.elementsEqual(label) ?? false
        })
    }
    
    /// The unconditional first child of the given subject.
    static func firstChild(in subject: Any) -> Child? {
        Mirror(reflecting: subject).firstChild
    }
    
    /// The first child of the given subject whose label matches the given string.
    static func firstChild(
        withLabel label: String, in subject: Any) -> Child? {
        Mirror(reflecting: subject).firstChild(withLabel: label)
    }
}