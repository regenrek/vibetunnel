import Foundation
import AppKit
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
        
        logger.info("AppleScript permission status: \(permitted)")
        return permitted
    }
    
    /// Requests AppleScript automation permissions by opening System Settings.
    func requestPermission() {
        logger.info("Requesting AppleScript automation permissions")
        
        // Open System Settings to Privacy & Security > Automation
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
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