import AppKit
import Foundation
import Sparkle
import os.log

/// Custom user driver for Sparkle updates that implements gentle reminders
@MainActor
public final class SparkleUserDriver: NSObject, SPUUserDriverDelegate {
    private let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VibeTunnel",
        category: "SparkleUserDriver"
    )
    
    private var updateItem: SUAppcastItem?
    private var userDriver: SPUUserDriver?
    private var reminderTimer: Timer?
    private var lastReminderDate: Date?
    
    // Configuration
    private let initialReminderDelay: TimeInterval = 60 * 60 * 24 // 24 hours
    private let subsequentReminderInterval: TimeInterval = 60 * 60 * 24 * 3 // 3 days
    
    public override init() {
        super.init()
    }
    
    // MARK: - SPUUserDriverDelegate
    
    public func showCanCheck(forUpdates updater: SPUUpdater) {
        logger.info("User can check for updates")
    }
    
    public func showUpdatePermissionRequest(for updater: SPUUpdater, systemProfile: [String : Any], reply: @escaping (SPUUpdatePermissionResponse) -> Void) {
        // Show permission dialog
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Check for Updates Automatically?"
            alert.informativeText = "VibeTunnel can automatically check for updates. You can always check for updates manually from the menu."
            alert.addButton(withTitle: "Check Automatically")
            alert.addButton(withTitle: "Don't Check")
            
            let response = alert.runModal()
            
            reply(SPUUpdatePermissionResponse(
                automaticUpdateChecks: response == .alertFirstButtonReturn,
                sendSystemProfile: false
            ))
        }
    }
    
    public func showUserInitiatedUpdateCheck(completion updateCheckStatusCompletion: @escaping (SPUUserInitiatedCheckStatus) -> Void) {
        logger.info("User initiated update check")
        updateCheckStatusCompletion(.checkEnabled)
    }
    
    public func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUpdateState, reply: @escaping (SPUUpdateAlertChoice) -> Void) {
        logger.info("Update found: \(appcastItem.displayVersionString ?? "Unknown version")")
        
        // Store the update item for gentle reminders
        self.updateItem = appcastItem
        
        // Cancel any existing reminder timer
        reminderTimer?.invalidate()
        
        // Show immediate notification
        showUpdateNotification(appcastItem: appcastItem, state: state, reply: reply, isReminder: false)
        
        // Schedule the first gentle reminder
        scheduleGentleReminder(appcastItem: appcastItem, state: state)
    }
    
    public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Handle release notes display if needed
        logger.info("Showing update release notes")
    }
    
    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        logger.error("Failed to download release notes: \(error)")
    }
    
    public func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        logger.info("No updates found")
        acknowledgement()
    }
    
    public func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        logger.error("Updater error: \(error)")
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Update Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            
            acknowledgement()
        }
    }
    
    public func showDownloadInitiated(cancellation: @escaping () -> Void) {
        logger.info("Download initiated")
        // Could show a download progress indicator here
    }
    
    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        logger.info("Download expected content length: \(expectedContentLength)")
    }
    
    public func showDownloadDidReceiveData(ofLength length: UInt64) {
        // Update download progress if showing progress UI
    }
    
    public func showDownloadDidStartExtractingUpdate() {
        logger.info("Extracting update")
    }
    
    public func showExtractionReceivedProgress(_ progress: Double) {
        // Update extraction progress if showing progress UI
    }
    
    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUpdateAlertChoice) -> Void) {
        logger.info("Ready to install and relaunch")
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Update Ready to Install"
            alert.informativeText = "VibeTunnel is ready to install the update and relaunch."
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Install Later")
            
            let response = alert.runModal()
            
            if response == .alertFirstButtonReturn {
                reply(.installUpdateChoice)
            } else {
                reply(.installLaterChoice)
            }
        }
    }
    
    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        logger.info("Installing update, application terminated: \(applicationTerminated)")
    }
    
    public func showSendingTerminationSignal() {
        logger.info("Sending termination signal")
    }
    
    public func showUpdateInstallationDidFinish(acknowledgement: @escaping () -> Void) {
        logger.info("Update installation finished")
        acknowledgement()
    }
    
    public func dismissUpdateInstallation() {
        logger.info("Dismissing update installation")
        
        // Cancel any pending reminders
        reminderTimer?.invalidate()
        reminderTimer = nil
        updateItem = nil
    }
    
    // MARK: - Gentle Reminders
    
    private func scheduleGentleReminder(appcastItem: SUAppcastItem, state: SPUUpdateState) {
        // Determine the delay for the next reminder
        let delay: TimeInterval
        if lastReminderDate == nil {
            // First reminder
            delay = initialReminderDelay
        } else {
            // Subsequent reminders
            delay = subsequentReminderInterval
        }
        
        logger.info("Scheduling gentle reminder in \(delay / 3600) hours")
        
        reminderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.showGentleReminder(appcastItem: appcastItem, state: state)
        }
    }
    
    private func showGentleReminder(appcastItem: SUAppcastItem, state: SPUUpdateState) {
        logger.info("Showing gentle reminder for update")
        
        lastReminderDate = Date()
        
        // Show the update notification as a reminder
        showUpdateNotification(appcastItem: appcastItem, state: state, reply: { [weak self] choice in
            if choice == .installUpdateChoice {
                // User chose to install, no more reminders needed
                self?.reminderTimer?.invalidate()
                self?.reminderTimer = nil
            } else {
                // Schedule the next reminder
                self?.scheduleGentleReminder(appcastItem: appcastItem, state: state)
            }
        }, isReminder: true)
    }
    
    private func showUpdateNotification(appcastItem: SUAppcastItem, state: SPUUpdateState, reply: @escaping (SPUUpdateAlertChoice) -> Void, isReminder: Bool) {
        DispatchQueue.main.async {
            // Create a more prominent alert for updates
            let alert = NSAlert()
            alert.messageText = isReminder ? "Update Reminder" : "Update Available"
            
            let versionString = appcastItem.displayVersionString ?? "new version"
            var informativeText = "VibeTunnel \(versionString) is available."
            
            if isReminder {
                informativeText += " You have a pending update ready to install."
            }
            
            if let releaseNotesURL = appcastItem.releaseNotesURL {
                informativeText += " Would you like to download it now?"
            }
            
            alert.informativeText = informativeText
            alert.alertStyle = .informational
            
            // Add buttons
            alert.addButton(withTitle: state.stage == .downloaded ? "Install Update" : "Download Update")
            alert.addButton(withTitle: "Skip This Version")
            alert.addButton(withTitle: "Remind Me Later")
            
            // Make the window more prominent
            if let window = alert.window {
                window.level = .floating
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            
            let response = alert.runModal()
            
            switch response {
            case .alertFirstButtonReturn:
                reply(.installUpdateChoice)
            case .alertSecondButtonReturn:
                reply(.skipThisVersionChoice)
            default:
                reply(.installLaterChoice)
            }
        }
    }
}