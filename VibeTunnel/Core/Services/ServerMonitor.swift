import Foundation
import Observation

/// Monitors the HTTP server status and provides observable state for the UI
/// This class now acts as a facade over ServerManager for backward compatibility
@MainActor
@Observable
public final class ServerMonitor {
    public static let shared = ServerMonitor()

    /// Observable properties
    public var isRunning: Bool {
        isServerRunning
    }

    public var port: Int {
        Int(ServerManager.shared.port) ?? 4_020
    }

    public var lastError: Error? {
        ServerManager.shared.lastError
    }

    /// Reference to the actual server (kept for backward compatibility)
    private weak var server: TunnelServer?

    /// Internal state tracking
    public var isServerRunning = false

    private init() {
        // Sync initial state with ServerManager
        Task {
            await syncWithServerManager()
        }
    }

    /// Updates the monitor with the current server instance (backward compatibility)
    public func setServer(_ server: TunnelServer?) {
        self.server = server
        updateStatus()
    }

    /// Updates the current status from the server
    public func updateStatus() {
        Task {
            await syncWithServerManager()
        }
    }

    /// Syncs state with ServerManager
    private func syncWithServerManager() async {
        // Consider the server as running if it's actually running OR if it's restarting
        // This prevents the UI from showing "stopped" during restart
        isServerRunning = ServerManager.shared.isRunning || ServerManager.shared.isRestarting
    }

    /// Starts the server if not already running
    public func startServer() async throws {
        // Delegate to ServerManager
        await ServerManager.shared.start()
        await syncWithServerManager()
    }

    /// Stops the server if running
    public func stopServer() async throws {
        // Delegate to ServerManager
        await ServerManager.shared.stop()
        await syncWithServerManager()
    }

    /// Restarts the server
    public func restartServer() async throws {
        // During restart, we maintain the running state to prevent UI flicker
        await ServerManager.shared.restart()
        // Sync after restart completes
        await syncWithServerManager()
    }

    /// Checks if the server is healthy by making a health check request
    public func checkHealth() async -> Bool {
        guard isRunning else { return false }

        do {
            guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else {
                return false
            }
            let request = URLRequest(url: url, timeoutInterval: 2.0)
            let (_, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Server not responding
        }
        return false
    }
}
