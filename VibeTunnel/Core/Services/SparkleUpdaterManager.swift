import os
import Sparkle
import UserNotifications

/// Manages the Sparkle auto-update framework integration for VibeTunnel.
///
/// SparkleUpdaterManager provides:
/// - Automatic update checking and installation
/// - Update UI presentation and user interaction
/// - Delegate callbacks for update lifecycle events
/// - Configuration of update channels and behavior
///
/// ## Features
/// - Automatic update checks based on configured interval
/// - Background downloads with gentle reminders
/// - Support for stable and pre-release update channels
/// - Critical update handling
/// - User notification integration
///
/// ## Usage
/// ```swift
/// let updaterManager = SparkleUpdaterManager()
/// updaterManager.checkForUpdates() // Manual check
/// updaterManager.setUpdateChannel(.preRelease) // Switch channels
/// ```
@MainActor
@Observable
public class SparkleUpdaterManager: NSObject, @preconcurrency SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate,
    @preconcurrency UNUserNotificationCenterDelegate
{
    // MARK: Initialization

    private nonisolated static let staticLogger = Logger(subsystem: "com.amantus.vibetunnel", category: "updates")

    /// Initializes the updater manager and configures Sparkle
    override init() {
        super.init()

        Self.staticLogger.info("Initializing SparkleUpdaterManager")

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
    private var updateChannelObserver: NSKeyValueObservation?

    // MARK: Methods

    /// Checks for updates immediately
    func checkForUpdates() {
        guard let updaterController else {
            logger.warning("Updater controller not available")
            return
        }

        logger.info("Manual update check initiated")
        updaterController.checkForUpdates(nil)
    }

    /// Configures the update channel and restarts if needed
    func setUpdateChannel(_ channel: UpdateChannel) {
        // Store the channel preference
        UserDefaults.standard.set(channel.rawValue, forKey: "updateChannel")

        logger.info("Update channel changed to: \(channel.rawValue)")

        // Force a new update check with the new feed
        checkForUpdates()
    }

    // MARK: Private

    /// Initializes the Sparkle updater controller
    private func initializeUpdaterController() {
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
        updater.updateCheckInterval = 60 * 60 // 1 hour
        updater.automaticallyDownloadsUpdates = true

        logger.info("""
            Updater configured:
            - Automatic checks: \(updater.automaticallyChecksForUpdates)
            - Check interval: \(updater.updateCheckInterval)s
            - Auto download: \(updater.automaticallyDownloadsUpdates)
        """)
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
        updateChannelObserver = UserDefaults.standard.observe(
            \.updateChannel,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.logger.info("Update channel changed via UserDefaults")
                self?.setUpdateChannel(UpdateChannel.current)
            }
        }
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
        logger.info("Starting background update check")
        lastUpdateCheckDate = Date()

        // Sparkle will check in the background when automaticallyChecksForUpdates is true
        // We don't need to explicitly call checkForUpdates for background checks
    }

    /// Shows a gentle reminder notification for available updates
    @MainActor
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
        gentleReminderTimer = Timer.scheduledTimer(withTimeInterval: 4 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.showGentleUpdateReminder()
            }
        }

        // Show first reminder after 1 hour
        DispatchQueue.main.asyncAfter(deadline: .now() + 3_600) { [weak self] in
            Task { @MainActor in
                self?.showGentleUpdateReminder()
            }
        }
    }

    // MARK: - SPUUpdaterDelegate

    @objc
    public nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Task { @MainActor in
            Self.staticLogger.info("Appcast loaded successfully: \(appcast.items.count) items")
        }
    }

    @objc
    public nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in
            Self.staticLogger.info("No update found: \(error.localizedDescription)")
        }
    }

    @objc
    public nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            Self.staticLogger.error("Update aborted with error: \(error.localizedDescription)")
        }
    }

    /// Provide the feed URL dynamically based on update channel
    @objc
    public nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateChannel.current.appcastURL.absoluteString
    }

    // MARK: - SPUStandardUserDriverDelegate

    @objc
    public nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            Self.staticLogger.info("""
                Will show update:
                - Version: \(update.displayVersionString)
                - Critical: \(update.isCriticalUpdate)
                - Stage: \(state.stage.rawValue)
            """)
        }
    }

    @objc
    public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        logger.info("User gave attention to update: \(update.displayVersionString)")
        updateInProgress = true

        // Cancel gentle reminders since user is aware
        gentleReminderTimer?.invalidate()
        gentleReminderTimer = nil
    }

    @objc
    public func standardUserDriverWillFinishUpdateSession() {
        logger.info("Update session finishing")
        updateInProgress = false
    }

    // MARK: - Background update handling

    @objc
    public func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        logger.info("Will download update: \(item.displayVersionString)")
    }

    @objc
    public func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        logger.info("Update downloaded: \(item.displayVersionString)")

        // For background downloads, schedule gentle reminders
        if !updateInProgress {
            scheduleGentleReminders()
        }
    }

    @objc
    public func updater(
        _ updater: SPUUpdater,
        willInstallUpdate item: SUAppcastItem
    ) {
        logger.info("Will install update: \(item.displayVersionString)")
    }

    // MARK: - UNUserNotificationCenterDelegate

    @objc
    public func userNotificationCenter(
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

    // MARK: - Cleanup

    deinit {
        // Note: updateChannelObserver will be invalidated automatically
        // Timer is cleaned up automatically when the object is deallocated
    }
}
