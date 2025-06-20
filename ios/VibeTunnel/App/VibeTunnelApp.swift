import SwiftUI

@main
struct VibeTunnelApp: App {
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var navigationManager = NavigationManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionManager)
                .environmentObject(navigationManager)
                .onOpenURL { url in
                    handleURL(url)
                }
        }
    }
    
    private func handleURL(_ url: URL) {
        // Handle vibetunnel://session/{sessionId} URLs
        guard url.scheme == "vibetunnel" else { return }
        
        if url.host == "session",
           let sessionId = url.pathComponents.last,
           !sessionId.isEmpty {
            navigationManager.navigateToSession(sessionId)
        }
    }
}

class ConnectionManager: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var serverConfig: ServerConfig?
    
    init() {
        loadSavedConnection()
    }
    
    private func loadSavedConnection() {
        if let data = UserDefaults.standard.data(forKey: "savedServerConfig"),
           let config = try? JSONDecoder().decode(ServerConfig.self, from: data) {
            self.serverConfig = config
        }
    }
    
    func saveConnection(_ config: ServerConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "savedServerConfig")
            self.serverConfig = config
        }
    }
    
    func disconnect() {
        isConnected = false
    }
}

class NavigationManager: ObservableObject {
    @Published var selectedSessionId: String?
    @Published var shouldNavigateToSession: Bool = false
    
    func navigateToSession(_ sessionId: String) {
        selectedSessionId = sessionId
        shouldNavigateToSession = true
    }
    
    func clearNavigation() {
        selectedSessionId = nil
        shouldNavigateToSession = false
    }
}