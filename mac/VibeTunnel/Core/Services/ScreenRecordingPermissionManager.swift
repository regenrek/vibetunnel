import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import OSLog

/// Manages Screen Recording permissions required for window enumeration.
///
/// This class provides methods to check and request screen recording permissions
/// required for using CGWindowListCopyWindowInfo to enumerate windows.
@MainActor
final class ScreenRecordingPermissionManager {
    static let shared = ScreenRecordingPermissionManager()
    
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VibeTunnel",
        category: "ScreenRecordingPermissions"
    )
    
    private init() {}
    
    /// Checks if we have Screen Recording permission.
    ///
    /// This uses CGWindowListCopyWindowInfo to detect if we can access window information.
    /// If the API returns nil or an empty list when we know windows exist, permission is likely denied.
    func hasPermission() -> Bool {
        // Try to get window information
        let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
        
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            // If we can get window info and the list is not suspiciously empty, we have permission
            // Note: An empty list could mean no windows are open, but that's unlikely
            return !windowList.isEmpty || checkIfNoWindowsOpen()
        }
        
        // If CGWindowListCopyWindowInfo returns nil, we definitely don't have permission
        return false
    }
    
    /// Checks if there are actually no windows open (rare but possible).
    private func checkIfNoWindowsOpen() -> Bool {
        // Check if any applications have windows
        let runningApps = NSWorkspace.shared.runningApplications
        
        for app in runningApps where app.activationPolicy == .regular {
            // If we find any regular app running, assume it has windows
            return false
        }
        
        // Truly no windows open
        return true
    }
    
    /// Requests Screen Recording permission by opening System Settings.
    ///
    /// Unlike Accessibility permission, Screen Recording cannot be triggered programmatically.
    /// We can only guide the user to the correct settings pane.
    func requestPermission() {
        logger.info("Requesting Screen Recording permission")
        
        // Open System Settings to Privacy & Security > Screen Recording
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
            logger.info("Opened System Settings for Screen Recording permission")
        } else {
            // Fallback to general privacy settings
            if let fallbackUrl = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                NSWorkspace.shared.open(fallbackUrl)
                logger.info("Opened System Settings to Privacy (fallback)")
            }
        }
    }
    
    /// Shows an alert explaining why Screen Recording permission is needed.
    func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
        VibeTunnel needs Screen Recording permission to track and focus terminal windows.
        
        This permission allows VibeTunnel to:
        • See which terminal windows are open
        • Focus the correct window when you select a session
        • Provide a better window management experience
        
        Please grant permission in System Settings > Privacy & Security > Screen Recording.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            requestPermission()
        }
    }
    
    /// Checks permission and shows alert if needed.
    /// Returns true if permission is granted, false otherwise.
    func ensurePermission() -> Bool {
        if hasPermission() {
            return true
        }
        
        logger.warning("Screen Recording permission not granted")
        
        // Show alert on main queue
        Task { @MainActor in
            showPermissionAlert()
        }
        
        return false
    }
    
    /// Monitors permission status and provides updates.
    ///
    /// This can be used to periodically check if the user has granted permission
    /// after being prompted.
    func startMonitoring(interval: TimeInterval = 2.0, callback: @escaping @Sendable (Bool) -> Void) {
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                let hasPermission = self.hasPermission()
                callback(hasPermission)
                
                if hasPermission {
                    self.logger.info("Screen Recording permission granted")
                }
            }
        }
    }
}

// MARK: - WindowTracker Extension
