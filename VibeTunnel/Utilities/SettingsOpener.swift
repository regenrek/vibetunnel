@preconcurrency import AppKit
import ApplicationServices
import Foundation
import SwiftUI

/// Helper to open the Settings window programmatically when SettingsLink cannot be used.
///
/// Provides workarounds for opening the Settings window in menu bar apps where
/// SwiftUI's SettingsLink may not function correctly. Uses multiple strategies
/// including menu item triggering and window manipulation to ensure reliable behavior.
@MainActor
enum SettingsOpener {
    /// SwiftUI's hardcoded settings window identifier
    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"
    private static var windowObserver: NSObjectProtocol?

    /// Opens the Settings window using the environment action via notification
    /// This is needed for cases where we can't use SettingsLink (e.g., from notifications)
    static func openSettings() {
        // Store the current dock visibility preference
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        
        // Temporarily show dock icon to ensure settings window can be brought to front
        if !showInDock {
            NSApp.setActivationPolicy(.regular)
        }
        
        // Simple activation and window opening
        Task { @MainActor in
            // Small delay to ensure dock icon is visible
            try? await Task.sleep(for: .milliseconds(50))
            
            // Activate the app
            NSApp.activate(ignoringOtherApps: true)
            
            // Try to open via menu item first
            if !openSettingsViaMenuItem() {
                // Fallback to notification
                NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
            }
            
            // Wait for window to appear and make it key
            try? await Task.sleep(for: .milliseconds(100))
            if let settingsWindow = findSettingsWindow() {
                settingsWindow.makeKeyAndOrderFront(nil)
            }
            
            // Set up observer to restore dock visibility when settings window closes
            if !showInDock {
                setupDockVisibilityRestoration()
            }
        }
    }
    
