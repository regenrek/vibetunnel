import Foundation

struct TerminalSnapshot: Codable {
    let sessionId: String
    let header: AsciinemaHeader?
    let events: [AsciinemaEvent]

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case header
        case events
    }
}

struct AsciinemaEvent: Codable {
    let time: Double
    let type: EventType
    let data: String

    enum EventType: String, Codable {
        case output = "o"
        case input = "i"
        case resize = "r"
        case marker = "m"
    }
}

extension TerminalSnapshot {
    /// Get the last few lines of terminal output for preview
    var outputPreview: String {
        // Combine all output events
        let outputEvents = events.filter { $0.type == .output }
        let combinedOutput = outputEvents.map(\.data).joined()

        // Split into lines and get last few non-empty lines
        let lines = combinedOutput.components(separatedBy: .newlines)
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Take last 3-5 lines for preview
        let previewLines = Array(nonEmptyLines.suffix(4))
        return previewLines.joined(separator: "\n")
    }

    /// Get a cleaned version without ANSI escape codes (basic implementation)
    var cleanOutputPreview: String {
        let output = outputPreview
        // Remove common ANSI escape sequences (this is a simplified version)
        let pattern = "\\x1B\\[[0-9;]*[mGKHf]"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(location: 0, length: output.utf16.count)
        let cleaned = regex?.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: "") ?? output
        return cleaned
    }
}
