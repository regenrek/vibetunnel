import Foundation

/// Authentication type for server connections
enum AuthType: String, Codable, CaseIterable {
    case none = "none"
    case basic = "basic"
    case bearer = "bearer"
    
    var displayName: String {
        switch self {
        case .none: return "No Authentication"
        case .basic: return "Basic Auth (Username/Password)"
        case .bearer: return "Bearer Token"
        }
    }
}

/// Configuration for connecting to a VibeTunnel server.
///
/// ServerConfig stores all necessary information to establish
/// a connection to a VibeTunnel server, including host, port,
/// optional authentication, and display name.
struct ServerConfig: Codable, Equatable {
    let host: String
    let port: Int
    let name: String?
    let password: String?
    let authType: AuthType
    let bearerToken: String?
    
    init(
        host: String,
        port: Int,
        name: String? = nil,
        password: String? = nil,
        authType: AuthType = .none,
        bearerToken: String? = nil
    ) {
        self.host = host
        self.port = port
        self.name = name
        self.password = password
        self.authType = authType
        self.bearerToken = bearerToken
    }

    /// Constructs the base URL for API requests.
    ///
    /// - Returns: A URL constructed from the host and port.
    ///
    /// The URL uses HTTP protocol. If URL construction fails
    /// (which should not happen with valid host/port), returns
    /// a file URL as fallback to ensure non-nil return.
    var baseURL: URL {
        // This should always succeed with valid host and port
        // Fallback ensures we always have a valid URL
        URL(string: "http://\(host):\(port)") ?? URL(fileURLWithPath: "/")
    }

    /// User-friendly display name for the server.
    ///
    /// Returns the custom name if set, otherwise formats
    /// the host and port as "host:port".
    var displayName: String {
        name ?? "\(host):\(port)"
    }

    /// Indicates whether the server requires authentication.
    ///
    /// - Returns: true if authentication is configured, false otherwise.
    var requiresAuthentication: Bool {
        switch authType {
        case .none:
            return false
        case .basic:
            if let password {
                return !password.isEmpty
            }
            return false
        case .bearer:
            if let bearerToken {
                return !bearerToken.isEmpty
            }
            return false
        }
    }

    /// Generates the Authorization header value based on auth type.
    ///
    /// - Returns: A properly formatted auth header string,
    ///   or nil if no authentication is configured.
    ///
    /// For Basic auth: uses "admin" as the username with the configured password.
    /// For Bearer auth: uses the configured bearer token.
    var authorizationHeader: String? {
        switch authType {
        case .none:
            return nil
            
        case .basic:
            guard let password, !password.isEmpty else { return nil }
            let credentials = "admin:\(password)"
            guard let data = credentials.data(using: .utf8) else { return nil }
            let base64 = data.base64EncodedString()
            return "Basic \(base64)"
            
        case .bearer:
            guard let bearerToken, !bearerToken.isEmpty else { return nil }
            return "Bearer \(bearerToken)"
        }
    }
}
