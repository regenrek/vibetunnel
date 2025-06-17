import Foundation
import AppKit
import OSLog

/// Safely executes AppleScript commands with proper error handling and crash prevention.
///
/// This class ensures AppleScript execution is deferred to the next run loop to avoid
/// crashes when called directly from SwiftUI actions. It provides centralized error
/// handling and logging for all AppleScript operations in the app.
@MainActor
final class AppleScriptExecutor {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VibeTunnel",
        category: "AppleScriptExecutor"
    )
    
    /// Shared instance for app-wide AppleScript execution
    static let shared = AppleScriptExecutor()
    
    private init() {}
    
    /// Executes an AppleScript synchronously with proper error handling.
    ///
    /// This method defers the actual AppleScript execution to the next run loop
    /// to prevent crashes when called from SwiftUI actions.
    ///
    /// - Parameter script: The AppleScript source code to execute
    /// - Throws: `AppleScriptError` if execution fails
    /// - Returns: The result of the AppleScript execution, if any
    @discardableResult
    func execute(_ script: String) throws -> NSAppleEventDescriptor? {
        // Create a semaphore to wait for async execution
        let semaphore = DispatchSemaphore(value: 0)
        var executionResult: NSAppleEventDescriptor?
        var executionError: Error?
        
        // Defer AppleScript execution to next run loop to avoid crashes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            var error: NSDictionary?
            if let scriptObject = NSAppleScript(source: script) {
                executionResult = scriptObject.executeAndReturnError(&error)
                
                if let error = error {
                    let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                    let errorNumber = error["NSAppleScriptErrorNumber"] as? Int
                    
                    // Log all error details
                    self.logger.error("AppleScript execution failed:")
                    self.logger.error("  Error code: \(errorNumber ?? -1)")
                    self.logger.error("  Error message: \(errorMessage)")
                    if let errorRange = error["NSAppleScriptErrorRange"] as? NSRange {
                        self.logger.error("  Error range: \(errorRange)")
                    }
                    if let errorBriefMessage = error["NSAppleScriptErrorBriefMessage"] as? String {
                        self.logger.error("  Brief message: \(errorBriefMessage)")
                    }
                    
                    // Create appropriate error
                    executionError = AppleScriptError.executionFailed(
                        message: errorMessage,
                        errorCode: errorNumber
                    )
                } else {
                    // Log successful execution
                    self.logger.debug("AppleScript executed successfully")
                }
            } else {
                self.logger.error("Failed to create NSAppleScript object")
                executionError = AppleScriptError.scriptCreationFailed
            }
            semaphore.signal()
        }
        
        // Wait for execution to complete with timeout
        let waitResult = semaphore.wait(timeout: .now() + 5.0)
        
        if waitResult == .timedOut {
            logger.error("AppleScript execution timed out after 5 seconds")
            throw AppleScriptError.timeout
        }
        
        if let error = executionError {
            throw error
        }
        
        return executionResult
    }
    
    /// Executes an AppleScript asynchronously.
    ///
    /// This method is useful when you don't need to wait for the result
    /// and want to avoid blocking the current thread.
    ///
    /// - Parameter script: The AppleScript source code to execute
    /// - Returns: The result of the AppleScript execution, if any
    func executeAsync(_ script: String) async throws -> NSAppleEventDescriptor? {
        return try await withCheckedThrowingContinuation { continuation in
            // Defer execution to next run loop to avoid crashes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                var error: NSDictionary?
                if let scriptObject = NSAppleScript(source: script) {
                    let result = scriptObject.executeAndReturnError(&error)
                    
                    if let error = error {
                        let errorMessage = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                        let errorNumber = error["NSAppleScriptErrorNumber"] as? Int
                        
                        self.logger.error("AppleScript execution failed: \(errorMessage) (code: \(errorNumber ?? -1))")
                        
                        continuation.resume(throwing: AppleScriptError.executionFailed(
                            message: errorMessage,
                            errorCode: errorNumber
                        ))
                    } else {
                        self.logger.debug("AppleScript executed successfully")
                        continuation.resume(returning: result)
                    }
                } else {
                    self.logger.error("Failed to create NSAppleScript object")
                    continuation.resume(throwing: AppleScriptError.scriptCreationFailed)
                }
            }
        }
    }
    
    /// Checks if AppleScript permission is granted by executing a simple test script.
    ///
    /// - Returns: true if permission is granted, false otherwise
    func checkPermission() async -> Bool {
        let testScript = """
            tell application "System Events"
                return name of first process whose frontmost is true
            end tell
        """
        
        do {
            _ = try await executeAsync(testScript)
            return true
        } catch let error as AppleScriptError {
            if error.isPermissionError {
                logger.info("AppleScript permission check: Permission denied")
                return false
            }
            logger.error("AppleScript permission check failed with error: \(error)")
            return false
        } catch {
            logger.error("AppleScript permission check failed with unexpected error: \(error)")
            return false
        }
    }
}

/// Errors that can occur during AppleScript execution.
enum AppleScriptError: LocalizedError {
    case scriptCreationFailed
    case executionFailed(message: String, errorCode: Int?)
    case permissionDenied
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .scriptCreationFailed:
            return "Failed to create AppleScript object"
        case .executionFailed(let message, let errorCode):
            if let code = errorCode {
                return "AppleScript error \(code): \(message)"
            } else {
                return "AppleScript error: \(message)"
            }
        case .permissionDenied:
            return "AppleScript permission denied. Please grant permission in System Settings."
        case .timeout:
            return "AppleScript execution timed out"
        }
    }
    
    var failureReason: String? {
        switch self {
        case .permissionDenied:
            return "VibeTunnel needs Automation permission to control other applications."
        case .executionFailed(_, let errorCode):
            if let code = errorCode {
                switch code {
                case -1743:
                    return "User permission is required to control other applications."
                case -1728:
                    return "The application is not running or cannot be controlled."
                case -1708:
                    return "The event was not handled by the target application."
                default:
                    return nil
                }
            }
            return nil
        default:
            return nil
        }
    }
    
    /// Checks if this error represents a permission denial
    var isPermissionError: Bool {
        switch self {
        case .permissionDenied:
            return true
        case .executionFailed(_, let errorCode):
            return errorCode == -1743
        default:
            return false
        }
    }
    
    /// Converts this error to a TerminalLauncherError if appropriate
    func toTerminalLauncherError() -> TerminalLauncherError {
        if isPermissionError {
            return .appleScriptPermissionDenied
        }
        
        switch self {
        case .executionFailed(let message, let errorCode):
            return .appleScriptExecutionFailed(message, errorCode: errorCode)
        default:
            return .appleScriptExecutionFailed(self.localizedDescription, errorCode: nil)
        }
    }
}