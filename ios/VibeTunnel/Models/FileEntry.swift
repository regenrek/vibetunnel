import Foundation

struct FileEntry: Codable, Identifiable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64
    let mode: String
    let modTime: Date

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case isDir = "is_dir"
        case size
        case mode
        case modTime = "mod_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        isDir = try container.decode(Bool.self, forKey: .isDir)
        size = try container.decode(Int64.self, forKey: .size)
        mode = try container.decode(String.self, forKey: .mode)

        // Decode mod_time string as Date
        let modTimeString = try container.decode(String.self, forKey: .modTime)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: modTimeString) {
            modTime = date
        } else {
            // Fallback without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: modTimeString) {
                modTime = date
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .modTime,
                    in: container,
                    debugDescription: "Invalid date format"
                )
            }
        }
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: size)
    }

    var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: modTime, relativeTo: Date())
    }
}

struct DirectoryListing: Codable {
    let absolutePath: String
    let files: [FileEntry]
}
