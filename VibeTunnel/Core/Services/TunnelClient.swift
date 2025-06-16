import Foundation
import HTTPTypes
import Logging

/// WebSocket message types for terminal communication
public enum WSMessageType: String, Codable {
    case connect
    case command
    case output
    case error
    case ping
    case pong
    case close
}

/// WebSocket message structure
public struct WSMessage: Codable {
    public let type: WSMessageType
    public let sessionId: String?
    public let data: String?
    public let timestamp: Date

    public init(type: WSMessageType, sessionId: String? = nil, data: String? = nil) {
        self.type = type
        self.sessionId = sessionId
        self.data = data
        self.timestamp = Date()
    }
}

/// Client SDK for interacting with the VibeTunnel server
public class TunnelClient {
    private let baseURL: URL
    private let apiKey: String
    private let httpClient: HTTPClientProtocol
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let logger = Logger(label: "VibeTunnel.TunnelClient")

    /// Default base URL for the tunnel server
    private static let defaultBaseURL: URL = {
        guard let url = URL(string: "http://127.0.0.1:8080") else {
            fatalError("Invalid default base URL - this should never happen with a hardcoded URL")
        }
        return url
    }()

    public init(baseURL: URL? = nil, apiKey: String, httpClient: HTTPClientProtocol? = nil) {
        // Use a static default URL that we know is valid
        self.baseURL = baseURL ?? Self.defaultBaseURL
        self.apiKey = apiKey

        // Use injected client or create default with API key in session config
        if let httpClient {
            self.httpClient = httpClient
        } else {
            let config = URLSessionConfiguration.default
            config.httpAdditionalHeaders = ["X-API-Key": apiKey]
            self.httpClient = HTTPClient(session: URLSession(configuration: config))
        }

        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Health Check

    public func checkHealth() async throws -> TunnelSession.HealthResponse {
        let request = buildRequest(path: "/api/health", method: .get)
        let (data, response) = try await httpClient.data(for: request, body: nil)

        guard response.status == .ok else {
            throw TunnelClientError.httpError(statusCode: response.status.code)
        }

        return try decoder.decode(TunnelSession.HealthResponse.self, from: data)
    }

    // MARK: - Session Management

    public func createSession(clientInfo: TunnelSession.ClientInfo? = nil) async throws -> TunnelSession
        .CreateResponse
    {
        let requestBody = TunnelSession.CreateRequest(clientInfo: clientInfo)
        let request = buildRequest(path: "/api/sessions", method: .post)
        let body = try encoder.encode(requestBody)

        let (data, response) = try await httpClient.data(for: request, body: body)

        guard response.status == .created || response.status == .ok else {
            if let errorResponse = try? decoder.decode(TunnelSession.ErrorResponse.self, from: data) {
                throw TunnelClientError.serverError(errorResponse.error)
            }
            throw TunnelClientError.httpError(statusCode: response.status.code)
        }

        return try decoder.decode(TunnelSession.CreateResponse.self, from: data)
    }

    public func listSessions() async throws -> [TunnelSession] {
        let request = buildRequest(path: "/api/sessions", method: .get)
        let (data, response) = try await httpClient.data(for: request, body: nil)

        guard response.status == .ok else {
            throw TunnelClientError.httpError(statusCode: response.status.code)
        }

        let listResponse = try decoder.decode(TunnelSession.ListResponse.self, from: data)
        return listResponse.sessions
    }

    public func getSession(id: String) async throws -> TunnelSession {
        let request = buildRequest(path: "/api/sessions/\(id)", method: .get)
        let (data, response) = try await httpClient.data(for: request, body: nil)

        guard response.status == .ok else {
            if response.status == .notFound {
                throw TunnelClientError.sessionNotFound
            }
            throw TunnelClientError.httpError(statusCode: response.status.code)
        }

        return try decoder.decode(TunnelSession.self, from: data)
    }

    public func deleteSession(id: String) async throws {
        let request = buildRequest(path: "/api/sessions/\(id)", method: .delete)
        let (_, response) = try await httpClient.data(for: request, body: nil)

        guard response.status == .noContent || response.status == .ok else {
            if response.status == .notFound {
                throw TunnelClientError.sessionNotFound
            }
            throw TunnelClientError.httpError(statusCode: response.status.code)
        }
    }

    // MARK: - Command Execution

    public func executeCommand(
        sessionId: String,
        command: String,
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    )
        async throws -> TunnelSession.ExecuteCommandResponse
    {
        let requestBody = TunnelSession.ExecuteCommandRequest(
            sessionId: sessionId,
            command: command,
            environment: environment,
            workingDirectory: workingDirectory
        )

        let request = buildRequest(path: "/api/sessions/\(sessionId)/execute", method: .post)
        let body = try encoder.encode(requestBody)

        let (data, response) = try await httpClient.data(for: request, body: body)

        guard response.status == .ok else {
            if response.status == .notFound {
                throw TunnelClientError.sessionNotFound
            }
            if let errorResponse = try? decoder.decode(TunnelSession.ErrorResponse.self, from: data) {
                throw TunnelClientError.serverError(errorResponse.error)
            }
            throw TunnelClientError.httpError(statusCode: response.status.code)
        }

        return try decoder.decode(TunnelSession.ExecuteCommandResponse.self, from: data)
    }

    // MARK: - WebSocket Connection

    public func connectWebSocket(sessionId: String? = nil) -> TunnelWebSocketClient? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            logger.error("Failed to create URL components from baseURL: \(baseURL)")
            return nil
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path += "/ws/terminal"

        guard let wsURL = components.url else {
            logger.error("Failed to create WebSocket URL from components")
            return nil
        }

        return TunnelWebSocketClient(url: wsURL, apiKey: apiKey, sessionId: sessionId)
    }

