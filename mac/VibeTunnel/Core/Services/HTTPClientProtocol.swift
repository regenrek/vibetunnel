import Foundation
import HTTPTypes

/// Protocol for HTTP client abstraction to enable testing.
///
/// Defines the interface for making HTTP requests, allowing for
/// easy mocking and testing of network-dependent code.
public protocol HTTPClientProtocol {
    func data(for request: HTTPRequest, body: Data?) async throws -> (Data, HTTPResponse)
}

/// Real HTTP client implementation.
///
/// Concrete implementation of HTTPClientProtocol using URLSession
/// for actual network requests. Converts between HTTPTypes and
/// Foundation's URLRequest/URLResponse types.
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

/// Errors that can occur during HTTP client operations.
enum HTTPClientError: Error {
    case invalidResponse
}

// MARK: - URLSession Extensions

extension URLRequest {
    init(customHTTPRequest: HTTPRequest) {
        // Reconstruct URL from components
        var urlComponents = URLComponents()
        urlComponents.scheme = customHTTPRequest.scheme

        if let authority = customHTTPRequest.authority {
            // Parse host and port from authority
            let parts = authority.split(separator: ":", maxSplits: 1)
            urlComponents.host = String(parts[0])
            if parts.count > 1 {
                urlComponents.port = Int(String(parts[1]))
            }
        }

        urlComponents.path = customHTTPRequest.path ?? "/"

        guard let url = urlComponents.url else {
            fatalError("HTTPRequest must have valid URL components")
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
