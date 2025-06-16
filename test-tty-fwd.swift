#!/usr/bin/env swift

import Foundation

let ttyFwdPath =
    "/Users/steipete/Projects/vibetunnel/build/Build/Products/Debug/VibeTunnel.app/Contents/Resources/tty-fwd"
let controlPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibetunnel/control").path

print("Testing tty-fwd execution...")
print("Executable: \(ttyFwdPath)")
print("Control path: \(controlPath)")

// Check if executable exists
if FileManager.default.fileExists(atPath: ttyFwdPath) {
    print("✓ Executable exists")
} else {
    print("✗ Executable not found")
    exit(1)
}

// Check if control directory exists
if FileManager.default.fileExists(atPath: controlPath) {
    print("✓ Control directory exists")
} else {
    print("✗ Control directory not found")
}

// Try to run the process
let process = Process()
process.executableURL = URL(fileURLWithPath: ttyFwdPath)
process.arguments = ["--control-path", controlPath, "--list-sessions"]

let outputPipe = Pipe()
let errorPipe = Pipe()
process.standardOutput = outputPipe
process.standardError = errorPipe

do {
    print("\nStarting process...")
    try process.run()

    // Wait for it to complete
    process.waitUntilExit()

    let exitCode = process.terminationStatus
    print("Process terminated with exit code: \(exitCode)")

    // Read output
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
        print("Output: \(output)")
    }

    // Read error
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    if let error = String(data: errorData, encoding: .utf8), !error.isEmpty {
        print("Error: \(error)")
    }

} catch {
    print("Failed to run process: \(error)")
}
