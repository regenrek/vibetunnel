import Foundation
import Combine

/// Stub implementation of TunnelServer for the macOS app
@MainActor
public final class TunnelServerDemo: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var port: Int
    
    public init(port: Int = 8080) {
        self.port = port
    }
    
    public func start() async throws {
        isRunning = true
    }
    
    public func stop() async throws {
        isRunning = false
    }
}