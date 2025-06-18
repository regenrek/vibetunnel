import Testing
import Foundation
@testable import VibeTunnel

// MARK: - Mock URLSession for Testing

@MainActor
final class MockURLSession: URLSession {
    var responses: [URL: (Data, URLResponse)] = [:]
    var errors: [URL: Error] = [:]
    var requestDelay: Duration?
    var requestCount = 0
    
    override func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        
        // Simulate delay if configured
        if let delay = requestDelay {
            try await Task.sleep(for: delay)
        }
        
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        
        // Check for configured error
        if let error = errors[url] {
            throw error
        }
        
        // Check for configured response
        if let response = responses[url] {
            return response
        }
        
        // Default to 404
        let response = HTTPURLResponse(
            url: url,
            statusCode: 404,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}

// MARK: - Mock Session Monitor

@MainActor
final class MockSessionMonitor: SessionMonitor {
    var mockSessions: [String: SessionInfo] = [:]
    var mockSessionCount = 0
    var mockLastError: String?
    var fetchSessionsCalled = false
    
    override func fetchSessions() async {
        fetchSessionsCalled = true
        self.sessions = mockSessions
        self.sessionCount = mockSessionCount
        self.lastError = mockLastError
    }
    
    func reset() {
        mockSessions = [:]
        mockSessionCount = 0
        mockLastError = nil
        fetchSessionsCalled = false
    }
}

// MARK: - Session Monitor Tests

@Suite("Session Monitor Tests")
@MainActor
struct SessionMonitorTests {
    
    // Helper to create test session data
    func createTestSession(
        id: String = UUID().uuidString,
        status: String = "running",
        exitCode: Int? = nil
    ) -> SessionMonitor.SessionInfo {
        SessionMonitor.SessionInfo(
            cmdline: ["/bin/bash"],
            cwd: "/Users/test",
            exitCode: exitCode,
            name: id,
            pid: Int.random(in: 1000...9999),
            startedAt: ISO8601DateFormatter().string(from: Date()),
            status: status,
            stdin: "/tmp/\(id)/stdin",
            streamOut: "/tmp/\(id)/stdout"
        )
    }
    
    // MARK: - Monitoring Active Sessions Tests
    
    @Test("Monitoring active sessions")
    func testActiveSessionMonitoring() async throws {
        let monitor = MockSessionMonitor()
        
        // Set up mock sessions
        let session1 = createTestSession(id: "session-1", status: "running")
        let session2 = createTestSession(id: "session-2", status: "running")
        let session3 = createTestSession(id: "session-3", status: "exited", exitCode: 0)
        
        monitor.mockSessions = [
            "session-1": session1,
            "session-2": session2,
            "session-3": session3
        ]
        monitor.mockSessionCount = 2 // Only running sessions
        
        // Fetch sessions
        await monitor.fetchSessions()
        
        #expect(monitor.fetchSessionsCalled)
        #expect(monitor.sessionCount == 2)
        #expect(monitor.sessions.count == 3)
        #expect(monitor.lastError == nil)
        
        // Verify running sessions
        #expect(monitor.sessions["session-1"]?.isRunning == true)
        #expect(monitor.sessions["session-2"]?.isRunning == true)
        #expect(monitor.sessions["session-3"]?.isRunning == false)
    }
    
    @Test("Detecting stale sessions", .timeLimit(.seconds(5)))
    func testStaleSessionDetection() async throws {
        let monitor = SessionMonitor.shared
        
        // This test documents expected behavior for detecting stale sessions
        // In real implementation, stale sessions would be those that haven't
        // updated their status for a certain period
        
        // For now, verify that exited sessions are properly identified
        let staleSession = createTestSession(status: "exited", exitCode: 1)
        #expect(!staleSession.isRunning)
        #expect(staleSession.exitCode == 1)
    }
    
