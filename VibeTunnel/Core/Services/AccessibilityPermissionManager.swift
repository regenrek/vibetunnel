import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Manages Accessibility permissions required for sending keystrokes.
///
/// This class provides methods to check and request accessibility permissions
/// required for simulating keyboard input via AppleScript/System Events.
final class AccessibilityPermissionManager {
    @MainActor static let shared = AccessibilityPermissionManager()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VibeTunnel",
        category: "AccessibilityPermissions"
    )

    private init() {}

    /// Checks if we have Accessibility permissions.
    func hasPermission() -> Bool {
        let permitted = AXIsProcessTrusted()
        logger.info("Accessibility permission status: \(permitted)")
        return permitted
    }

    /// Requests Accessibility permissions by triggering the system dialog.
    func requestPermission() {
        logger.info("Requesting Accessibility permissions")

        // Create options dictionary with the prompt key
        // Using hardcoded string to avoid concurrency issues with kAXTrustedCheckOptionPrompt
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        let alreadyTrusted = AXIsProcessTrustedWithOptions(options)

        if alreadyTrusted {
            logger.info("Accessibility permission already granted")
        } else {
            logger.info("Accessibility permission dialog triggered")
            // After a short delay, also open System Settings as a fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let url =
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
