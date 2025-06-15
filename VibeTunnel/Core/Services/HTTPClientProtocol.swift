import Foundation
import HTTPTypes

/// Protocol for HTTP client abstraction to enable testing
public protocol HTTPClientProtocol {
    func data(for request: HTTPRequest, body: Data?) async throws -> (Data, HTTPResponse)
}

/// Real HTTP client implementation
public final class HTTPClient: HTTPClientProtocol {
    private let session: URLSession
    
    public init(session: URLSession = .shared) {
        self.session = session
    }
    
    public func data(for request: HTTPRequest, body: Data?) async throws -> (Data, HTTPResponse) {
        var urlRequest = URLRequest(customHTTPRequest: request)
        urlRequest.httpBody = body
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }
        
        let httpTypesResponse = httpResponse.httpResponse
        return (data, httpTypesResponse)
    }
}

enum HTTPClientError: Error {
    case invalidResponse
}

// MARK: - URLSession Extensions

extension URLRequest {
    init(customHTTPRequest: HTTPRequest) {
        guard let url = customHTTPRequest.url else {
            fatalError("HTTPRequest must have a valid URL")
        }
        
        self.init(url: url)
        self.httpMethod = customHTTPRequest.method.rawValue
        
        // Copy headers
        for field in customHTTPRequest.headerFields {
            self.setValue(field.value, forHTTPHeaderField: field.name.rawName)
        }
    }
}

extension HTTPURLResponse {
    var httpResponse: HTTPResponse {
        let status = HTTPResponse.Status(code: statusCode)
        var headerFields = HTTPFields()
        
        for (key, value) in allHeaderFields {
            if let name = key as? String, let fieldName = HTTPField.Name(name) {
                headerFields[fieldName] = value as? String
            }
        }
        
        return HTTPResponse(status: status, headerFields: headerFields)
    }
}
