import CryptoKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdCore
import Logging

/// Custom HTTP header name for API key
extension HTTPField.Name {
    static let xAPIKey = Self("X-API-Key")!
}

/// Simple authentication middleware for the tunnel server
struct AuthenticationMiddleware<Context: RequestContext>: RouterMiddleware {
    private let logger = Logger(label: "VibeTunnel.AuthMiddleware")
    private let bearerPrefix = "Bearer "

    /// In production, this should be stored securely and configurable
    private let validApiKeys: Set<String>

    init() {
        // Load API keys from storage
        var apiKeys = APIKeyManager.loadStoredAPIKeys()

        if apiKeys.isEmpty {
            // Generate a default API key for development
            let defaultKey = Self.generateAPIKey()
            apiKeys = [defaultKey]
            APIKeyManager.saveAPIKeys(apiKeys)
            logger.info("Authentication initialized with new API key: \(defaultKey)")
        } else {
            logger.info("Authentication initialized with \(apiKeys.count) stored API key(s)")
        }

        self.validApiKeys = apiKeys
    }

    init(apiKeys: Set<String>) {
        self.validApiKeys = apiKeys
    }

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    )
        async throws -> Response {
        // Skip authentication for health check and WebSocket upgrade
        if request.uri.path == "/health" || request.headers[.upgrade] == "websocket" {
            return try await next(request, context)
        }

        // Check for API key in header
        if let apiKey = request.headers[.xAPIKey] {
            if validApiKeys.contains(apiKey) {
                return try await next(request, context)
            }
        }

        // Check for Bearer token
        if let authorization = request.headers[.authorization],
           authorization.hasPrefix(bearerPrefix) {
            let token = String(authorization.dropFirst(bearerPrefix.count))
            if validApiKeys.contains(token) {
                return try await next(request, context)
            }
        }

        // No valid authentication found
        logger.warning("Unauthorized request to \(request.uri.path)")
        throw HTTPError(.unauthorized, message: "Invalid or missing API key")
    }

    /// Generate a secure API key
    static func generateAPIKey() -> String {
        let randomBytes = SymmetricKey(size: .bits256)
        let data = randomBytes.withUnsafeBytes { Data($0) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// API Key management utilities
enum APIKeyManager {
    static let apiKeyStorageKey = "VibeTunnel.APIKeys"

    static func loadStoredAPIKeys() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: apiKeyStorageKey),
              let keys = try? JSONDecoder().decode(Set<String>.self, from: data)
        else {
            // Generate and store a default key if none exists
            let defaultKey = AuthenticationMiddleware<BasicRequestContext>.generateAPIKey()
            let keys = Set([defaultKey])
            saveAPIKeys(keys)
            return keys
        }
        return keys
    }

    static func saveAPIKeys(_ keys: Set<String>) {
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults.standard.set(data, forKey: apiKeyStorageKey)
        }
    }

    static func addAPIKey(_ key: String) {
        var keys = loadStoredAPIKeys()
        keys.insert(key)
        saveAPIKeys(keys)
    }

    static func removeAPIKey(_ key: String) {
        var keys = loadStoredAPIKeys()
        keys.remove(key)
        saveAPIKeys(keys)
    }
}
