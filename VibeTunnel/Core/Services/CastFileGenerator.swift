import Foundation
import Logging

/// Generates Asciinema cast v2 format files from terminal session output.
///
/// Creates recordings of terminal sessions in the Asciinema cast format,
/// which can be played back using Asciinema players. Handles timing information,
/// terminal dimensions, and output/input event recording.
///
/// Format specification: https://docs.asciinema.org/manual/asciicast/v2/
struct CastFileGenerator {
    private let logger = Logger(label: "VibeTunnel.CastFileGenerator")

    /// Header structure for Asciinema cast v2 format.
    ///
    /// Contains metadata about the terminal recording including
    /// dimensions, timing, and environment information.
    struct CastHeader: Codable {
        let version: Int = 2
        let width: Int
        let height: Int
        let timestamp: TimeInterval?
        let duration: TimeInterval?
        let idleTimeLimit: TimeInterval?
        let command: String?
        let title: String?
        let env: [String: String]?

        enum CodingKeys: String, CodingKey {
            case version
            case width
            case height
            case timestamp
            case duration
            case idleTimeLimit = "idle_time_limit"
            case command
            case title
            case env
        }
    }

    /// Represents a single event in the Asciinema recording.
    ///
    /// Each event captures either terminal output or input at a specific timestamp.
    struct CastEvent {
        let time: TimeInterval
        let eventType: String
        let data: String
    }

    /// Generate a cast file from a session's stream-out file
    func generateCastFile(
        sessionId: String,
        streamOutPath: String,
        width: Int = 80,
        height: Int = 24,
        title: String? = nil,
        command: String? = nil
    )
        throws -> Data
    {
        guard FileManager.default.fileExists(atPath: streamOutPath) else {
            throw CastFileError.fileNotFound(streamOutPath)
        }

        let content = try String(contentsOfFile: streamOutPath, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var outputData = Data()
        var events: [CastEvent] = []
        var startTime: Date?
        var sessionWidth = width
        var sessionHeight = height

        // Parse the stream-out file
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data)
            else {
                continue
            }

            // Check if it's a header
            if let dict = parsed as? [String: Any],
               dict["version"] is Int,
               let width = dict["width"] as? Int,
               let height = dict["height"] as? Int
            {
                sessionWidth = width
                sessionHeight = height
                continue
            }

            // Parse as event [timestamp, type, data]
            if let array = parsed as? [Any],
               array.count >= 3,
               let timestamp = array[0] as? TimeInterval,
               let eventType = array[1] as? String,
               let eventData = array[2] as? String
            {
                if startTime == nil {
                    startTime = Date()
                }

                events.append(CastEvent(
                    time: timestamp,
                    eventType: eventType,
                    data: eventData
                ))
            }
        }

        // Generate header
        let header = CastHeader(
            width: sessionWidth,
            height: sessionHeight,
            timestamp: startTime?.timeIntervalSince1970,
            duration: events.last?.time,
            idleTimeLimit: nil,
            command: command,
            title: title,
            env: nil
        )

        // Write header as first line
        let headerData = try JSONEncoder().encode(header)
        outputData.append(headerData)
        outputData.append(Data("\n".utf8))

        // Write events
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes

        for event in events {
            let eventArray: [Any] = [event.time, event.eventType, event.data]
            let eventData = try JSONSerialization.data(withJSONObject: eventArray)
            outputData.append(eventData)
            outputData.append(Data("\n".utf8))
        }

        return outputData
    }

    /// Generate a cast file and save it to disk
    func saveCastFile(
        sessionId: String,
        streamOutPath: String,
        outputPath: String,
        width: Int = 80,
        height: Int = 24,
        title: String? = nil,
        command: String? = nil
    )
        throws
    {
        let castData = try generateCastFile(
            sessionId: sessionId,
            streamOutPath: streamOutPath,
            width: width,
            height: height,
            title: title,
            command: command
        )

        try castData.write(to: URL(fileURLWithPath: outputPath))
        logger.info("Cast file saved to: \(outputPath)")
    }

    /// Generate a live cast stream that can be consumed in real-time
    func streamCastEvents(
        from streamOutPath: String,
        startTime: Date
    )
        -> AsyncStream<Data>
    {
        AsyncStream { continuation in
            Task {
                let fileDescriptor = open(streamOutPath, O_RDONLY)
                guard fileDescriptor >= 0 else {
                    logger.error("Failed to open file for streaming: \(streamOutPath)")
                    continuation.finish()
                    return
                }

                defer {
                    close(fileDescriptor)
                    continuation.finish()
                }

                var lastReadPosition: off_t = 0

                while !Task.isCancelled {
                    let currentPosition = lseek(fileDescriptor, 0, SEEK_END)
                    let bytesToRead = currentPosition - lastReadPosition

                    if bytesToRead > 0 {
                        lseek(fileDescriptor, lastReadPosition, SEEK_SET)

                        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(bytesToRead) + 1)
                        defer { buffer.deallocate() }

                        let bytesRead = read(fileDescriptor, buffer, Int(bytesToRead))
                        if bytesRead > 0 {
                            let data = Data(bytes: buffer, count: bytesRead)
                            if let content = String(data: data, encoding: .utf8) {
                                let lines = content.components(separatedBy: .newlines)
                                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                                    if let eventData = processLineToAsciinemaEvent(
                                        line: line,
                                        startTime: startTime
                                    ) {
                                        continuation.yield(eventData)
                                    }
                                }
                            }
                            lastReadPosition = currentPosition
                        }
                    }

                    // Sleep briefly before checking again
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    private func processLineToAsciinemaEvent(line: String, startTime: Date) -> Data? {
        guard let data = line.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any],
              parsed.count >= 3,
              let eventType = parsed[1] as? String,
              let eventData = parsed[2] as? String
        else {
            return nil
        }

        let currentTime = Date()
        let timestamp = currentTime.timeIntervalSince(startTime)

        let event: [Any] = [timestamp, eventType, eventData]
        return try? JSONSerialization.data(withJSONObject: event)
    }
}

enum CastFileError: LocalizedError {
    case fileNotFound(String)
    case invalidFormat
    case encodingError

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            "Stream file not found: \(path)"
        case .invalidFormat:
            "Invalid stream file format"
        case .encodingError:
            "Failed to encode cast file"
        }
    }
}
