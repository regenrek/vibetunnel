import SwiftUI

/// Sheet for selecting terminal width presets.
///
/// Provides common terminal width options (80, 100, 120, 132, 160 columns)
/// with descriptions of their typical use cases.
struct TerminalWidthSheet: View {
    @Binding var selectedWidth: Int?
    @Environment(\.dismiss) var dismiss
    
    struct WidthPreset {
        let columns: Int
        let name: String
        let description: String
        let icon: String
    }
    
    let widthPresets: [WidthPreset] = [
        WidthPreset(
            columns: 80,
            name: "Classic",
            description: "Traditional terminal width, ideal for legacy apps",
            icon: "rectangle.split.3x1"
        ),
        WidthPreset(
            columns: 100,
            name: "Comfortable",
            description: "Good balance for modern development",
            icon: "rectangle.split.3x1.fill"
        ),
        WidthPreset(
            columns: 120,
            name: "Standard",
            description: "Common IDE and editor width",
            icon: "rectangle.3.offgrid"
        ),
        WidthPreset(
            columns: 132,
            name: "Wide",
            description: "DEC VT100 wide mode, great for logs",
            icon: "rectangle.3.offgrid.fill"
        ),
        WidthPreset(
            columns: 160,
            name: "Ultra Wide",
            description: "Maximum visibility for complex output",
            icon: "rectangle.grid.3x2"
        )
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.large) {
                    // Info header
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.Colors.primaryAccent)
                        
                        Text("Terminal width determines how many characters fit on each line")
                            .font(.caption)
                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    
                    // Width presets
                    VStack(spacing: Theme.Spacing.medium) {
                        ForEach(widthPresets, id: \.columns) { preset in
                            Button(action: {
                                selectedWidth = preset.columns
                                HapticFeedback.impact(.light)
                                dismiss()
                            }) {
                                HStack(spacing: Theme.Spacing.medium) {
                                    // Icon
                                    Image(systemName: preset.icon)
                                        .font(.system(size: 24))
                                        .foregroundColor(Theme.Colors.primaryAccent)
                                        .frame(width: 40)
                                    
                                    // Text content
                                    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
                                        HStack {
                                            Text(preset.name)
                                                .font(.headline)
                                                .foregroundColor(Theme.Colors.terminalForeground)
                                            
                                            Text("\(preset.columns) columns")
                                                .font(.caption)
                                                .foregroundColor(Theme.Colors.terminalForeground.opacity(0.5))
                                        }
                                        
                                        Text(preset.description)
                                            .font(.caption)
                                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    
                                    Spacer()
                                    
                                    // Selection indicator
                                    if selectedWidth == preset.columns {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(Theme.Colors.successAccent)
                                    }
                                }
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                        .fill(selectedWidth == preset.columns 
                                            ? Theme.Colors.primaryAccent.opacity(0.1) 
                                            : Theme.Colors.cardBorder.opacity(0.1))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                        .stroke(selectedWidth == preset.columns 
                                            ? Theme.Colors.primaryAccent 
                                            : Theme.Colors.cardBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal)
                    
                    // Custom width option
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text("Custom Width")
                            .font(.caption)
                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                            .padding(.horizontal)
                        
                        Button(action: {
                            // For now, just use the current width
                            selectedWidth = nil
                            dismiss()
                        }) {
                            HStack {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 20))
                                    .foregroundColor(Theme.Colors.terminalForeground.opacity(0.5))
                                
                                Text("Use current terminal width")
                                    .font(.subheadline)
                                    .foregroundColor(Theme.Colors.terminalForeground)
                                
                                Spacer()
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .fill(Theme.Colors.cardBorder.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                    .stroke(Theme.Colors.cardBorder, lineWidth: 1)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal)
                    }
                    
                    Spacer(minLength: Theme.Spacing.large)
                }
            }
            .background(Theme.Colors.cardBackground)
            .navigationTitle("Terminal Width")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(Theme.Colors.primaryAccent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    TerminalWidthSheet(selectedWidth: .constant(80))
}