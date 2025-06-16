import Foundation

/// Represents the available tabs in the Settings window
enum SettingsTab: String, CaseIterable {
    case general
    case dashboard
    case advanced
    case debug
    case about

    var displayName: String {
        switch self {
        case .general: "General"
        case .dashboard: "Dashboard"
        case .advanced: "Advanced"
        case .debug: "Debug"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gear"
        case .dashboard: "server.rack"
        case .advanced: "gearshape.2"
        case .debug: "hammer"
        case .about: "info.circle"
        }
    }
}

extension Notification.Name {
    static let openSettingsTab = Notification.Name("openSettingsTab")
}
