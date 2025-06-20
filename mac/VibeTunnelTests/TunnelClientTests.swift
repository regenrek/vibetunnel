import Foundation
import HTTPTypes
import Testing
@testable import VibeTunnel

@Suite("TunnelClient Tests")
struct TunnelClientTests {
    let mockClient: MockHTTPClient
    let tunnelClient: TunnelClient
    let testURL = URL(string: "http://localhost:8080")!
    let testAPIKey = "test-api-key-123"

    init() {
        self.mockClient = MockHTTPClient()
        self.tunnelClient = TunnelClient(
            baseURL: testURL,
            apiKey: testAPIKey,
            httpClient: mockClient
        )
    }

    // MARK: - Health Check Tests

    @Test("Health check returns healthy status")
    func healthCheckSuccess() async throws {
        // Arrange
        let healthResponse = TestFixtures.healthCheckResponse(
            status: "healthy",
            sessions: 3,
            version: "1.0.0"
        )
        try mockClient.configureJSON(healthResponse, for: "/api/health")

        // Act
        let result = try await tunnelClient.checkHealth()

        // Assert
        #expect(result.status == "healthy")
        #expect(result.sessions == 3)
        #expect(result.version == "1.0.0")

        // Verify request
        #expect(mockClient.wasRequested(path: "/api/health"))
        let lastRequest = mockClient.lastRequest()!
        #expect(lastRequest.request.method == .get)
        #expect(lastRequest.request.headerFields[.authorization] == "Bearer \(testAPIKey)")
    }

