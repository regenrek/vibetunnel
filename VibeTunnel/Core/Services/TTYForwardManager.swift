import Foundation
import os.log

/// Manages interactions with the tty-fwd command-line tool
@MainActor
final class TTYForwardManager {
    static let shared = TTYForwardManager()
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VibeTunnel", category: "TTYForwardManager")
    
    private init() {}
    
    /// Returns the URL to the bundled tty-fwd executable
    var ttyForwardExecutableURL: URL? {
        return Bundle.main.url(forResource: "tty-fwd", withExtension: nil)
    }
    
    /// Executes the tty-fwd binary with the specified arguments
    /// - Parameters:
    ///   - arguments: Command line arguments to pass to tty-fwd
    ///   - completion: Completion handler with the process result
    func executeTTYForward(with arguments: [String], completion: @escaping (Result<Process, Error>) -> Void) {
        guard let executableURL = ttyForwardExecutableURL else {
            completion(.failure(TTYForwardError.executableNotFound))
            return
        }
        
        // Verify the executable exists and is executable
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            completion(.failure(TTYForwardError.executableNotFound))
            return
        }
        
        // Check if executable permission is set
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            logger.error("tty-fwd binary is not executable at path: \(executableURL.path)")
            completion(.failure(TTYForwardError.notExecutable))
            return
        }
        
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        
        // Set up pipes for stdout and stderr
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Log the command being executed
        logger.info("Executing tty-fwd with arguments: \(arguments.joined(separator: " "))")
        
        do {
            try process.run()
            completion(.success(process))
        } catch {
            logger.error("Failed to execute tty-fwd: \(error.localizedDescription)")
            completion(.failure(error))
        }
    }
    
    /// Creates a new tty-fwd process configured but not yet started
    /// - Parameter arguments: Command line arguments to pass to tty-fwd
    /// - Returns: A configured Process instance or nil if the executable is not found
    func createTTYForwardProcess(with arguments: [String]) -> Process? {
        guard let executableURL = ttyForwardExecutableURL else {
            logger.error("tty-fwd executable not found in bundle")
            return nil
        }
        
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        
        return process
    }
}

/// Errors that can occur when working with the tty-fwd binary
enum TTYForwardError: LocalizedError {
    case executableNotFound
    case notExecutable
    
    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "tty-fwd executable not found in application bundle"
        case .notExecutable:
            return "tty-fwd binary does not have executable permissions"
        }
    }
}