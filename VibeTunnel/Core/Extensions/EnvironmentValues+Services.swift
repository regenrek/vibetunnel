import SwiftUI

// MARK: - Environment Keys

private struct ServerManagerKey: EnvironmentKey {
    static let defaultValue: ServerManager? = nil
}

private struct NgrokServiceKey: EnvironmentKey {
    static let defaultValue: NgrokService? = nil
}

private struct AppleScriptPermissionManagerKey: EnvironmentKey {
    static let defaultValue: AppleScriptPermissionManager? = nil
}

private struct TerminalLauncherKey: EnvironmentKey {
    static let defaultValue: TerminalLauncher? = nil
}

// MARK: - Environment Values Extensions

extension EnvironmentValues {
    var serverManager: ServerManager {
        get { self[ServerManagerKey.self] }
        set { self[ServerManagerKey.self] = newValue }
    }
    
    var ngrokService: NgrokService {
        get { self[NgrokServiceKey.self] }
        set { self[NgrokServiceKey.self] = newValue }
    }
    
    var appleScriptPermissionManager: AppleScriptPermissionManager {
        get { self[AppleScriptPermissionManagerKey.self] }
        set { self[AppleScriptPermissionManagerKey.self] = newValue }
    }
    
    var terminalLauncher: TerminalLauncher {
        get { self[TerminalLauncherKey.self] }
        set { self[TerminalLauncherKey.self] = newValue }
    }
}

// MARK: - View Extensions

extension View {
    /// Injects all VibeTunnel services into the environment
    func withVibeTunnelServices(
        serverManager: ServerManager = .shared,
        ngrokService: NgrokService = .shared,
        appleScriptPermissionManager: AppleScriptPermissionManager = .shared,
        terminalLauncher: TerminalLauncher = .shared
    ) -> some View {
        self
            .environment(\.serverManager, serverManager)
            .environment(\.ngrokService, ngrokService)
            .environment(\.appleScriptPermissionManager, appleScriptPermissionManager)
            .environment(\.terminalLauncher, terminalLauncher)
    }
}