import os
import UserNotifications

/// Stub implementation of SparkleUpdaterManager
/// TODO: Add Sparkle dependency through Xcode Package Manager and restore full implementation
@available(macOS 10.15, *)
public final class SparkleUpdaterManager: NSObject {
    
    public static let shared = SparkleUpdaterManager()
    
    private let logger = Logger(
        subsystem: "VibeTunnel",
        category: "SparkleUpdater"
    )
    
    private override init() {
        super.init()
        logger.info("SparkleUpdaterManager initialized (stub implementation)")
    }
    
    public func setUpdateChannel(_ channel: UpdateChannel) {
        logger.info("Update channel set to: \(channel) (stub)")
    }
    
    public func checkForUpdatesInBackground() {
        logger.info("Background update check requested (stub)")
    }
    
    public func checkForUpdates() {
        logger.info("Manual update check requested (stub)")
    }
    
    public func clearUserDefaults() {
        logger.info("User defaults cleared (stub)")
    }
}

/// Stub implementation of SparkleViewModel
@MainActor
@available(macOS 10.15, *)
public final class SparkleViewModel: ObservableObject {
    @Published public var canCheckForUpdates = false
    @Published public var isCheckingForUpdates = false
    @Published public var automaticallyChecksForUpdates = true
    @Published public var automaticallyDownloadsUpdates = false
    @Published public var updateCheckInterval: TimeInterval = 86400
    @Published public var lastUpdateCheckDate: Date?
    @Published public var updateChannel: UpdateChannel = .stable
    
    private let updaterManager = SparkleUpdaterManager.shared
    
    public init() {
        // Stub implementation
    }
    
    public func checkForUpdates() {
        updaterManager.checkForUpdates()
    }
    
    public func setUpdateChannel(_ channel: UpdateChannel) {
        updateChannel = channel
        updaterManager.setUpdateChannel(channel)
    }
}

fileprivate extension ProcessInfo {
    var installedFromAppStore: Bool {
        // Check for App Store receipt
        let receiptURL = Bundle.main.appStoreReceiptURL
        return receiptURL?.lastPathComponent == "receipt" && FileManager.default.fileExists(atPath: receiptURL?.path ?? "")
    }
}