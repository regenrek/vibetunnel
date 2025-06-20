import Foundation
import Observation

/// Cast file theme configuration
struct CastTheme: Codable {
    let foreground: String?
    let background: String?
    let palette: String?

    enum CodingKeys: String, CodingKey {
        case foreground = "fg"
        case background = "bg"
        case palette
    }
}

/// Asciinema cast v2 format support
struct CastFile: Codable {
    let version: Int
    let width: Int
    let height: Int
    let timestamp: TimeInterval?
    let title: String?
    let env: [String: String]?
    let theme: CastTheme?
}

struct CastEvent: Codable {
    let time: TimeInterval
    let type: String
    let data: String
}

/// Cast file recorder for terminal sessions
@MainActor
@Observable
class CastRecorder {
    var isRecording = false
    var recordingStartTime: Date?
    var events: [CastEvent] = []

    private let sessionId: String
    private let width: Int
    private let height: Int
    private var startTime: TimeInterval = 0

    init(sessionId: String, width: Int = 80, height: Int = 24) {
        self.sessionId = sessionId
        self.width = width
        self.height = height
    }

    func startRecording() {
        guard !isRecording else { return }

        isRecording = true
        recordingStartTime = Date()
        startTime = Date().timeIntervalSince1970
        events.removeAll()
    }

    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        recordingStartTime = nil
    }

    func recordOutput(_ data: String) {
        guard isRecording else { return }

        let currentTime = Date().timeIntervalSince1970
        let relativeTime = currentTime - startTime

        let event = CastEvent(
            time: relativeTime,
            type: "o", // output
            data: data
        )

        events.append(event)
    }

    func recordResize(cols: Int, rows: Int) {
        guard isRecording else { return }

        let currentTime = Date().timeIntervalSince1970
        let relativeTime = currentTime - startTime

        let resizeData = "\(cols)x\(rows)"
        let event = CastEvent(
            time: relativeTime,
            type: "r", // resize
            data: resizeData
        )

        events.append(event)
    }

    func exportCastFile() -> Data? {
        // Create header
        let header = CastFile(
            version: 2,
            width: width,
            height: height,
            timestamp: startTime,
            title: "VibeTunnel Recording - \(sessionId)",
            env: ["TERM": "xterm-256color", "SHELL": "/bin/zsh"],
            theme: nil
        )

        guard let headerData = try? JSONEncoder().encode(header),
              let headerString = String(data: headerData, encoding: .utf8)
        else {
            return nil
        }

        // Build the cast file content
        var castContent = headerString + "\n"

        // Add all events
        for event in events {
            // Cast events are encoded as arrays [time, type, data]
            let eventArray: [Any] = [event.time, event.type, event.data]

            if let jsonData = try? JSONSerialization.data(withJSONObject: eventArray),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                castContent += jsonString + "\n"
            }
        }

        return castContent.data(using: .utf8)
    }
}

/// Cast file player for imported recordings
class CastPlayer {
    let header: CastFile
    let events: [CastEvent]

    init?(data: Data) {
        guard let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }

        // Parse header (first line)
        guard let headerData = lines[0].data(using: .utf8),
              let header = try? JSONDecoder().decode(CastFile.self, from: headerData)
        else {
            return nil
        }

        // Parse events (remaining lines)
        var parsedEvents: [CastEvent] = []
        for index in 1..<lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: lineData) as? [Any],
                  array.count >= 3,
                  let time = array[0] as? Double,
                  let type = array[1] as? String,
                  let data = array[2] as? String
            else {
                continue
            }

            let event = CastEvent(time: time, type: type, data: data)
            parsedEvents.append(event)
        }

        self.header = header
        self.events = parsedEvents
    }

    var duration: TimeInterval {
        events.last?.time ?? 0
    }

    func play(onEvent: @escaping @Sendable (CastEvent) -> Void, completion: @escaping @Sendable () -> Void) {
        let eventsToPlay = self.events
        Task { @Sendable in
            for event in eventsToPlay {
                // Wait for the appropriate time
                if event.time > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(event.time * 1_000_000_000))
                }

                await MainActor.run {
                    onEvent(event)
                }
            }

            await MainActor.run {
                completion()
            }
        }
    }
}
