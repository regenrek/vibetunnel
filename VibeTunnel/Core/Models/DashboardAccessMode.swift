import Foundation

/// Dashboard access mode
enum DashboardAccessMode: String, CaseIterable {
    case localhost
    case network

    var displayName: String {
        switch self {
        case .localhost: "Localhost only"
        case .network: "Network"
        }
    }

    var bindAddress: String {
        switch self {
        case .localhost: "127.0.0.1"
        case .network: "0.0.0.0"
        }
    }

    var description: String {
        switch self {
        case .localhost: "Only accessible from this Mac"
        case .network: "Accessible from other devices on the network"
        }
    }
}
