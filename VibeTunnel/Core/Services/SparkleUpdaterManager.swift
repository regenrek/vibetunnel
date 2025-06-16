import Foundation
import Observation
import os.log
import Sparkle
import UserNotifications

/// SparkleUpdaterManager with automatic update downloads enabled
@available(macOS 10.15, *)
@MainActor
public final class SparkleUpdaterManager: NSObject, SPUUpdaterDelegate {
    public static let shared = SparkleUpdaterManager()

    fileprivate var updaterController: SPUStandardUpdaterController?
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VibeTunnel",
        category: "SparkleUpdater"
    )

    override public init() {
        super.init()

        // Check if installed from App Store
        if ProcessInfo.processInfo.installedFromAppStore {
            logger.info("App installed from App Store, skipping Sparkle initialization")
            return
        }

        // Initialize Sparkle with standard configuration
        #if DEBUG
        // In debug mode, don't start the updater automatically
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        #else
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        #endif

        // Configure automatic updates
        if let updater = updaterController?.updater {
            #if DEBUG
            // Disable automatic checks in debug builds
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            logger.info("Sparkle updater initialized in DEBUG mode - automatic updates disabled")
            #else
            // Enable automatic checking for updates
            updater.automaticallyChecksForUpdates = true

            // Enable automatic downloading of updates
            updater.automaticallyDownloadsUpdates = true

            // Set update check interval to 24 hours
            updater.updateCheckInterval = 86_400

            logger.info("Sparkle updater initialized successfully with automatic downloads enabled")
            
            // Start the updater if it wasn't started during initialization
            if !updaterController!.startedUpdater {
                updaterController!.updater.startUpdater()
            }
            #endif
            
            // Note: feedURL configuration happens through delegate methods
        }
    }

    public func setUpdateChannel(_ channel: UpdateChannel) {
        // Save the channel preference
        UserDefaults.standard.set(channel.rawValue, forKey: "updateChannel")
        logger.info("Update channel set to: \(channel.rawValue)")
        
        // The actual feed URL will be provided by the delegate method
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

// MARK: - SPUUpdaterDelegate

extension SparkleUpdaterManager {
    nonisolated public func updater(_ updater: SPUUpdater, mayPerformUpdateCheck updateCheck: SPUUpdateCheck) throws {
        // Allow update checks by default - not throwing an error means the check is allowed
        // We could add logic here to prevent checks during certain conditions
    }
    
    nonisolated public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // Get the current update channel from UserDefaults
        if let savedChannel = UserDefaults.standard.string(forKey: "updateChannel"),
           let channel = UpdateChannel(rawValue: savedChannel) {
            return channel.includesPreReleases ? Set(["", "prerelease"]) : Set([""])
        }
        return Set([""]) // Default to stable channel only
    }
    
    nonisolated public func feedURLString(for updater: SPUUpdater) -> String? {
        // Provide the appropriate feed URL based on the current update channel
        if let savedChannel = UserDefaults.standard.string(forKey: "updateChannel"),
           let channel = UpdateChannel(rawValue: savedChannel) {
            return channel.appcastURL.absoluteString
        }
        return UpdateChannel.defaultChannel.appcastURL.absoluteString
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
    public var updateCheckInterval: TimeInterval = 86_400
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
        if let savedChannel = UserDefaults.standard.string(forKey: "updateChannel"),
           let channel = UpdateChannel(rawValue: savedChannel) {
            updateChannel = channel
        } else {
            updateChannel = UpdateChannel.stable
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

extension ProcessInfo {
    fileprivate var installedFromAppStore: Bool {
        // Check for App Store receipt
        let receiptURL = Bundle.main.appStoreReceiptURL
        return receiptURL?.lastPathComponent == "receipt" && FileManager.default
            .fileExists(atPath: receiptURL?.path ?? "")
    }
}
