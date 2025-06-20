import SwiftUI

/// Main settings view with tabbed navigation
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab = SettingsTab.general
    
    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case advanced = "Advanced"
        
        var icon: String {
            switch self {
            case .general: return "gear"
            case .advanced: return "gearshape.2"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab selector
                HStack(spacing: 0) {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Button(action: {
                            withAnimation(Theme.Animation.smooth) {
                                selectedTab = tab
                            }
                        }) {
                            VStack(spacing: Theme.Spacing.small) {
                                Image(systemName: tab.icon)
                                    .font(.title2)
                                Text(tab.rawValue)
                                    .font(Theme.Typography.terminalSystem(size: 14))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.medium)
                            .foregroundColor(selectedTab == tab ? Theme.Colors.primaryAccent : Theme.Colors.terminalForeground.opacity(0.5))
                            .background(
                                selectedTab == tab ? Theme.Colors.primaryAccent.opacity(0.1) : Color.clear
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .background(Theme.Colors.cardBackground)
                
                Divider()
                    .background(Theme.Colors.terminalForeground.opacity(0.1))
                
                // Tab content
                ScrollView {
                    VStack(spacing: Theme.Spacing.large) {
                        switch selectedTab {
                        case .general:
                            GeneralSettingsView()
                        case .advanced:
                            AdvancedSettingsView()
                        }
                    }
                    .padding()
                }
                .background(Theme.Colors.terminalBackground)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(Theme.Colors.primaryAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// General settings tab content
struct GeneralSettingsView: View {
    @AppStorage("defaultFontSize") private var defaultFontSize: Double = 14
    @AppStorage("defaultTerminalWidth") private var defaultTerminalWidth: Int = 80
    @AppStorage("autoScrollEnabled") private var autoScrollEnabled = true
    @AppStorage("enableURLDetection") private var enableURLDetection = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            // Terminal Defaults Section
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("Terminal Defaults")
                    .font(.headline)
                    .foregroundColor(Theme.Colors.terminalForeground)
                
                VStack(spacing: Theme.Spacing.medium) {
                    // Font Size
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("Default Font Size: \(Int(defaultFontSize))pt")
                            .font(Theme.Typography.terminalSystem(size: 14))
                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                        
                        Slider(value: $defaultFontSize, in: 10...24, step: 1)
                            .accentColor(Theme.Colors.primaryAccent)
                    }
                    .padding()
                    .background(Theme.Colors.cardBackground)
                    .cornerRadius(Theme.CornerRadius.card)
                    
                    // Terminal Width
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("Default Terminal Width: \(defaultTerminalWidth) columns")
                            .font(Theme.Typography.terminalSystem(size: 14))
                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                        
                        Picker("Width", selection: $defaultTerminalWidth) {
                            Text("80 columns").tag(80)
                            Text("100 columns").tag(100)
                            Text("120 columns").tag(120)
                            Text("160 columns").tag(160)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    .padding()
                    .background(Theme.Colors.cardBackground)
                    .cornerRadius(Theme.CornerRadius.card)
                    
                    // Auto Scroll
                    Toggle(isOn: $autoScrollEnabled) {
                        HStack {
                            Image(systemName: "arrow.down.to.line")
                                .foregroundColor(Theme.Colors.primaryAccent)
                            Text("Auto-scroll to bottom")
                                .font(Theme.Typography.terminalSystem(size: 14))
                                .foregroundColor(Theme.Colors.terminalForeground)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.Colors.primaryAccent))
                    .padding()
                    .background(Theme.Colors.cardBackground)
                    .cornerRadius(Theme.CornerRadius.card)
                    
                    // URL Detection
                    Toggle(isOn: $enableURLDetection) {
                        HStack {
                            Image(systemName: "link")
                                .foregroundColor(Theme.Colors.primaryAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Detect URLs")
                                    .font(Theme.Typography.terminalSystem(size: 14))
                                    .foregroundColor(Theme.Colors.terminalForeground)
                                Text("Make URLs clickable in terminal output")
                                    .font(Theme.Typography.terminalSystem(size: 12))
                                    .foregroundColor(Theme.Colors.terminalForeground.opacity(0.6))
                            }
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.Colors.primaryAccent))
                    .padding()
                    .background(Theme.Colors.cardBackground)
                    .cornerRadius(Theme.CornerRadius.card)
                }
            }
            
            Spacer()
        }
    }
}

/// Advanced settings tab content
struct AdvancedSettingsView: View {
    @AppStorage("verboseLogging") private var verboseLogging = false
    @AppStorage("enableMetrics") private var enableMetrics = true
    @AppStorage("enableCrashReporting") private var enableCrashReporting = true
    @AppStorage("debugModeEnabled") private var debugModeEnabled = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            // Logging Section
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("Logging & Analytics")
                    .font(.headline)
                    .foregroundColor(Theme.Colors.terminalForeground)
                
                VStack(spacing: Theme.Spacing.medium) {
                    // Verbose Logging
                    Toggle(isOn: $verboseLogging) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(Theme.Colors.primaryAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Verbose Logging")
                                    .font(Theme.Typography.terminalSystem(size: 14))
                                    .foregroundColor(Theme.Colors.terminalForeground)
                                Text("Log detailed debugging information")
                                    .font(Theme.Typography.terminalSystem(size: 12))
                                    .foregroundColor(Theme.Colors.terminalForeground.opacity(0.6))
                            }
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.Colors.primaryAccent))
                    .padding()
                    .background(Theme.Colors.cardBackground)
                    .cornerRadius(Theme.CornerRadius.card)
                    
                    // Metrics
                    Toggle(isOn: $enableMetrics) {
                        HStack {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundColor(Theme.Colors.primaryAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Usage Metrics")
                                    .font(Theme.Typography.terminalSystem(size: 14))
                                    .foregroundColor(Theme.Colors.terminalForeground)
                                Text("Help improve the app by sharing usage data")
                                    .font(Theme.Typography.terminalSystem(size: 12))
                                    .foregroundColor(Theme.Colors.terminalForeground.opacity(0.6))
                            }
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.Colors.primaryAccent))
                    .padding()
                    .background(Theme.Colors.cardBackground)
                    .cornerRadius(Theme.CornerRadius.card)
                    
                    // Crash Reporting
                    Toggle(isOn: $enableCrashReporting) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(Theme.Colors.primaryAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Crash Reports")
                                    .font(Theme.Typography.terminalSystem(size: 14))
                                    .foregroundColor(Theme.Colors.terminalForeground)
                                Text("Automatically send crash reports")
                                    .font(Theme.Typography.terminalSystem(size: 12))
                                    .foregroundColor(Theme.Colors.terminalForeground.opacity(0.6))
                            }
                        }
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Theme.Colors.primaryAccent))
                    .padding()
                    .background(Theme.Colors.cardBackground)
                    .cornerRadius(Theme.CornerRadius.card)
                }
            }
            
            // Developer Section
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Text("Developer")
                    .font(.headline)
                    .foregroundColor(Theme.Colors.terminalForeground)
                
                // Debug Mode Switch - Last element in Advanced section
                Toggle(isOn: $debugModeEnabled) {
                    HStack {
                        Image(systemName: "ladybug")
                            .foregroundColor(Theme.Colors.warningAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Debug Mode")
                                .font(Theme.Typography.terminalSystem(size: 14))
                                .foregroundColor(Theme.Colors.terminalForeground)
                            Text("Enable debug features and logging")
                                .font(Theme.Typography.terminalSystem(size: 12))
                                .foregroundColor(Theme.Colors.terminalForeground.opacity(0.6))
                        }
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: Theme.Colors.warningAccent))
                .padding()
                .background(Theme.Colors.cardBackground)
                .cornerRadius(Theme.CornerRadius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.card)
                        .stroke(Theme.Colors.warningAccent.opacity(0.3), lineWidth: 1)
                )
            }
            
            Spacer()
        }
    }
}

#Preview {
    SettingsView()
}