import AppKit
import Foundation
import OSLog

/// Manages AppleScript automation permissions for VibeTunnel.
///
/// This class checks and monitors automation permissions required for launching
/// terminal applications via AppleScript. It provides continuous monitoring
/// and user-friendly permission request flows.
@MainActor
final class AppleScriptPermissionManager: ObservableObject {
    static let shared = AppleScriptPermissionManager()

    @Published private(set) var hasPermission = false
    @Published private(set) var isChecking = false

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VibeTunnel",
        category: "AppleScriptPermissions"
    )

    private var monitoringTask: Task<Void, Never>?

    private init() {
        // Start monitoring immediately
        startMonitoring()
    }

    deinit {
        monitoringTask?.cancel()
    }

    /// Checks if we have AppleScript automation permissions.
    func checkPermission() async -> Bool {
        isChecking = true
        defer { isChecking = false }

        let permitted = await AppleScriptExecutor.shared.checkPermission()
        hasPermission = permitted
        return permitted
    }

    /// Requests AppleScript automation permissions by triggering the permission dialog.
    func requestPermission() {
        logger.info("Requesting AppleScript automation permissions")

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