    // MARK: - Private Helpers

    private func buildRequest(path: String, method: HTTPRequest.Method) -> HTTPRequest {
        let url = baseURL.appendingPathComponent(path)

        // Use URLComponents to get scheme, host, and path
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            fatalError("Invalid URL")
        }

        var request = HTTPRequest(
            method: method,
            scheme: components.scheme,
            authority: components.host.map { host in
                components.port.map { "\(host):\($0)" } ?? host
            },
            path: components.path
        )

        // Add authentication
        request.headerFields[.authorization] = "Bearer \(apiKey)"

        // Add content type for POST/PUT requests
        if method == .post || method == .put {
            request.headerFields[.contentType] = "application/json"
        }

        return request
    }
}

/// WebSocket client for real-time terminal communication
public final class TunnelWebSocketClient: NSObject, @unchecked Sendable {
    private let url: URL
    private let apiKey: String
    private var sessionId: String?
    private var webSocketTask: URLSessionWebSocketTask?
    private var messageContinuation: AsyncStream<WSMessage>.Continuation?
    private let logger = Logger(label: "VibeTunnel.TunnelWebSocketClient")

    public var messages: AsyncStream<WSMessage> {
        AsyncStream { continuation in
            self.messageContinuation = continuation
        }
    }

    public init(url: URL, apiKey: String, sessionId: String? = nil) {
        self.url = url
        self.apiKey = apiKey
        self.sessionId = sessionId
        super.init()
    }

    public func connect() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        // Send initial connection message if session ID is provided
        if let sessionId {
            send(WSMessage(type: .connect, sessionId: sessionId))
        }

        // Start receiving messages
        receiveMessage()
    }

    public func send(_ message: WSMessage) {
        guard let webSocketTask else { return }

        do {
            let data = try JSONEncoder().encode(message)
            let text = String(data: data, encoding: .utf8) ?? "{}"
            let message = URLSessionWebSocketTask.Message.string(text)

            webSocketTask.send(message) { error in
                if let error {
                    self.logger.error("WebSocket send error: \(error)")
                }
            }
        } catch {
            logger.error("Failed to encode message: \(error)")
        }
    }

    public func sendCommand(_ command: String) {
        guard let sessionId else { return }
        send(WSMessage(type: .command, sessionId: sessionId, data: command))
    }

    public func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        messageContinuation?.finish()
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let wsMessage = try? JSONDecoder().decode(WSMessage.self, from: data)
                    {
                        self?.messageContinuation?.yield(wsMessage)
                    }
                case .data(let data):
                    if let wsMessage = try? JSONDecoder().decode(WSMessage.self, from: data) {
                        self?.messageContinuation?.yield(wsMessage)
                    }
                @unknown default:
                    break
                }

                // Continue receiving messages
                self?.receiveMessage()

            case .failure(let error):
                self?.logger.error("WebSocket receive error: \(error)")
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension TunnelWebSocketClient: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        logger.info("WebSocket connected")
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        logger.info("WebSocket disconnected with code: \(closeCode)")
        messageContinuation?.finish()
    }
}

// MARK: - Errors

public enum TunnelClientError: LocalizedError, Equatable {
    case invalidResponse
    case httpError(statusCode: Int)
    case serverError(String)
    case sessionNotFound
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server"
        case .httpError(let statusCode):
            "HTTP error: \(statusCode)"
        case .serverError(let message):
            "Server error: \(message)"
        case .sessionNotFound:
            "Session not found"
        case .decodingError(let error):
            "Decoding error: \(error)"
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.invalidResponse, .invalidResponse):
            true
        case (.httpError(let code1), .httpError(let code2)):
            code1 == code2
        case (.serverError(let msg1), .serverError(let msg2)):
            msg1 == msg2
        case (.sessionNotFound, .sessionNotFound):
            true
        case (.decodingError(let msg1), .decodingError(let msg2)):
            msg1 == msg2
        default:
            false
        }
    }
}