    @Test("Health check handles server error")
    func healthCheckServerError() async throws {
        // Arrange
        mockClient.configure(for: "/api/health", response: .serverError)

        // Act & Assert
        await #expect(throws: TunnelClientError.httpError(statusCode: 500)) {
            _ = try await tunnelClient.checkHealth()
        }
    }

    // MARK: - Session Creation Tests

    @Test("Create session with client info")
    func createSessionWithClientInfo() async throws {
        // Arrange
        let clientInfo = TestFixtures.defaultClientInfo()
        let sessionResponse = TestFixtures.createSessionResponse(id: "00000000-0000-0000-0000-000000000123")
        try mockClient.configureJSON(sessionResponse, statusCode: .created, for: "/api/sessions")

        // Act
        let result = try await tunnelClient.createSession(clientInfo: clientInfo)

        // Assert
        #expect(result.id == "00000000-0000-0000-0000-000000000123")
        #expect(result.session.id.uuidString == "00000000-0000-0000-0000-000000000123")

        // Verify request
        let lastRequest = mockClient.lastRequest()!
        #expect(lastRequest.request.method == .post)
        #expect(lastRequest.request.headerFields[.contentType] == "application/json")
        #expect(lastRequest.request.headerFields[.authorization] == "Bearer \(testAPIKey)")

        // Verify request body
        let requestBody = try lastRequest.body.map {
            try JSONDecoder().decode(TunnelSession.CreateRequest.self, from: $0)
        }
        #expect(requestBody?.clientInfo?.hostname == "test-host")
    }

    @Test("Create session without client info")
    func createSessionWithoutClientInfo() async throws {
        // Arrange
        let sessionResponse = TestFixtures.createSessionResponse(id: "00000000-0000-0000-0000-000000000456")
        try mockClient.configureJSON(sessionResponse, statusCode: .ok, for: "/api/sessions")

        // Act
        let result = try await tunnelClient.createSession()

        // Assert
        #expect(result.id == "00000000-0000-0000-0000-000000000456")

        // Verify request body
        let lastRequest = mockClient.lastRequest()!
        let requestBody = try lastRequest.body.map {
            try JSONDecoder().decode(TunnelSession.CreateRequest.self, from: $0)
        }
        #expect(requestBody?.clientInfo == nil)
    }

    @Test("Create session handles server error with message")
    func createSessionServerError() async throws {
        // Arrange
        let errorResponse = TestFixtures.errorResponse(
            error: "Maximum sessions reached",
            code: "MAX_SESSIONS"
        )
        let errorData = try JSONEncoder().encode(errorResponse)
        mockClient.configure(
            for: "/api/sessions",
            response: MockHTTPClient.ResponseConfig(
                data: errorData,
                statusCode: .badRequest
            )
        )

        // Act & Assert
        await #expect(throws: TunnelClientError.serverError("Maximum sessions reached")) {
            _ = try await tunnelClient.createSession()
        }
    }

    // MARK: - Session Management Tests

    @Test("List sessions returns multiple sessions")
    func testListSessions() async throws {
        // Arrange
        let sessions = [
            TestFixtures.createSession(id: "00000000-0000-0000-0000-000000000001"),
            TestFixtures.createSession(id: "00000000-0000-0000-0000-000000000002"),
            TestFixtures.createSession(id: "00000000-0000-0000-0000-000000000003")
        ]
        let listResponse = TunnelSession.ListResponse(sessions: sessions)
        try mockClient.configureJSON(listResponse, for: "/api/sessions")

        // Act
        let result = try await tunnelClient.listSessions()

        // Assert
        #expect(result.count == 3)
        #expect(result[0].id.uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(result[1].id.uuidString == "00000000-0000-0000-0000-000000000002")
        #expect(result[2].id.uuidString == "00000000-0000-0000-0000-000000000003")

        // Verify request
        #expect(mockClient.requestCount(for: "/api/sessions") == 1)
    }

    @Test("Get session by ID")
    func testGetSession() async throws {
        // Arrange
        let session = TestFixtures.createSession(id: "00000000-0000-0000-0000-000000000789")
        try mockClient.configureJSON(session, for: "/api/sessions/00000000-0000-0000-0000-000000000789")

        // Act
        let result = try await tunnelClient.getSession(id: "00000000-0000-0000-0000-000000000789")

        // Assert
        #expect(result.id.uuidString == "00000000-0000-0000-0000-000000000789")
        #expect(result.isActive)

        // Verify request
        let lastRequest = mockClient.lastRequest()!
        #expect(lastRequest.request.path == "/api/sessions/00000000-0000-0000-0000-000000000789")
        #expect(lastRequest.request.method == .get)
    }

    @Test("Get session handles not found")
    func getSessionNotFound() async throws {
        // Arrange
        mockClient.configure(
            for: "/api/sessions/unknown-session",
            response: MockHTTPClient.ResponseConfig(statusCode: .notFound)
        )

        // Act & Assert
        await #expect(throws: TunnelClientError.sessionNotFound) {
            _ = try await tunnelClient.getSession(id: "unknown-session")
        }
    }

    @Test("Delete session")
    func testDeleteSession() async throws {
        // Arrange
        mockClient.configure(
            for: "/api/sessions/00000000-0000-0000-0000-000000000123",
            response: MockHTTPClient.ResponseConfig(statusCode: .noContent)
        )

        // Act
        try await tunnelClient.deleteSession(id: "00000000-0000-0000-0000-000000000123")

        // Assert
        #expect(mockClient.wasRequested(path: "/api/sessions/00000000-0000-0000-0000-000000000123"))
        let lastRequest = mockClient.lastRequest()!
        #expect(lastRequest.request.method == .delete)
    }

    // MARK: - Command Execution Tests

    @Test("Execute command successfully")
    func testExecuteCommand() async throws {
        // Arrange
        let commandResponse = TestFixtures.executeCommandResponse(
            exitCode: 0,
            stdout: "Hello, World!",
            stderr: ""
        )
        try mockClient.configureJSON(commandResponse, for: "/api/sessions/00000000-0000-0000-0000-000000000123/execute")

        // Act
        let result = try await tunnelClient.executeCommand(
            sessionId: "00000000-0000-0000-0000-000000000123",
            command: "echo 'Hello, World!'"
        )

        // Assert
        #expect(result.exitCode == 0)
        #expect(result.stdout == "Hello, World!")
        #expect(result.stderr.isEmpty)

        // Verify request
        let lastRequest = mockClient.lastRequest()!
        let requestBody = try lastRequest.body.map {
            try JSONDecoder().decode(TunnelSession.ExecuteCommandRequest.self, from: $0)
        }
        #expect(requestBody?.command == "echo 'Hello, World!'")
        #expect(requestBody?.sessionId == "00000000-0000-0000-0000-000000000123")
    }

    @Test("Execute command with environment and working directory")
    func executeCommandWithEnvironment() async throws {
        // Arrange
        let commandResponse = TestFixtures.executeCommandResponse(exitCode: 0)
        try mockClient.configureJSON(commandResponse, for: "/api/sessions/00000000-0000-0000-0000-000000000123/execute")

        let environment = ["PATH": "/usr/bin", "USER": "test"]
        let workingDir = "/tmp/test"

        // Act
        let result = try await tunnelClient.executeCommand(
            sessionId: "00000000-0000-0000-0000-000000000123",
            command: "pwd",
            environment: environment,
            workingDirectory: workingDir
        )

        // Assert
        #expect(result.exitCode == 0)

        // Verify request body
        let lastRequest = mockClient.lastRequest()!
        let requestBody = try lastRequest.body.map {
            try JSONDecoder().decode(TunnelSession.ExecuteCommandRequest.self, from: $0)
        }
        #expect(requestBody?.environment == environment)
        #expect(requestBody?.workingDirectory == workingDir)
    }

    @Test("Execute command handles failure")
    func executeCommandFailure() async throws {
        // Arrange
        let commandResponse = TestFixtures.executeCommandResponse(
            exitCode: 127,
            stdout: "",
            stderr: "Command not found"
        )
        try mockClient.configureJSON(commandResponse, for: "/api/sessions/00000000-0000-0000-0000-000000000123/execute")

        // Act
        let result = try await tunnelClient.executeCommand(
            sessionId: "00000000-0000-0000-0000-000000000123",
            command: "nonexistent-command"
        )

        // Assert
        #expect(result.exitCode == 127)
        #expect(result.stderr == "Command not found")
    }

    // MARK: - Authentication Tests

    @Test("All requests include authentication header")
    func authenticationHeader() async throws {
        // Arrange
        mockClient.configure(for: "/api/health", response: .success)
        mockClient.configure(for: "/api/sessions", response: .success)

        // Act
        _ = try? await tunnelClient.checkHealth()
        _ = try? await tunnelClient.listSessions()

        // Assert
        for request in mockClient.recordedRequests {
            #expect(request.request.headerFields[.authorization] == "Bearer \(testAPIKey)")
        }
    }

    // MARK: - Error Handling Tests

    @Test("Network error handling")
    func testNetworkError() async throws {
        // Arrange
        mockClient.configure(
            for: "/api/sessions",
            response: MockHTTPClient.ResponseConfig(
                error: MockHTTPError.networkError
            )
        )

        // Act & Assert
        await #expect(throws: MockHTTPError.networkError) {
            _ = try await tunnelClient.listSessions()
        }
    }

    @Test("Timeout error handling")
    func timeoutError() async throws {
        // Arrange
        mockClient.configure(
            for: "/api/sessions",
            response: MockHTTPClient.ResponseConfig(
                error: MockHTTPError.timeout,
                delay: 0.1
            )
        )

        // Act & Assert
        await #expect(throws: MockHTTPError.timeout) {
            _ = try await tunnelClient.listSessions()
        }
    }

    @Test("Various HTTP error codes")
    func variousHTTPErrors() async throws {
        let errorCodes: [HTTPResponse.Status] = [
            .badRequest,
            .unauthorized,
            .forbidden,
            .notFound,
            .internalServerError,
            .badGateway,
            .serviceUnavailable
        ]

        for statusCode in errorCodes {
            // Reset mock for each test
            mockClient.reset()
            mockClient.configure(
                for: "/api/sessions",
                response: MockHTTPClient.ResponseConfig(statusCode: statusCode)
            )

            // Act & Assert
            await #expect(throws: TunnelClientError.httpError(statusCode: statusCode.code)) {
                _ = try await tunnelClient.listSessions()
            }
        }
    }
}
