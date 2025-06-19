import Observation
import SwiftUI

/// View for displaying server console logs.
///
/// Provides a real-time console interface for monitoring server output with
/// filtering capabilities, auto-scroll functionality, and color-coded log levels.
/// Supports both Rust and Hummingbird server implementations.
struct ServerConsoleView: View {
    @State private var viewModel = ServerConsoleViewModel()
    @State private var autoScroll = true
    @State private var filterText = ""
    @State private var selectedLevel: ServerLogEntry.Level?

    var body: some View {
        VStack(spacing: 0) {
            // Header with controls
            HStack {
                // Filter controls
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Filter logs...", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)

                    Picker("Level", selection: $selectedLevel) {
                        Text("All").tag(nil as ServerLogEntry.Level?)
                        Text("Debug").tag(ServerLogEntry.Level.debug)
                        Text("Info").tag(ServerLogEntry.Level.info)
                        Text("Warning").tag(ServerLogEntry.Level.warning)
                        Text("Error").tag(ServerLogEntry.Level.error)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Spacer()

                // Controls
                HStack(spacing: 12) {
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.checkbox)

                    Button(action: viewModel.clearLogs) {
                        Label("Clear", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)

                    Button(action: viewModel.exportLogs) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    
                    // Show restart button for all modes except Swift/Hummingbird
                    if ServerManager.shared.serverMode != .hummingbird {
                        Divider()
                            .frame(height: 20)
                        
                        Button {
                            Task {
                                await ServerManager.shared.manualRestart()
                            }
                        } label: {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Console output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredLogs) { entry in
                            ServerLogEntryView(entry: entry)
                                .id(entry.id)
                        }

                        // Invisible anchor for auto-scrolling
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
                .font(.system(.body, design: .monospaced))
                .onChange(of: viewModel.logs.count) { _, _ in
                    if autoScroll {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 200)
        .onDisappear {
            viewModel.cleanup()
        }
    }

    private var filteredLogs: [ServerLogEntry] {
        viewModel.logs.filter { entry in
            // Level filter
            if let selectedLevel, entry.level != selectedLevel {
                return false
            }

            // Text filter
            if !filterText.isEmpty {
                return entry.message.localizedCaseInsensitiveContains(filterText)
            }

            return true
        }
    }
}

/// View for a single log entry
struct ServerLogEntryView: View {
    let entry: ServerLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            // Level indicator
            Circle()
                .fill(entry.level.color)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            // Source badge
            Text(entry.source.displayName)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(entry.source.color.opacity(0.2))
                .foregroundStyle(entry.source.color)
                .clipShape(Capsule())

            // Message
            Text(entry.message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(entry.level.textColor)
        }
        .padding(.vertical, 2)
    }
}

/// View model for the server console.
///
/// Manages the collection and filtering of server log entries,
/// subscribing to the server's log stream and maintaining a
/// bounded collection of recent logs.
@MainActor
@Observable
class ServerConsoleViewModel {
    private(set) var logs: [ServerLogEntry] = []

    private var logTask: Task<Void, Never>?
    private let maxLogs = 1_000

    init() {
        // Subscribe to server logs using async stream
        logTask = Task { [weak self] in
            for await entry in ServerManager.shared.logStream {
                self?.addLog(entry)
            }
        }
    }

    func cleanup() {
        logTask?.cancel()
    }

    private func addLog(_ entry: ServerLogEntry) {
        logs.append(entry)

        // Trim old logs if needed
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func exportLogs() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let logText = logs.map { entry in
            let timestamp = dateFormatter.string(from: entry.timestamp)
            let level = String(describing: entry.level).uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
            let source = entry.source.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)
            return "[\(timestamp)] [\(level)] [\(source)] \(entry.message)"
        }
        .joined(separator: "\n")

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "vibetunnel-server-logs.txt"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            try? logText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Extensions

extension ServerLogEntry: Identifiable {
    var id: String {
        "\(timestamp.timeIntervalSince1970)-\(message.hashValue)"
    }
}

extension ServerLogEntry.Level {
    var color: Color {
        switch self {
        case .debug: .gray
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    var textColor: Color {
        switch self {
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        }
    }
}

extension ServerMode {
    var color: Color {
        switch self {
        case .hummingbird: .blue
        case .rust: .orange
        case .go: .cyan
        }
    }
}