    /// Opens settings window using modal session for guaranteed focus
    static func openSettingsWithModal() {
        // Store current activation policy
        let currentPolicy = NSApp.activationPolicy()
        
        // Switch to regular app mode
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        // Try the direct menu item approach first
        let openedViaMenu = openSettingsViaMenuItem()
        
        if !openedViaMenu {
            // Fallback to notification approach
            NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
        }
        
        // Wait for window to appear and run modal session
        Task { @MainActor in
            // Give time for window creation
            try? await Task.sleep(for: .milliseconds(200))
            
            if let settingsWindow = findSettingsWindow() {
                // Configure window for modal presentation
                settingsWindow.center()
                settingsWindow.makeKeyAndOrderFront(nil)
                settingsWindow.level = .modalPanel
                settingsWindow.collectionBehavior = [.moveToActiveSpace, .canJoinAllSpaces]
                
                // Begin modal session
                let session = NSApp.beginModalSession(for: settingsWindow)
                
                // Create a class to hold the session reference safely
                final class SessionHolder: @unchecked Sendable {
                    let session: NSApplication.ModalSession
                    var isActive = true
                    
                    init(_ session: NSApplication.ModalSession) {
                        self.session = session
                    }
                }
                
                let sessionHolder = SessionHolder(session)
                
                // Set up observer to end modal when window closes
                let closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: settingsWindow,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        if sessionHolder.isActive {
                            sessionHolder.isActive = false
                            NSApp.endModalSession(sessionHolder.session)
                            settingsWindow.level = .normal
                            settingsWindow.collectionBehavior = []
                            
                            // Restore activation policy
                            NSApp.setActivationPolicy(currentPolicy)
                        }
                    }
                }
                
                // Run modal loop in background to not block
                Task { @MainActor in
                    // Small initial delay
                    try? await Task.sleep(for: .milliseconds(100))
                    
                    while settingsWindow.isVisible && sessionHolder.isActive {
                        // Run one iteration of the modal session
                        let result = NSApp.runModalSession(sessionHolder.session)
                        if result != .continue {
                            break
                        }
                        
                        // Small delay to prevent busy loop
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    
                    // Clean up when loop exits
                    if sessionHolder.isActive {
                        sessionHolder.isActive = false
                        NSApp.endModalSession(sessionHolder.session)
                        settingsWindow.level = .normal
                        settingsWindow.collectionBehavior = []
                    }
                    NotificationCenter.default.removeObserver(closeObserver)
                    
                    // Restore activation policy if window closed
                    if !settingsWindow.isVisible {
                        NSApp.setActivationPolicy(currentPolicy)
                    }
                }
                
                // Ensure window is properly focused after modal setup
                settingsWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                
            } else {
                // No window found, restore activation policy
                NSApp.setActivationPolicy(currentPolicy)
            }
        }
    }
    
    // MARK: - Dock Visibility Restoration
    
    private static func setupDockVisibilityRestoration() {
        // Remove any existing observer
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }
        
        // Set up observer for window closing
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak windowObserver] notification in
            guard let window = notification.object as? NSWindow else { return }
            
            Task { @MainActor in
                guard window.title.contains("Settings") || window.identifier?.rawValue.contains(settingsWindowIdentifier) == true else {
                    return
                }
                
                // Window is closing, restore dock visibility
                let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
                if !showInDock {
                    NSApp.setActivationPolicy(.accessory)
                }
                
                // Clean up observer
                if let observer = windowObserver {
                    NotificationCenter.default.removeObserver(observer)
                    Self.windowObserver = nil
                }
            }
        }
    }
    
    /// Finds the settings window using multiple detection methods
    static func findSettingsWindow() -> NSWindow? {
        // Try multiple methods to find the window
        return NSApp.windows.first { window in
            // Check by identifier
            if window.identifier?.rawValue == settingsWindowIdentifier {
                return true
            }
            
            // Check by title
            if window.isVisible && window.styleMask.contains(.titled) &&
               (window.title.localizedCaseInsensitiveContains("settings") ||
                window.title.localizedCaseInsensitiveContains("preferences")) {
                return true
            }
            
            // Check by content view controller type
            if let contentVC = window.contentViewController,
               String(describing: type(of: contentVC)).contains("Settings") {
                return true
            }
            
            return false
        }
    }

    /// Opens settings via the native menu item (more reliable)
    static func openSettingsViaMenuItem() -> Bool {
        let kAppMenuInternalIdentifier = "app"
        let kSettingsLocalizedStringKey = "Settings\\U2026"

        if let internalItemAction = NSApp.mainMenu?
            .item(withInternalIdentifier: kAppMenuInternalIdentifier)?
            .submenu?
            .item(withLocalizedTitle: kSettingsLocalizedStringKey)?
            .internalItemAction
        {
            internalItemAction()
            return true
        }
        return false
    }

    /// Focuses the settings window without level manipulation
    static func focusSettingsWindow() {
        // With dock icon visible, simple activation is enough
        NSApp.activate(ignoringOtherApps: true)
        if let settingsWindow = findSettingsWindow() {
            settingsWindow.makeKeyAndOrderFront(nil)
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
        window.level = .floating // Temporarily set to floating level

        // Reset level after a short delay
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            window.level = .normal
        }

        NSApp.activate(ignoringOtherApps: true)

        // Setup window close observer to restore activation policy
        setupWindowCloseObserver(for: window)
    }
    
    /// Simple AppleScript approach to activate the app
    /// Now that we show the dock icon, this is much simpler
    static func bringSettingsToFrontWithAppleScript() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "sh.vibetunnel.vibetunnel"
        
        let activateScript = """
        tell application "\(bundleIdentifier)"
            activate
        end tell
        """
        
        Task { @MainActor in
            do {
                _ = try await AppleScriptExecutor.shared.executeAsync(activateScript)
            } catch {
                print("AppleScript error activating app: \(error)")
            }
        }
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
        // First try to open via menu item
        let openedViaMenu = openSettingsViaMenuItem()
        
        if !openedViaMenu {
            // Fallback to notification approach
            NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
        }

        Task {
            // Small delay to ensure the settings window is fully initialized
            try? await Task.sleep(for: .milliseconds(300))
            
            // Use AppleScript to bring to front
            bringSettingsToFrontWithAppleScript()
            
            // Then switch to the specific tab
            NotificationCenter.default.post(
                name: .openSettingsTab,
                object: tab
            )
        }
    }
}