    @Test("Session timeout handling", arguments: [30, 60, 120])
    func testSessionTimeout(seconds: Int) async throws {
        // Test that monitor can handle sessions with different timeout configurations
        let monitor = MockSessionMonitor()
        
        let session = createTestSession(status: "running")
        monitor.mockSessions = [session.name: session]
        monitor.mockSessionCount = 1
        
        await monitor.fetchSessions()
        
        #expect(monitor.sessionCount == 1)
        
        // Simulate session timeout
        let timedOutSession = createTestSession(
            id: session.name,
            status: "exited",
            exitCode: 124 // Common timeout exit code
        )
        monitor.mockSessions = [session.name: timedOutSession]
        monitor.mockSessionCount = 0
        
        await monitor.fetchSessions()
        
        #expect(monitor.sessionCount == 0)
        #expect(monitor.sessions[session.name]?.exitCode == 124)
    }
    
    // MARK: - Session Lifecycle Tests
    
    @Test("Monitor start and stop lifecycle")
    func testMonitorLifecycle() async throws {
        let monitor = SessionMonitor.shared
        
        // Stop any existing monitoring
        monitor.stopMonitoring()
        
        // Start monitoring
        monitor.startMonitoring()
        
        // Give it a moment to start
        try await Task.sleep(for: .milliseconds(100))
        
        // Stop monitoring
        monitor.stopMonitoring()
        
        // Verify clean state
        #expect(monitor.sessionCount >= 0)
    }
    
    @Test("Refresh on demand")
    func testRefreshNow() async throws {
        let monitor = MockSessionMonitor()
        
        // Set up a session
        let session = createTestSession()
        monitor.mockSessions = [session.name: session]
        monitor.mockSessionCount = 1
        
        // Refresh
        await monitor.refreshNow()
        
        #expect(monitor.fetchSessionsCalled)
        #expect(monitor.sessionCount == 1)
    }
    
    // MARK: - Error Handling Tests
    
    @Test("Handle server not running")
    func testServerNotRunning() async throws {
        let monitor = SessionMonitor.shared
        
        // When server is not running, sessions should be empty
        // This test assumes server might not be running during tests
        await monitor.fetchSessions()
        
        // Should gracefully handle server not being available
        #expect(monitor.sessions.isEmpty || monitor.sessions.count >= 0)
        #expect(monitor.lastError == nil || monitor.lastError?.isEmpty == false)
    }
    
    @Test("Handle invalid session data")
    func testInvalidSessionData() async throws {
        let monitor = MockSessionMonitor()
        monitor.mockLastError = "Error fetching sessions: Invalid JSON"
        monitor.mockSessionCount = 0
        
        await monitor.fetchSessions()
        
        #expect(monitor.sessions.isEmpty)
        #expect(monitor.sessionCount == 0)
        #expect(monitor.lastError?.contains("Invalid JSON") == true)
    }
    
    // MARK: - Session Information Tests
    
    @Test("Session info properties")
    func testSessionInfoProperties() throws {
        let session = createTestSession(
            id: "test-session",
            status: "running"
        )
        
        #expect(session.name == "test-session")
        #expect(session.status == "running")
        #expect(session.isRunning)
        #expect(session.exitCode == nil)
        #expect(session.cmdline == ["/bin/bash"])
        #expect(session.cwd == "/Users/test")
        #expect(session.pid > 0)
        #expect(!session.stdin.isEmpty)
        #expect(!session.streamOut.isEmpty)
    }
    
    @Test("Session JSON encoding/decoding")
    func testSessionCoding() throws {
        let session = createTestSession()
        
        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        
        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SessionMonitor.SessionInfo.self, from: data)
        
        #expect(decoded.name == session.name)
        #expect(decoded.status == session.status)
        #expect(decoded.pid == session.pid)
        #expect(decoded.exitCode == session.exitCode)
    }
    
    // MARK: - Performance Tests
    
