import Foundation
import Observation
import OSLog
import SwiftUI

/// Manages the VibeTunnel server lifecycle.
///
/// `ServerManager` is the central coordinator for server lifecycle management in VibeTunnel.
/// It handles starting, stopping, and restarting the Go server, manages server configuration,
/// and provides logging capabilities.
@MainActor
@Observable
class ServerManager {
    @MainActor static let shared = ServerManager()

    var port: String {
        get { UserDefaults.standard.string(forKey: "serverPort") ?? "4020" }
        set { UserDefaults.standard.set(newValue, forKey: "serverPort") }
    }

    var bindAddress: String {
        get {
            let mode = DashboardAccessMode(rawValue: UserDefaults.standard.string(forKey: "dashboardAccessMode") ?? ""
            ) ??
                .localhost
            return mode.bindAddress
        }
        set {
            // Find the mode that matches this bind address
            if let mode = DashboardAccessMode.allCases.first(where: { $0.bindAddress == newValue }) {
                UserDefaults.standard.set(mode.rawValue, forKey: "dashboardAccessMode")
            }
        }
    }

    private var cleanupOnStartup: Bool {
        get { UserDefaults.standard.bool(forKey: "cleanupOnStartup") }
        set { UserDefaults.standard.set(newValue, forKey: "cleanupOnStartup") }
    }

