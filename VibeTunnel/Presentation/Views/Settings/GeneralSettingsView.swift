import SwiftUI

/// General settings tab for basic app preferences
struct GeneralSettingsView: View {
    @AppStorage("autostart")
    private var autostart = false
    @AppStorage("showNotifications")
    private var showNotifications = true
    @AppStorage("showInDock")
    private var showInDock = false
    @AppStorage("updateChannel")
    private var updateChannelRaw = UpdateChannel.stable.rawValue

    @State private var isCheckingForUpdates = false

    private let startupManager = StartupManager()

    var updateChannel: UpdateChannel {
        UpdateChannel(rawValue: updateChannelRaw) ?? .stable
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Launch at Login
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Launch at Login", isOn: launchAtLoginBinding)
                        Text("Automatically start VibeTunnel when you log into your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Application")
                        .font(.headline)
                }

                Section {
                    // Update Channel
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Update Channel")
                            Spacer()
                            Picker("", selection: updateChannelBinding) {
                                ForEach(UpdateChannel.allCases) { channel in
                                    Text(channel.displayName).tag(channel)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        Text(updateChannel.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Check for Updates
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Check for Updates")
                            Text("Check for new versions of VibeTunnel")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Check Now") {
                            checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isCheckingForUpdates)
                    }
                } header: {
                    Text("Updates")
                        .font(.headline)
                }

                Section {
                    // Show in Dock
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show in Dock", isOn: showInDockBinding)
                        Text("Show VibeTunnel icon in the Dock.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Appearance")
                        .font(.headline)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("General Settings")
        }
        .task {
            // Sync launch at login status
            autostart = startupManager.isLaunchAtLoginEnabled
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { autostart },
            set: { newValue in
                autostart = newValue
                startupManager.setLaunchAtLogin(enabled: newValue)
            }
        )
    }

    private var showInDockBinding: Binding<Bool> {
        Binding(
            get: { showInDock },
            set: { newValue in
                showInDock = newValue
                NSApp.setActivationPolicy(newValue ? .regular : .accessory)
            }
        )
    }

    private var updateChannelBinding: Binding<UpdateChannel> {
        Binding(
            get: { updateChannel },
            set: { newValue in
                updateChannelRaw = newValue.rawValue
                // Notify the updater manager about the channel change
                NotificationCenter.default.post(
                    name: Notification.Name("UpdateChannelChanged"),
                    object: nil,
                    userInfo: ["channel": newValue]
                )
            }
        )
    }

    private func checkForUpdates() {
        isCheckingForUpdates = true
        NotificationCenter.default.post(name: Notification.Name("checkForUpdates"), object: nil)

        // Reset after a delay
        Task {
            try? await Task.sleep(for: .seconds(2))
            isCheckingForUpdates = false
        }
    }
}
