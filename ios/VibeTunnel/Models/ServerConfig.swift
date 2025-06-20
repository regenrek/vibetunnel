import Foundation

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
    /// - Returns: true if a non-empty password is set, false otherwise.
    var requiresAuthentication: Bool {
        if let password {
            return !password.isEmpty
        }
        return false
    }

    /// Generates the Basic Authentication header value.
    ///
    /// - Returns: A properly formatted Basic Auth header string,
    ///   or nil if no password is set.
    ///
    /// The authentication uses "admin" as the username and the
    /// configured password. The credentials are base64 encoded
    /// following the HTTP Basic Authentication scheme.
    var authorizationHeader: String? {
        guard let password, !password.isEmpty else { return nil }
        let credentials = "admin:\(password)"
        guard let data = credentials.data(using: .utf8) else { return nil }
        let base64 = data.base64EncodedString()
        return "Basic \(base64)"
    }
}
