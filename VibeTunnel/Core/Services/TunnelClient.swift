import Combine
import Foundation

/// Client SDK for interacting with the VibeTunnel server
public class TunnelClient {
    private let baseURL: URL
    private let apiKey: String
    private var session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL = URL(string: "http://localhost:8080")!, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["X-API-Key": apiKey]
        self.session = URLSession(configuration: config)

        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Health Check

    public func checkHealth() async throws -> Bool {
        let url = baseURL.appendingPathComponent("health")
        let (_, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TunnelClientError.invalidResponse
        }

        return httpResponse.statusCode == 200
    }

    // MARK: - Session Management

    public func createSession(
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        shell: String? = nil
    )
        async throws -> CreateSessionResponse {
        let url = baseURL.appendingPathComponent("sessions")
        let request = CreateSessionRequest(
            workingDirectory: workingDirectory,
            environment: environment,
            shell: shell
        )

        return try await post(to: url, body: request)
    }

    public func listSessions() async throws -> [SessionInfo] {
        let url = baseURL.appendingPathComponent("sessions")
        let response: ListSessionsResponse = try await get(from: url)
        return response.sessions
    }

    public func getSession(id: String) async throws -> SessionInfo {
        let url = baseURL.appendingPathComponent("sessions/\(id)")
        return try await get(from: url)
    }

    public func closeSession(id: String) async throws {
        let url = baseURL.appendingPathComponent("sessions/\(id)")
        try await delete(from: url)
    }

    // MARK: - Command Execution

    public func executeCommand(
        sessionId: String,
        command: String,
        args: [String]? = nil
    )
        async throws -> CommandResponse {
        let url = baseURL.appendingPathComponent("execute")
        let request = CommandRequest(
            sessionId: sessionId,
            command: command,
            args: args,
            environment: nil
        )

        return try await post(to: url, body: request)
    }

    // MARK: - WebSocket Connection

    public func connectWebSocket(sessionId: String? = nil) -> TunnelWebSocketClient {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = components.path + "/ws/terminal"
        let wsURL = components.url!

        return TunnelWebSocketClient(url: wsURL, apiKey: apiKey, sessionId: sessionId)
    }

    // MARK: - Private Helpers

    private func get<T: Decodable>(from url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TunnelClientError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw TunnelClientError.httpError(statusCode: httpResponse.statusCode)
        }

        return try decoder.decode(T.self, from: data)
    }

    private func post<R: Decodable>(to url: URL, body: some Encodable) async throws -> R {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TunnelClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw TunnelClientError.httpError(statusCode: httpResponse.statusCode)
        }

        return try decoder.decode(R.self, from: data)
    }

    private func delete(from url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TunnelClientError.invalidResponse
        }

        guard httpResponse.statusCode == 204 else {
            throw TunnelClientError.httpError(statusCode: httpResponse.statusCode)
        }
    }
}

/// WebSocket client for real-time terminal communication
public class TunnelWebSocketClient: NSObject {
    private let url: URL
    private let apiKey: String
    private var sessionId: String?
    private var webSocketTask: URLSessionWebSocketTask?
    private let messageSubject = PassthroughSubject<WSMessage, Never>()

    public var messages: AnyPublisher<WSMessage, Never> {
        messageSubject.eraseToAnyPublisher()
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
                    print("WebSocket send error: \(error)")
                }
            }
        } catch {
            print("Failed to encode message: \(error)")
        }
    }

    public func sendCommand(_ command: String) {
        guard let sessionId else { return }
        send(WSMessage(type: .command, sessionId: sessionId, data: command))
    }

    public func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let wsMessage = try? JSONDecoder().decode(WSMessage.self, from: data) {
                        self?.messageSubject.send(wsMessage)
                    }
                case .data(let data):
                    if let wsMessage = try? JSONDecoder().decode(WSMessage.self, from: data) {
                        self?.messageSubject.send(wsMessage)
                    }
                @unknown default:
                    break
                }

                // Continue receiving messages
                self?.receiveMessage()

            case .failure(let error):
                print("WebSocket receive error: \(error)")
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
        print("WebSocket connected")
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        print("WebSocket disconnected")
        messageSubject.send(completion: .finished)
    }
}

// MARK: - Errors

public enum TunnelClientError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Invalid response from server"
        case .httpError(let statusCode):
            "HTTP error: \(statusCode)"
        case .decodingError(let error):
            "Decoding error: \(error.localizedDescription)"
        }
    }
}
