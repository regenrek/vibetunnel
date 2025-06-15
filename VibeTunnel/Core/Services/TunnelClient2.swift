// This file is required for testing with dependency injection.
// DO NOT REMOVE - tests depend on TunnelClient2 and TunnelClient2Error

import Foundation
import HTTPTypes
import HTTPTypesFoundation
import Logging

/// HTTP client-based tunnel client for better testability
public final class TunnelClient2 {
    // MARK: - Properties
    
    private let baseURL: URL
    private let apiKey: String
    private let httpClient: HTTPClientProtocol
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let logger = Logger(label: "VibeTunnel.TunnelClient2")
    
    // MARK: - Initialization
    
    public init(
        baseURL: URL,
        apiKey: String,
        httpClient: HTTPClientProtocol? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.httpClient = httpClient ?? HTTPClient()
        
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }
    
    // MARK: - Health Check
    
    public func checkHealth() async throws -> TunnelSession.HealthResponse {
        let request = buildRequest(path: "/health", method: .get)
        let (data, response) = try await httpClient.data(for: request, body: nil)
        
        guard response.status == .ok else {
            throw TunnelClient2Error.httpError(statusCode: response.status.code)
        }
        
        return try decoder.decode(TunnelSession.HealthResponse.self, from: data)
    }
    
    // MARK: - Session Management
    
    public func createSession(clientInfo: TunnelSession.ClientInfo? = nil) async throws -> TunnelSession.CreateResponse {
        let requestBody = TunnelSession.CreateRequest(clientInfo: clientInfo)
        let request = buildRequest(path: "/api/sessions", method: .post)
        let body = try encoder.encode(requestBody)
        
        let (data, response) = try await httpClient.data(for: request, body: body)
        
        guard response.status == .created || response.status == .ok else {
            if let errorResponse = try? decoder.decode(TunnelSession.ErrorResponse.self, from: data) {
                throw TunnelClient2Error.serverError(errorResponse.error)
            }
            throw TunnelClient2Error.httpError(statusCode: response.status.code)
        }
        
        return try decoder.decode(TunnelSession.CreateResponse.self, from: data)
    }
    
    public func listSessions() async throws -> [TunnelSession] {
        let request = buildRequest(path: "/api/sessions", method: .get)
        let (data, response) = try await httpClient.data(for: request, body: nil)
        
        guard response.status == .ok else {
            throw TunnelClient2Error.httpError(statusCode: response.status.code)
        }
        
        let listResponse = try decoder.decode(TunnelSession.ListResponse.self, from: data)
        return listResponse.sessions
    }
    
    public func getSession(id: String) async throws -> TunnelSession {
        let request = buildRequest(path: "/api/sessions/\(id)", method: .get)
        let (data, response) = try await httpClient.data(for: request, body: nil)
        
        guard response.status == .ok else {
            if response.status == .notFound {
                throw TunnelClient2Error.sessionNotFound
            }
            throw TunnelClient2Error.httpError(statusCode: response.status.code)
        }
        
        return try decoder.decode(TunnelSession.self, from: data)
    }
    
    public func deleteSession(id: String) async throws {
        let request = buildRequest(path: "/api/sessions/\(id)", method: .delete)
        let (_, response) = try await httpClient.data(for: request, body: nil)
        
        guard response.status == .noContent || response.status == .ok else {
            if response.status == .notFound {
                throw TunnelClient2Error.sessionNotFound
            }
            throw TunnelClient2Error.httpError(statusCode: response.status.code)
        }
    }
    
    // MARK: - Command Execution
    
    public func executeCommand(
        sessionId: String,
        command: String,
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) async throws -> TunnelSession.ExecuteCommandResponse {
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
                throw TunnelClient2Error.sessionNotFound
            }
            if let errorResponse = try? decoder.decode(TunnelSession.ErrorResponse.self, from: data) {
                throw TunnelClient2Error.serverError(errorResponse.error)
            }
            throw TunnelClient2Error.httpError(statusCode: response.status.code)
        }
        
        return try decoder.decode(TunnelSession.ExecuteCommandResponse.self, from: data)
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

// MARK: - Errors

public enum TunnelClient2Error: LocalizedError, Equatable {
    case invalidResponse
    case httpError(statusCode: Int)
    case serverError(String)
    case sessionNotFound
    case decodingError(String)
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .sessionNotFound:
            return "Session not found"
        case .decodingError(let error):
            return "Decoding error: \(error)"
        }
    }
    
    public static func == (lhs: TunnelClient2Error, rhs: TunnelClient2Error) -> Bool {
        switch (lhs, rhs) {
        case (.invalidResponse, .invalidResponse):
            return true
        case (.httpError(let code1), .httpError(let code2)):
            return code1 == code2
        case (.serverError(let msg1), .serverError(let msg2)):
            return msg1 == msg2
        case (.sessionNotFound, .sessionNotFound):
            return true
        case (.decodingError(let msg1), .decodingError(let msg2)):
            return msg1 == msg2
        default:
            return false
        }
    }
}