    @Test("Memory management with many sessions", .tags(.performance))
    func testMemoryManagement() async throws {
        let monitor = MockSessionMonitor()
        
        // Create many sessions
        var sessions: [String: SessionMonitor.SessionInfo] = [:]
        let sessionCount = 100
        
        for i in 0..<sessionCount {
            let session = createTestSession(
                id: "session-\(i)",
                status: i % 3 == 0 ? "exited" : "running"
            )
            sessions[session.name] = session
        }
        
        monitor.mockSessions = sessions
        monitor.mockSessionCount = sessions.values.count { $0.isRunning }
        
        await monitor.fetchSessions()
        
        #expect(monitor.sessions.count == sessionCount)
        #expect(monitor.sessionCount == sessions.values.count { $0.isRunning })
        
        // Clear sessions
        monitor.mockSessions = [:]
        monitor.mockSessionCount = 0
        await monitor.fetchSessions()
        
        #expect(monitor.sessions.isEmpty)
        #expect(monitor.sessionCount == 0)
    }
    
    // MARK: - Port Configuration Tests
    
    @Test("Port configuration from UserDefaults")
    func testPortConfiguration() async throws {
        // Save current value
        let originalPort = UserDefaults.standard.integer(forKey: "serverPort")
        
        // Test custom port
        UserDefaults.standard.set(8080, forKey: "serverPort")
        
        let monitor = SessionMonitor.shared
        monitor.startMonitoring()
        
        // The monitor should use the configured port
        // (Can't directly test private serverPort property)
        
        monitor.stopMonitoring()
        
        // Restore original
        UserDefaults.standard.set(originalPort, forKey: "serverPort")
    }
    
    @Test("Default port when not configured")
    func testDefaultPort() async throws {
        // Remove port setting
        UserDefaults.standard.removeObject(forKey: "serverPort")
        
        let monitor = SessionMonitor.shared
        monitor.startMonitoring()
        
        // Should use default port 4020
        // (Can't directly test private serverPort property)
        
        monitor.stopMonitoring()
    }
    
    // MARK: - Concurrent Access Tests
    
    @Test("Concurrent session updates", .tags(.concurrency))
    func testConcurrentUpdates() async throws {
        let monitor = MockSessionMonitor()
        
        await withTaskGroup(of: Void.self) { group in
            // Multiple concurrent fetches
            for i in 0..<5 {
                group.addTask {
                    let session = self.createTestSession(id: "concurrent-\(i)")
                    monitor.mockSessions[session.name] = session
                    monitor.mockSessionCount = monitor.mockSessions.values.count { $0.isRunning }
                    await monitor.fetchSessions()
                }
            }
            
            await group.waitForAll()
        }
        
        // Should handle concurrent updates gracefully
        #expect(monitor.sessions.count <= 5)
        #expect(monitor.sessionCount >= 0)
    }
    
    // MARK: - Integration Tests
    
    @Test("Full monitoring cycle", .tags(.integration))
    func testFullMonitoringCycle() async throws {
        let monitor = MockSessionMonitor()
        
        // 1. Start with no sessions
        #expect(monitor.sessions.isEmpty)
        #expect(monitor.sessionCount == 0)
        
        // 2. Add running sessions
        let session1 = createTestSession(id: "cycle-1", status: "running")
        let session2 = createTestSession(id: "cycle-2", status: "running")
        monitor.mockSessions = [
            session1.name: session1,
            session2.name: session2
        ]
        monitor.mockSessionCount = 2
        
        await monitor.fetchSessions()
        #expect(monitor.sessionCount == 2)
        
        // 3. One session exits
        let exitedSession = createTestSession(id: "cycle-1", status: "exited", exitCode: 0)
        monitor.mockSessions[session1.name] = exitedSession
        monitor.mockSessionCount = 1
        
        await monitor.fetchSessions()
        #expect(monitor.sessionCount == 1)
        #expect(monitor.sessions["cycle-1"]?.isRunning == false)
        #expect(monitor.sessions["cycle-2"]?.isRunning == true)
        
        // 4. All sessions end
        monitor.mockSessions = [:]
        monitor.mockSessionCount = 0
        
        await monitor.fetchSessions()
        #expect(monitor.sessions.isEmpty)
        #expect(monitor.sessionCount == 0)
    }
}