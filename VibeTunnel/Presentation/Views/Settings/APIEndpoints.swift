import Foundation

/// Represents an API endpoint for testing in debug mode
struct APIEndpoint: Identifiable {
    let id: String
    let method: String
    let path: String
    let description: String
    let isTestable: Bool

    init(method: String, path: String, description: String, isTestable: Bool) {
        self.id = "\(method)_\(path)"
        self.method = method
        self.path = path
        self.description = description
        self.isTestable = isTestable
    }
}

let apiEndpoints = [
    APIEndpoint(method: "GET", path: "/", description: "Web interface - displays server status", isTestable: true),
    APIEndpoint(
        method: "GET",
        path: "/api/health",
        description: "Health check - returns OK if server is running",
        isTestable: true
    ),
    APIEndpoint(
        method: "GET",
        path: "/info",
        description: "Server information - returns version and uptime",
        isTestable: true
    ),
    APIEndpoint(method: "GET", path: "/sessions", description: "List tty-fwd sessions", isTestable: true),
    APIEndpoint(method: "POST", path: "/sessions", description: "Create new terminal session", isTestable: false),
    APIEndpoint(
        method: "GET",
        path: "/sessions/:id",
        description: "Get specific session information",
        isTestable: false
    ),
    APIEndpoint(method: "DELETE", path: "/sessions/:id", description: "Close a terminal session", isTestable: false),
    APIEndpoint(method: "POST", path: "/execute", description: "Execute command in a session", isTestable: false),
    APIEndpoint(method: "POST", path: "/api/ngrok/start", description: "Start ngrok tunnel", isTestable: true),
    APIEndpoint(method: "POST", path: "/api/ngrok/stop", description: "Stop ngrok tunnel", isTestable: true),
    APIEndpoint(method: "GET", path: "/api/ngrok/status", description: "Get ngrok tunnel status", isTestable: true)
]
