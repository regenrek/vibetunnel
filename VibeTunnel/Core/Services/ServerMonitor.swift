import Foundation
import Observation

/// Monitors the HTTP server status and provides observable state for the UI
/// This class now acts as a facade over ServerManager for backward compatibility
@MainActor
@Observable
public final class ServerMonitor {
    public static let shared = ServerMonitor()

    // Observable properties
    public var isRunning: Bool {
        isServerRunning
    }
    
    public var port: Int {
        Int(ServerManager.shared.port) ?? 4020
    }
    
    public var lastError: Error? {
        ServerManager.shared.lastError
    }

    /// Reference to the actual server (kept for backward compatibility)
    private weak var server: TunnelServer?
    
    /// Internal state tracking
    @ObservationIgnored
    public var isServerRunning = false {
        didSet {
            // Notify observers when state changes
        }
    }

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
        isServerRunning = ServerManager.shared.isRunning
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
        await ServerManager.shared.restart()
        await syncWithServerManager()
    }

    /// Checks if the server is healthy by making a health check request
    public func checkHealth() async -> Bool {
        guard isRunning else { return false }

        do {
            let url = URL(string: "http://127.0.0.1:\(port)/api/health")!
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