// MARK: - Hidden Window View

/// A hidden window view that enables Settings to work in MenuBarExtra-only apps.
///
/// This is a workaround for FB10184971 where SettingsLink doesn't function
/// properly in menu bar apps. Creates an invisible window that can receive
/// the openSettings environment action.
struct HiddenWindowView: View {
    @Environment(\.openSettings)
    private var openSettings

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
    
    /// Uses Accessibility API to force window to front
    /// This requires accessibility permissions but is very reliable
    static func bringSettingsToFrontWithAccessibility() {
        guard let settingsWindow = SettingsOpener.findSettingsWindow() else { return }
        
        // Use CGWindowListCopyWindowInfo to get window information
        let windowNumber = settingsWindow.windowNumber
        if let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]],
           let firstWindow = windowInfo.first,
           let pid = firstWindow[kCGWindowOwnerPID as String] as? Int32 {
            
            // Bring the owning process to front
            if let app = NSRunningApplication(processIdentifier: pid) {
                if #available(macOS 14.0, *) {
                    app.activate(options: [.activateAllWindows])
                } else {
                    app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
            }
        }
        
        // Also try manipulating window directly
        settingsWindow.collectionBehavior = [NSWindow.CollectionBehavior.moveToActiveSpace, NSWindow.CollectionBehavior.canJoinAllSpaces]
        settingsWindow.level = NSWindow.Level.popUpMenu
        settingsWindow.orderFrontRegardless()
        
        // Reset after a delay
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            settingsWindow.level = NSWindow.Level.normal
            settingsWindow.collectionBehavior = []
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
            withLabel: "id", in: self
        )?.value
        else {
            return nil
        }

        return "\(id)"
    }

    /// A callback which is associated directly with this `NSMenuItem`.
    fileprivate var internalItemAction: (() -> Void)? {
        guard let platformItemAction = Mirror.firstChild(
            withLabel: "platformItemAction", in: self
        )?.value,
            let typeErasedCallback = Mirror.firstChild(
                in: platformItemAction
            )?.value
        else {
            return nil
        }

        return Mirror.firstChild(
            in: typeErasedCallback
        )?.value as? () -> Void
    }
}

// MARK: - NSMenu Extensions (Private)

extension NSMenu {
    /// Get the first `NSMenuItem` whose internal identifier string matches the given value.
    fileprivate func item(withInternalIdentifier identifier: String) -> NSMenuItem? {
        items.first { $0.internalIdentifier?.elementsEqual(identifier) ?? false }
    }

    /// Get the first `NSMenuItem` whose title is equivalent to the localized string referenced
    /// by the given localized string key in the localization table identified by the given table name
    /// from the bundle located at the given bundle path.
    fileprivate func item(
        withLocalizedTitle localizedTitleKey: String,
        inTable tableName: String = "MenuCommands",
        fromBundle bundlePath: String = "/System/Library/Frameworks/AppKit.framework"
    )
        -> NSMenuItem?
    {
        guard let localizationResource = Bundle(path: bundlePath) else {
            return nil
        }

        return item(withTitle: NSLocalizedString(
            localizedTitleKey,
            tableName: tableName,
            bundle: localizationResource,
            comment: ""
        ))
    }
}

// MARK: - Mirror Extensions (Helper)

extension Mirror {
    /// The unconditional first child of the reflection subject.
    fileprivate var firstChild: Child? { children.first }

    /// The first child of the reflection subject whose label matches the given string.
    fileprivate func firstChild(withLabel label: String) -> Child? {
        children.first { $0.label?.elementsEqual(label) ?? false }
    }

    /// The unconditional first child of the given subject.
    fileprivate static func firstChild(in subject: Any) -> Child? {
        Mirror(reflecting: subject).firstChild
    }

    /// The first child of the given subject whose label matches the given string.
    fileprivate static func firstChild(
        withLabel label: String, in subject: Any
    )
        -> Child?
    {
        Mirror(reflecting: subject).firstChild(withLabel: label)
    }
}
