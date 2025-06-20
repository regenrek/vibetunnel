import Foundation

struct ServerConfig: Codable, Equatable {
    let host: String
    let port: Int
    let name: String?
    let password: String?

    var baseURL: URL {
        // This should always succeed with valid host and port
        // Fallback ensures we always have a valid URL
        URL(string: "http://\(host):\(port)") ?? URL(fileURLWithPath: "/")
    }

    var displayName: String {
        name ?? "\(host):\(port)"
    }

    var requiresAuthentication: Bool {
        if let password {
            return !password.isEmpty
        }
        return false
    }

    var authorizationHeader: String? {
        guard let password, !password.isEmpty else { return nil }
        let credentials = "admin:\(password)"
        guard let data = credentials.data(using: .utf8) else { return nil }
        let base64 = data.base64EncodedString()
        return "Basic \(base64)"
    }
}
