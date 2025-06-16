import SwiftUI

/// Advanced settings tab for power user options
struct AdvancedSettingsView: View {
    @AppStorage("debugMode")
    private var debugMode = false
    @AppStorage("cleanupOnStartup")
    private var cleanupOnStartup = true

    var body: some View {
        NavigationStack {
            Form {
                // Integration section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Install CLI Tool")
                            Spacer()
                            Button("Install 'vt' Command") {
                                installCLITool()
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("Install the 'vt' command line tool to /usr/local/bin for terminal access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Integration")
                        .font(.headline)
                }

                // Advanced section
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Clean up old sessions on startup", isOn: $cleanupOnStartup)
                        Text("Automatically remove terminated sessions when the app starts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Advanced")
                        .font(.headline)
                }

                // Debug section
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Debug mode", isOn: $debugMode)
                        Text("Enable additional logging and debugging features.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Debug")
                        .font(.headline)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Advanced Settings")
        }
    }

    private func installCLITool() {
        let installer = CLIInstaller()
        installer.installCLITool()
    }
}
