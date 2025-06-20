import Foundation
import Testing
@testable import VibeTunnel

// MARK: - Server Manager Tests

@Suite("Server Manager Tests")
@MainActor
struct ServerManagerTests {
    // We'll use the shared ServerManager instance since it's a singleton

    // MARK: - Server Lifecycle Tests

    @Test("Starting and stopping Go server", .tags(.critical))
    func serverLifecycle() async throws {
        let manager = ServerManager.shared

        // Ensure clean state
        await manager.stop()

        // Start the server
        await manager.start()

        // Give server time to start
        try await Task.sleep(for: .milliseconds(500))

        // Check server is running
        #expect(manager.isRunning)
        #expect(manager.currentServer != nil)

        // Stop the server
        await manager.stop()

        // Give server time to stop
        try await Task.sleep(for: .milliseconds(500))

        // Check server is stopped
        #expect(!manager.isRunning)
        #expect(manager.currentServer == nil)
    }

    @Test("Starting server when already running does not create duplicate", .tags(.critical))
    func startingAlreadyRunningServer() async throws {
        let manager = ServerManager.shared

        // Ensure clean state
        await manager.stop()

        // Start the server
        await manager.start()
        try await Task.sleep(for: .milliseconds(500))

        let firstServer = manager.currentServer
        #expect(firstServer != nil)

        // Try to start again
        await manager.start()

        // Should still be the same server instance
        #expect(manager.currentServer === firstServer)
        #expect(manager.isRunning)

        // Cleanup
        await manager.stop()
    }

    @Test("Port configuration")
    func portConfiguration() async throws {
        let manager = ServerManager.shared

        // Store original port
        let originalPort = manager.port

        // Test setting different ports
        let testPorts = ["8080", "3000", "9999"]

        for port in testPorts {
            manager.port = port
            #expect(manager.port == port)
            #expect(UserDefaults.standard.string(forKey: "serverPort") == port)
        }

        // Restore original port
        manager.port = originalPort
    }

    @Test("Bind address configuration", arguments: [
        DashboardAccessMode.localhost,
        DashboardAccessMode.network
    ])
    func bindAddressConfiguration(mode: DashboardAccessMode) async throws {
        let manager = ServerManager.shared

        // Store original mode
        let originalMode = UserDefaults.standard.string(forKey: "dashboardAccessMode") ?? ""

        // Set the mode via UserDefaults (as bindAddress setter does)
        UserDefaults.standard.set(mode.rawValue, forKey: "dashboardAccessMode")

        // Check bind address reflects the mode
        #expect(manager.bindAddress == mode.bindAddress)

        // Restore original mode
        UserDefaults.standard.set(originalMode, forKey: "dashboardAccessMode")
    }

    // MARK: - Concurrent Operations Tests

    @Test("Concurrent server operations are serialized", .tags(.concurrency))
    func concurrentServerOperations() async throws {
        let manager = ServerManager.shared

        // Ensure clean state
        await manager.stop()

        // Start multiple operations concurrently
        await withTaskGroup(of: Void.self) { group in
            // Start server
            group.addTask {
                await manager.start()
            }

            // Try to stop immediately
            group.addTask {
                try? await Task.sleep(for: .milliseconds(50))
                await manager.stop()
            }

            // Try to restart
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                await manager.restart()
            }

            await group.waitForAll()
        }

        // Server should be in a consistent state
        let finalState = manager.isRunning
        if finalState {
            #expect(manager.currentServer != nil)
        } else {
            #expect(manager.currentServer == nil)
        }

        // Cleanup
        await manager.stop()
    }

    @Test("Server restart maintains configuration", .tags(.critical))
    func serverRestart() async throws {
        let manager = ServerManager.shared

        // Ensure clean state
        await manager.stop()

        // Set specific configuration
        let testPort = "4567"
        manager.port = testPort

        // Start server
        await manager.start()
        try await Task.sleep(for: .milliseconds(500))

        // Verify running
        #expect(manager.isRunning)
        let serverBeforeRestart = manager.currentServer

        // Restart
        await manager.restart()
        try await Task.sleep(for: .milliseconds(500))

        // Verify still running with same port
        #expect(manager.isRunning)
        #expect(manager.port == testPort)
        #expect(manager.currentServer !== serverBeforeRestart) // Should be new instance

        // Cleanup
        await manager.stop()
    }

    // MARK: - Error Handling Tests

    @Test("Server state remains consistent after operations", .tags(.reliability))
    func serverStateConsistency() async throws {
        let manager = ServerManager.shared

        // Ensure clean state
        await manager.stop()

        // Perform various operations
        await manager.start()
        try await Task.sleep(for: .milliseconds(200))

        await manager.stop()
        try await Task.sleep(for: .milliseconds(200))

        await manager.start()
        try await Task.sleep(for: .milliseconds(200))

        // State should be consistent
        if manager.isRunning {
            #expect(manager.currentServer != nil)
        } else {
            #expect(manager.currentServer == nil)
        }

        // Cleanup
        await manager.stop()
    }

    // MARK: - Log Stream Tests

    @Test("Server logs are captured in log stream")
    func serverLogStream() async throws {
        let manager = ServerManager.shared

        // Ensure clean state
        await manager.stop()

        // Collect logs during server operations
        var collectedLogs: [ServerLogEntry] = []
        let logTask = Task {
            for await log in manager.logStream {
                collectedLogs.append(log)
                if collectedLogs.count >= 2 {
                    break
                }
            }
        }

        // Start server to generate logs
        await manager.start()

        // Wait for logs
        try await Task.sleep(for: .seconds(1))
        logTask.cancel()

        // Verify logs were captured
        #expect(!collectedLogs.isEmpty)
        #expect(collectedLogs.contains { log in
            log.message.lowercased().contains("start") ||
                log.message.lowercased().contains("server") ||
                log.message.lowercased().contains("listening")
        })

        // Cleanup
        await manager.stop()
    }

    // MARK: - Crash Recovery Tests

    @Test("Crash count tracking")
    func crashCountTracking() async throws {
        let manager = ServerManager.shared

        // Ensure clean state
        await manager.stop()

        // Initial crash count should be 0
        #expect(manager.crashCount == 0)

        // Note: We can't easily simulate crashes in tests without
        // modifying the production code to support dependency injection
        // This test mainly verifies the property exists and is readable
    }
}
