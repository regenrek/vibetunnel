import SwiftUI

/// Advanced settings tab for power user options
struct AdvancedSettingsView: View {
    @AppStorage("debugMode")
    private var debugMode = false
    @AppStorage("cleanupOnStartup")
    private var cleanupOnStartup = true
    @State private var cliInstaller = CLIInstaller()

    var body: some View {
        NavigationStack {
            Form {
                // Integration section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Install CLI Tool")
                            Spacer()
                            if cliInstaller.isInstalled {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("CLI tool is installed")
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Button("Install 'vt' Command") {
                                    Task {
                                        await cliInstaller.install()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(cliInstaller.isInstalling)
                            }
                        }
                        
                        if cliInstaller.isInstalling {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        
                        if let error = cliInstaller.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        } else if cliInstaller.isInstalled {
                            Text("The 'vt' command line tool is installed at /usr/local/bin/vt")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Install the 'vt' command line tool to /usr/local/bin for terminal access.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
        .onAppear {
            cliInstaller.checkInstallationStatus()
        }
    }
}
