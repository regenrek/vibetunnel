import Foundation
import Observation

/// Monitors the HTTP server status and provides observable state for the UI
@MainActor
@Observable
public final class ServerMonitor {
    public static let shared = ServerMonitor()

    // Observable properties
    public private(set) var isRunning = false
    public private(set) var port: Int = 4_020
    public private(set) var lastError: Error?

    /// Reference to the actual server
    private weak var server: TunnelServer?

    private init() {}

    /// Updates the monitor with the current server instance
    public func setServer(_ server: TunnelServer?) {
        self.server = server
        updateStatus()
    }

    /// Updates the current status from the server
    public func updateStatus() {
        guard let server else {
            isRunning = false
            return
        }

        isRunning = server.isRunning
        port = server.port
        lastError = server.lastError
    }

    /// Starts the server if not already running
    public func startServer() async throws {
        guard let server else {
            throw ServerError.failedToStart("No server instance available")
        }

        try await server.start()
        updateStatus()
    }

    /// Stops the server if running
    public func stopServer() async throws {
        guard let server else { return }

        try await server.stop()
        updateStatus()
    }

    /// Checks if the server is healthy by making a health check request
    public func checkHealth() async -> Bool {
        guard isRunning else { return false }

        do {
            let url = URL(string: "http://127.0.0.1:\(port)/health")!
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
