import Foundation
import HTTPTypes
@testable import VibeTunnel

/// Mock HTTP client for testing
final class MockHTTPClient: HTTPClientProtocol {
    // MARK: - Response Configuration
    
    struct ResponseConfig {
        let data: Data?
        let response: HTTPResponse
        let error: Error?
        let delay: TimeInterval
        
        init(
            data: Data? = nil,
            statusCode: HTTPResponse.Status = .ok,
            headers: HTTPFields = [:],
            error: Error? = nil,
            delay: TimeInterval = 0
        ) {
            self.data = data
            self.response = HTTPResponse(status: statusCode, headerFields: headers)
            self.error = error
            self.delay = delay
        }
    }
    
    // MARK: - Request Recording
    
    struct RecordedRequest {
        let request: HTTPRequest
        let body: Data?
        let timestamp: Date
    }
    
    // MARK: - Properties
    
    private var responseConfigs: [String: ResponseConfig] = [:]
    private var defaultResponse: ResponseConfig
    private(set) var recordedRequests: [RecordedRequest] = []
    
    // MARK: - Initialization
    
    init(defaultResponse: ResponseConfig = ResponseConfig()) {
        self.defaultResponse = defaultResponse
    }
    
    // MARK: - Configuration
    
    func configure(for path: String, response: ResponseConfig) {
        responseConfigs[path] = response
    }
    
    func configureJSON<T: Encodable>(_ object: T, statusCode: HTTPResponse.Status = .ok, for path: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(object)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        configure(for: path, response: ResponseConfig(data: data, statusCode: statusCode, headers: headers))
    }
    
    func reset() {
        responseConfigs.removeAll()
        recordedRequests.removeAll()
    }
    
    // MARK: - HTTPClientProtocol
    
    func data(for request: HTTPRequest, body: Data?) async throws -> (Data, HTTPResponse) {
        // Record the request
        recordedRequests.append(RecordedRequest(
            request: request,
            body: body,
            timestamp: Date()
        ))
        
        // Get response configuration
        let config = responseConfigs[request.path ?? ""] ?? defaultResponse
        
        // Simulate delay if configured
        if config.delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(config.delay * 1_000_000_000))
        }
        
        // Throw error if configured
        if let error = config.error {
            throw error
        }
        
        return (config.data ?? Data(), config.response)
    }
    
    // MARK: - Test Helpers
    
    func lastRequest() -> RecordedRequest? {
        recordedRequests.last
    }
    
    func requests(for path: String) -> [RecordedRequest] {
        recordedRequests.filter { $0.request.path == path }
    }
    
    func requestCount(for path: String) -> Int {
        requests(for: path).count
    }
    
    func wasRequested(path: String) -> Bool {
        requestCount(for: path) > 0
    }
    
    func lastRequestBody<T: Decodable>(as type: T.Type) throws -> T? {
        guard let body = lastRequest()?.body else { return nil }
        return try JSONDecoder().decode(type, from: body)
    }
}

// MARK: - Common Test Responses

extension MockHTTPClient.ResponseConfig {
    static let success = MockHTTPClient.ResponseConfig(statusCode: .ok)
    static let unauthorized = MockHTTPClient.ResponseConfig(statusCode: .unauthorized)
    static let notFound = MockHTTPClient.ResponseConfig(statusCode: .notFound)
    static let serverError = MockHTTPClient.ResponseConfig(statusCode: .internalServerError)
    
    static func json<T: Encodable>(_ object: T, statusCode: HTTPResponse.Status = .ok) throws -> MockHTTPClient.ResponseConfig {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(object)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return MockHTTPClient.ResponseConfig(
            data: data,
            statusCode: statusCode,
            headers: headers
        )
    }
}

// MARK: - Error Types

enum MockHTTPError: Error {
    case networkError
    case timeout
    case invalidResponse
}