    private(set) var currentServer: GoServer?
    private(set) var isRunning = false
    private(set) var isRestarting = false
    private(set) var lastError: Error?
    private(set) var crashCount = 0
    private(set) var lastCrashTime: Date?
    private var monitoringTask: Task<Void, Never>?
    private var crashRecoveryTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "sh.vibetunnel.vibetunnel", category: "ServerManager")
    private var logContinuation: AsyncStream<ServerLogEntry>.Continuation?
    private var serverLogTask: Task<Void, Never>?
    private(set) var logStream: AsyncStream<ServerLogEntry>!

    private init() {
        setupLogStream()

        // Skip observer setup and monitoring during tests
        let isRunningInTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
            ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil ||
            ProcessInfo.processInfo.arguments.contains("-XCTest") ||
            NSClassFromString("XCTestCase") != nil

        if !isRunningInTests {
            setupObservers()
            startCrashMonitoring()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Tasks will be cancelled when they are deallocated
    }

    private func setupLogStream() {
        logStream = AsyncStream { continuation in
            self.logContinuation = continuation
        }
    }

    private func setupObservers() {
        // Watch for server mode changes when the value actually changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc
    private nonisolated func userDefaultsDidChange() {
        // Server mode is now fixed to Go, no need to handle changes
    }

    /// Start the server with current configuration
    func start() async {
        // Check if we already have a running server
        if let existingServer = currentServer {
            logger.info("Server already running on port \(existingServer.port)")

            // Ensure our state is synced
            isRunning = true
            lastError = nil

            // Log for clarity
            logContinuation?.yield(ServerLogEntry(
                level: .info,
                message: "Server already running on port \(self.port)"
            ))
            return
        }

        // Check for port conflicts before starting
        if let conflict = await PortConflictResolver.shared.detectConflict(on: Int(self.port) ?? 4_020) {
            logger.warning("Port \(self.port) is in use by \(conflict.process.name) (PID: \(conflict.process.pid))")

            // Handle based on conflict type
            switch conflict.suggestedAction {
            case .killOurInstance(let pid, let processName):
                logger.info("Attempting to kill conflicting process: \(processName) (PID: \(pid))")
                logContinuation?.yield(ServerLogEntry(
                    level: .warning,
                    message: "Port \(self.port) is used by another instance. Terminating conflicting process..."
                ))

                do {
                    try await PortConflictResolver.shared.resolveConflict(conflict)
                    logContinuation?.yield(ServerLogEntry(
                        level: .info,
                        message: "Conflicting process terminated successfully"
                    ))

                    // Wait a moment for port to be fully released
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    logger.error("Failed to resolve port conflict: \(error)")
                    lastError = PortConflictError.failedToKillProcess(pid: pid)
                    logContinuation?.yield(ServerLogEntry(
                        level: .error,
                        message: "Failed to terminate conflicting process. Please try a different port."
                    ))
                    return
                }

            case .reportExternalApp(let appName):
                logger.error("Port \(self.port) is used by external app: \(appName)")
                lastError = PortConflictError.portInUseByApp(
                    appName: appName,
                    port: Int(self.port) ?? 4_020,
                    alternatives: conflict.alternativePorts
                )
                logContinuation?.yield(ServerLogEntry(
                    level: .error,
                    message: "Port \(self.port) is used by \(appName). Please choose a different port."
                ))
                return

            case .suggestAlternativePort:
                // This shouldn't happen in our case
                logger.warning("Port conflict requires alternative port")
            }
        }

        // Log that we're starting a server
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Starting server on port \(self.port)..."
        ))

        do {
            let server = GoServer()
            server.port = port

            // Subscribe to server logs
            serverLogTask = Task { [weak self] in
                for await entry in server.logStream {
                    self?.logContinuation?.yield(entry)
                }
            }

            try await server.start()

            currentServer = server
            isRunning = true
            lastError = nil

            logger.info("Started server on port \(self.port)")

            // Trigger cleanup of old sessions after server starts
            await triggerInitialCleanup()
        } catch {
            logger.error("Failed to start server: \(error.localizedDescription)")
            logContinuation?.yield(ServerLogEntry(
                level: .error,
                message: "Failed to start server: \(error.localizedDescription)"
            ))
            lastError = error

            // Check if server is actually running despite the error
            if let server = currentServer, server.isRunning {
                logger.warning("Server reported as running despite startup error, syncing state")
                isRunning = true
            } else {
                isRunning = false
            }
        }
    }

    /// Stop the current server
    func stop() async {
        guard let server = currentServer else {
            logger.warning("No server running")
            return
        }

        logger.info("Stopping server")

        // Log that we're stopping the server
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Stopping server..."
        ))

        await server.stop()
        serverLogTask?.cancel()
        serverLogTask = nil
        currentServer = nil
        isRunning = false

        // Log that the server has stopped
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Server stopped"
        ))
    }

    /// Restart the current server
    func restart() async {
        // Set restarting flag to prevent UI from showing "stopped" state
        isRestarting = true
        defer { isRestarting = false }

        // Log that we're restarting
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Restarting server..."
        ))

        await stop()
        await start()
    }


    /// Trigger cleanup of exited sessions after server startup
    private func triggerInitialCleanup() async {
        // Check if cleanup on startup is enabled
        guard cleanupOnStartup else {
            logger.info("Cleanup on startup is disabled in settings")
            return
        }

        logger.info("Triggering initial cleanup of exited sessions")

        // Small delay to ensure server is fully ready
        try? await Task.sleep(for: .milliseconds(500))

        do {
            // Create URL for cleanup endpoint
            guard let url = URL(string: "http://localhost:\(self.port)/api/cleanup-exited") else {
                logger.warning("Failed to create cleanup URL")
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10

            // Make the cleanup request
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    // Try to parse the response
                    if let jsonData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let cleanedCount = jsonData["cleaned_count"] as? Int
                    {
                        logger.info("Initial cleanup completed: cleaned \(cleanedCount) exited sessions")
                        logContinuation?.yield(ServerLogEntry(
                            level: .info,
                            message: "Cleaned up \(cleanedCount) exited sessions on startup"
                        ))
                    } else {
                        logger.info("Initial cleanup completed successfully")
                        logContinuation?.yield(ServerLogEntry(
                            level: .info,
                            message: "Cleaned up exited sessions on startup"
                        ))
                    }
                } else {
                    logger.warning("Initial cleanup returned status code: \(httpResponse.statusCode)")
                }
            }
        } catch {
            // Log the error but don't fail startup
            logger.warning("Failed to trigger initial cleanup: \(error.localizedDescription)")
            logContinuation?.yield(ServerLogEntry(
                level: .warning,
                message: "Could not clean up old sessions: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Crash Recovery

    /// Start monitoring for server crashes
    private func startCrashMonitoring() {
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                // Wait for 10 seconds between checks
                try? await Task.sleep(for: .seconds(10))

                guard let self else { return }

                // Only monitor if server should be running
                guard isRunning,
                      !isRestarting else { continue }

                // Check if server is responding
                let isHealthy = await checkServerHealth()

                if !isHealthy && currentServer != nil {
                    logger.warning("Server health check failed, may have crashed")
                    await handleServerCrash()
                }
            }
        }
    }

    /// Check if the server is healthy
    private func checkServerHealth() async -> Bool {
        guard let url = URL(string: "http://localhost:\(self.port)/api/health") else {
            return false
        }

        do {
            let request = URLRequest(url: url, timeoutInterval: 5.0)
            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Server not responding
        }

        return false
    }

    /// Handle server crash with exponential backoff
    private func handleServerCrash() async {
        // Update crash tracking
        let now = Date()
        if let lastCrash = lastCrashTime,
           now.timeIntervalSince(lastCrash) > 300
        { // Reset count if more than 5 minutes since last crash
            self.crashCount = 0
        }

        self.crashCount += 1
        lastCrashTime = now

        // Log the crash
        logger.error("Server crashed (crash #\(self.crashCount))")
        logContinuation?.yield(ServerLogEntry(
            level: .error,
            message: "Server crashed unexpectedly (crash #\(self.crashCount))"
        ))

        // Clear the current server reference
        currentServer = nil
        isRunning = false

        // Calculate backoff delay based on crash count
        let baseDelay: Double = 2.0 // 2 seconds base delay
        let maxDelay: Double = 60.0 // Max 1 minute delay
        let delay = min(baseDelay * pow(2.0, Double(self.crashCount - 1)), maxDelay)

        logger.info("Waiting \(delay) seconds before restart attempt...")
        logContinuation?.yield(ServerLogEntry(
            level: .info,
            message: "Waiting \(Int(delay)) seconds before restart attempt..."
        ))

        // Wait with exponential backoff
        try? await Task.sleep(for: .seconds(delay))

        // Attempt to restart
        if !Task.isCancelled {
            logger.info("Attempting to restart server after crash...")
            logContinuation?.yield(ServerLogEntry(
                level: .info,
                message: "Attempting automatic restart after crash..."
            ))

            await start()

            // If server started successfully, reset crash count after some time
            if isRunning {
                Task {
                    try? await Task.sleep(for: .seconds(300)) // 5 minutes
                    if self.isRunning {
                        self.crashCount = 0
                        self.logger.info("Server has been stable for 5 minutes, resetting crash count")
                    }
                }
            }
        }
    }

    /// Manually trigger a server restart (for UI button)
    func manualRestart() async {
        // Reset crash count for manual restarts
        self.crashCount = 0
        self.lastCrashTime = nil

        await restart()
    }

    /// Clear the authentication cache (e.g., when password is changed or cleared)
    func clearAuthCache() async {
        // Authentication cache clearing is no longer needed as external servers handle their own auth
        logger.info("Authentication cache clearing requested - handled by external server")
    }

}

// MARK: - Port Conflict Error Extension

extension PortConflictError {
    static func portInUseByApp(appName: String, port: Int, alternatives: [Int]) -> Error {
        NSError(
            domain: "sh.vibetunnel.vibetunnel.ServerManager",
            code: 1_001,
            userInfo: [
                NSLocalizedDescriptionKey: "Port \(port) is in use by \(appName)",
                NSLocalizedFailureReasonErrorKey: "The port is being used by another application",
                NSLocalizedRecoverySuggestionErrorKey: "Try one of these ports: \(alternatives.map(String.init).joined(separator: ", "))",
                "appName": appName,
                "port": port,
                "alternatives": alternatives
            ]
        )
    }
}
