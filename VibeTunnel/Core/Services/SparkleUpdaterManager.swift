import Foundation
import Observation
import Sparkle
import UserNotifications
import os.log

/// SparkleUpdaterManager with automatic update downloads enabled
@available(macOS 10.15, *)
@MainActor
public final class SparkleUpdaterManager: NSObject {
    
    public static let shared = SparkleUpdaterManager()
    
    fileprivate var updaterController: SPUStandardUpdaterController?
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VibeTunnel",
        category: "SparkleUpdater"
    )
    
    public override init() {
        super.init()
        
        // Check if installed from App Store
        if ProcessInfo.processInfo.installedFromAppStore {
            logger.info("App installed from App Store, skipping Sparkle initialization")
            return
        }
        
        // Initialize Sparkle with standard configuration
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        
        // Configure automatic updates
        if let updater = updaterController?.updater {
            // Enable automatic checking for updates
            updater.automaticallyChecksForUpdates = true
            
            // Enable automatic downloading of updates
            updater.automaticallyDownloadsUpdates = true
            
            // Set update check interval to 24 hours
            updater.updateCheckInterval = 86400
            
            logger.info("Sparkle updater initialized successfully with automatic downloads enabled")
        }
    }
    
    public func setUpdateChannel(_ channel: UpdateChannel) {
        // This would require custom feed URL handling - for now just log
        logger.info("Update channel set to: \(channel.rawValue)")
    }
    
    public func checkForUpdatesInBackground() {
        guard let updater = updaterController?.updater else { return }
        updater.checkForUpdatesInBackground()
        logger.info("Background update check initiated")
    }
    
    public func checkForUpdates() {
        guard updaterController != nil else { 
            logger.warning("Cannot check for updates: updater not initialized")
            return 
        }
        updaterController?.checkForUpdates(nil)
        logger.info("Manual update check initiated")
    }
    
    public func clearUserDefaults() {
        let sparkleDefaults = [
            "SUEnableAutomaticChecks",
            "SUHasLaunchedBefore",
            "SULastCheckTime",
            "SUSendProfileInfo",
            "SUUpdateRelaunchingMarker",
            "SUAutomaticallyUpdate",
            "SULastProfileSubmissionDate"
        ]
        
        for key in sparkleDefaults {
            UserDefaults.standard.removeObject(forKey: key)
        }
        
        logger.info("Sparkle user defaults cleared")
    }
}

// MARK: - SparkleViewModel

@MainActor
@available(macOS 10.15, *)
@Observable
public final class SparkleViewModel {
    public var canCheckForUpdates = false
    public var isCheckingForUpdates = false
    public var automaticallyChecksForUpdates = true
    public var automaticallyDownloadsUpdates = true
    public var updateCheckInterval: TimeInterval = 86400
    public var lastUpdateCheckDate: Date?
    public var updateChannel: UpdateChannel = .stable
    
    private let updaterManager = SparkleUpdaterManager.shared
    
    public init() {
        // Sync with actual Sparkle settings
        if let updater = updaterManager.updaterController?.updater {
            automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
            updateCheckInterval = updater.updateCheckInterval
            lastUpdateCheckDate = updater.lastUpdateCheckDate
            canCheckForUpdates = updater.canCheckForUpdates
        }
        
        // Load saved update channel
        let savedChannel = UserDefaults.standard.string(forKey: "updateChannel") ?? UpdateChannel.stable.rawValue
        if let channel = UpdateChannel(rawValue: savedChannel) {
            updateChannel = channel
        }
    }
    
    public func checkForUpdates() {
        updaterManager.checkForUpdates()
    }
    
    public func setUpdateChannel(_ channel: UpdateChannel) {
        updateChannel = channel
        updaterManager.setUpdateChannel(channel)
    }
}

// MARK: - ProcessInfo Extension

fileprivate extension ProcessInfo {
    var installedFromAppStore: Bool {
        // Check for App Store receipt
        let receiptURL = Bundle.main.appStoreReceiptURL
        return receiptURL?.lastPathComponent == "receipt" && FileManager.default.fileExists(atPath: receiptURL?.path ?? "")
    }
}