import AppKit
import Foundation
import OSLog
import Observation

/// Manages AppleScript automation permissions for VibeTunnel.
///
/// This class checks and monitors automation permissions required for launching
/// terminal applications via AppleScript. It provides continuous monitoring
/// and user-friendly permission request flows.
@MainActor
@Observable
final class AppleScriptPermissionManager {
    static let shared = AppleScriptPermissionManager()

    private(set) var hasPermission = false
    private(set) var isChecking = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VibeTunnel",
        category: "AppleScriptPermissions"
    )

    private var monitoringTask: Task<Void, Never>?

    private init() {
        // Don't start monitoring automatically to avoid triggering permission dialog
        // Monitoring will start when user explicitly requests permission

        // Try to load cached permission status from UserDefaults
        hasPermission = UserDefaults.standard.bool(forKey: "cachedAppleScriptPermission")
    }

    deinit {
        // Task will be cancelled automatically when the object is deallocated
    }

    /// Checks if we have AppleScript automation permissions.
    /// Warning: This will trigger the permission dialog if not already granted.
    /// Use checkPermissionStatus() for a non-triggering check.
    func checkPermission() async -> Bool {
        isChecking = true
        defer { isChecking = false }

        let permitted = await AppleScriptExecutor.shared.checkPermission()
        hasPermission = permitted

        // Cache the result
        UserDefaults.standard.set(permitted, forKey: "cachedAppleScriptPermission")

        return permitted
    }

    /// Checks permission status without triggering the dialog.
    /// This returns the cached state which may not be 100% accurate if user changed
    /// permissions in System Preferences, but avoids triggering the dialog.
    func checkPermissionStatus() -> Bool {
        hasPermission
    }

    /// Performs a silent permission check that won't trigger the dialog.
    /// This uses a minimal AppleScript that shouldn't require automation permission.
    func silentPermissionCheck() async -> Bool {
        // Try a very simple AppleScript that doesn't target any application
        // If we have general AppleScript permission issues, this will fail
        let testScript = "return \"test\""

        do {
            _ = try await AppleScriptExecutor.shared.executeAsync(testScript, timeout: 1.0)
            // If this succeeds, we likely have some level of permission
            // Cache this positive result
            hasPermission = true
            UserDefaults.standard.set(true, forKey: "cachedAppleScriptPermission")
            return true
        } catch {
            // Can't determine for sure without potentially triggering dialog
            // Return cached value
            return hasPermission
        }
    }

    /// Requests AppleScript automation permissions by triggering the permission dialog.
    func requestPermission() {
        logger.info("Requesting AppleScript automation permissions")

        // Start monitoring when user explicitly requests permission
        if monitoringTask == nil {
            startMonitoring()
        }

        // First, execute an AppleScript to trigger the automation permission dialog
        // This ensures VibeTunnel appears in the Automation settings
        Task {
            let triggerScript = """
                tell application "Terminal"
                    -- This will trigger the automation permission dialog
                    exists
                end tell
            """

            do {
                // Use a longer timeout when triggering Terminal for the first time
                _ = try await AppleScriptExecutor.shared.executeAsync(triggerScript, timeout: 15.0)
            } catch {
                logger.info("Permission dialog triggered (expected error: \(error))")
            }

            // After a short delay, open System Settings to Privacy & Security > Automation
            // This gives the system time to register the permission request
            try? await Task.sleep(for: .milliseconds(500))

            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }

        // Continue monitoring more frequently after request
        startMonitoring(interval: 1.0)
    }

    /// Starts monitoring permission status continuously.
    private func startMonitoring(interval: TimeInterval = 2.0) {
        monitoringTask?.cancel()

        monitoringTask = Task {
            while !Task.isCancelled {
                _ = await checkPermission()

                // Wait before next check
                try? await Task.sleep(for: .seconds(interval))

                // If we have permission, reduce check frequency
                if hasPermission && interval < 10.0 {
                    startMonitoring(interval: 10.0)
                    break
                }
            }
        }
    }
}
