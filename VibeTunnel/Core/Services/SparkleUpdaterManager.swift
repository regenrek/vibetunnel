import os
#if canImport(Sparkle)
import Sparkle
#endif
import UserNotifications

#if canImport(Sparkle)

/// Manages the Sparkle auto-update framework integration for VibeTunnel.
///
/// SparkleUpdaterManager provides:
/// - Automatic update checking and installation
/// - Update UI presentation and user interaction
/// - Delegate callbacks for update lifecycle events
/// - Configuration of update channels and behavior
///
/// This manager wraps Sparkle's functionality to provide a clean
/// interface for the rest of the application while handling all
/// update-related delegate callbacks and UI presentation.
@MainActor
@Observable
public class SparkleUpdaterManager: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate,
    UNUserNotificationCenterDelegate {
    // MARK: - Static Logger for nonisolated methods
    
    private nonisolated static let staticLogger = Logger(subsystem: "com.amantus.vibetunnel", category: "updates")
    
    // MARK: Lifecycle
    
    override init() {
        super.init()
        
        // Skip Sparkle initialization in test environment to avoid dialogs
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            Self.staticLogger.info("SparkleUpdaterManager initialized in test mode - Sparkle disabled")
            return
        }
        
        // Initialize the updater controller
        initializeUpdaterController()
        
        // Set up notification center for gentle reminders
        setupNotificationCenter()
        
        // Listen for update channel changes
        setupUpdateChannelListener()
        Self.staticLogger
            .info("SparkleUpdaterManager initialized. Updater controller initialization completed.")
        
        // Only schedule startup update check in release builds
        #if !DEBUG
            scheduleStartupUpdateCheck()
        #endif
    }
    
    // MARK: Public
    
    // MARK: Properties
    
    /// The shared singleton instance of the updater manager
    static let shared = SparkleUpdaterManager()
    
    /// The Sparkle updater controller instance
    private(set) var updaterController: SPUStandardUpdaterController?
    
    /// The logger instance for update events
    private let logger = Logger(subsystem: "com.amantus.vibetunnel", category: "updates")
    
    // Track update state
    private var updateInProgress = false
    private var lastUpdateCheckDate: Date?
    private var gentleReminderTimer: Timer?
    
    // MARK: Methods
    
    /// Checks for updates immediately
    func checkForUpdates() {
        guard let updaterController = updaterController else {
            logger.warning("Updater controller not available")
            return
        }
        
        logger.info("Manual update check initiated")
        updaterController.checkForUpdates(nil)
    }
    
    /// Configures the update channel and restarts if needed
    func setUpdateChannel(_ channel: UpdateChannel) {
        guard let updater = updaterController?.updater else {
            logger.error("Updater not available")
            return
        }
        
        let oldFeedURL = updater.feedURL
        let newFeedURL = channel.feedURL
        
        guard oldFeedURL != newFeedURL else {
            logger.info("Update channel unchanged")
            return
        }
        
        logger.info("Changing update channel from \(oldFeedURL?.absoluteString ?? "nil") to \(newFeedURL)")
        
        // Update the feed URL
        updater.feedURL = newFeedURL
        
        // Force a new update check with the new feed
        checkForUpdates()
    }
    
    // MARK: Private
    
    /// Initializes the Sparkle updater controller
    private func initializeUpdaterController() {
        do {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            
            guard let updater = updaterController?.updater else {
                logger.error("Failed to get updater from controller")
                return
            }
            
            // Configure updater settings
            updater.automaticallyChecksForUpdates = true
            updater.updateCheckInterval = 60 * 60  // 1 hour
            updater.automaticallyDownloadsUpdates = true
            
            // Set the feed URL based on current channel
            updater.feedURL = UpdateChannel.current.feedURL
            
            logger.info("""
                Updater configured:
                - Automatic checks: \(updater.automaticallyChecksForUpdates)
                - Check interval: \(updater.updateCheckInterval)s
                - Auto download: \(updater.automaticallyDownloadsUpdates)
                - Feed URL: \(updater.feedURL?.absoluteString ?? "none")
            """)
            
        } catch {
            logger.error("Failed to initialize updater controller: \(error.localizedDescription)")
        }
    }
    
    /// Sets up the notification center for gentle reminders
    private func setupNotificationCenter() {
        UNUserNotificationCenter.current().delegate = self
        
        // Request notification permissions
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
                logger.info("Notification permission granted: \(granted)")
            } catch {
                logger.error("Failed to request notification permission: \(error.localizedDescription)")
            }
        }
    }
    
    /// Sets up a listener for update channel changes
    private func setupUpdateChannelListener() {
        // Listen for channel changes via UserDefaults
        UserDefaults.standard.addObserver(
            self,
            forKeyPath: "updateChannel",
            options: [.new],
            context: nil
        )
    }
    
    /// Schedules an update check after app startup
    private func scheduleStartupUpdateCheck() {
        // Check for updates 5 seconds after app launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdatesInBackground()
        }
    }
    
    /// Checks for updates in the background without UI
    private func checkForUpdatesInBackground() {
        guard let updater = updaterController?.updater else { return }
        
        logger.info("Starting background update check")
        lastUpdateCheckDate = Date()
        
        // Sparkle will check in the background when automaticallyChecksForUpdates is true
        // We don't need to explicitly call checkForUpdates for background checks
    }
    
    /// Shows a gentle reminder notification for available updates
    private func showGentleUpdateReminder() {
        let content = UNMutableNotificationContent()
        content.title = "Update Available"
        content.body = "A new version of VibeTunnel is ready to install. Click to update now."
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "update-reminder",
            content: content,
            trigger: nil
        )
        
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                logger.info("Gentle update reminder shown")
            } catch {
                logger.error("Failed to show update reminder: \(error.localizedDescription)")
            }
        }
    }
    
    /// Schedules periodic gentle reminders for available updates
    private func scheduleGentleReminders() {
        // Cancel any existing timer
        gentleReminderTimer?.invalidate()
        
        // Schedule reminders every 4 hours
        gentleReminderTimer = Timer.scheduledTimer(withTimeInterval: 4 * 60 * 60, repeats: true) {
            [weak self] _ in
            self?.showGentleUpdateReminder()
        }
        
        // Show first reminder after 1 hour
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { [weak self] in
            self?.showGentleUpdateReminder()
        }
    }
    
    // MARK: - SPUUpdaterDelegate
    
    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Self.staticLogger.info("Appcast loaded successfully: \(appcast.items.count) items")
    }
    
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Self.staticLogger.info("No update found: \(error.localizedDescription)")
    }
    
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Self.staticLogger.error("Update aborted with error: \(error.localizedDescription)")
    }
    
    // MARK: - SPUStandardUserDriverDelegate
    
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Self.staticLogger.info("""
            Will show update:
            - Version: \(update.displayVersionString ?? "unknown")
            - Critical: \(update.isCriticalUpdate)
            - Stage: \(state.stage.rawValue)
        """)
    }
    
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        logger.info("User gave attention to update: \(update.displayVersionString ?? "unknown")")
        updateInProgress = true
        
        // Cancel gentle reminders since user is aware
        gentleReminderTimer?.invalidate()
        gentleReminderTimer = nil
    }
    
    func standardUserDriverWillFinishUpdateSession() {
        logger.info("Update session finishing")
        updateInProgress = false
    }
    
    // MARK: - Background update handling
    
    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        logger.info("Will download update: \(item.displayVersionString ?? "unknown")")
    }
    
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        logger.info("Update downloaded: \(item.displayVersionString ?? "unknown")")
        
        // For background downloads, schedule gentle reminders
        if !updateInProgress {
            scheduleGentleReminders()
        }
    }
    
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdate item: SUAppcastItem
    ) {
        logger.info("Will install update: \(item.displayVersionString ?? "unknown")")
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == "update-reminder" {
            logger.info("User clicked update reminder notification")
            
            // Trigger the update UI
            checkForUpdates()
        }
        
        completionHandler()
    }
    
    // MARK: - KVO
    
    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "updateChannel" {
            logger.info("Update channel changed via UserDefaults")
            setUpdateChannel(UpdateChannel.current)
        }
    }
    
    // MARK: - Cleanup
    
    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: "updateChannel")
        gentleReminderTimer?.invalidate()
    }
}

#else

// MARK: - Stub implementation when Sparkle is not available

/// Stub implementation of SparkleUpdaterManager when Sparkle framework is not available
@MainActor
@Observable
public class SparkleUpdaterManager: NSObject {
    static let shared = SparkleUpdaterManager()
    
    private let logger = Logger(subsystem: "com.amantus.vibetunnel", category: "updates")
    
    override init() {
        super.init()
        logger.warning("SparkleUpdaterManager initialized without Sparkle framework")
    }
    
    func checkForUpdates() {
        logger.warning("checkForUpdates called but Sparkle framework is not available")
    }
    
    func setUpdateChannel(_ channel: UpdateChannel) {
        logger.warning("setUpdateChannel called but Sparkle framework is not available")
    }
}

#endif