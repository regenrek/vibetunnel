import SwiftUI

/// Floating action button to scroll terminal to bottom
struct ScrollToBottomButton: View {
    let isVisible: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            HapticFeedback.impact(.light)
            action()
        }) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.Colors.terminalForeground)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(Theme.Colors.cardBackground.opacity(0.95))
                        .overlay(
                            Circle()
                                .stroke(Theme.Colors.cardBorder, lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.8)
        .animation(Theme.Animation.smooth, value: isVisible)
        .allowsHitTesting(isVisible)
    }
}

/// Extension to add scroll-to-bottom overlay modifier
extension View {
    func scrollToBottomOverlay(
        isVisible: Bool,
        action: @escaping () -> Void
    ) -> some View {
        self.overlay(
            ScrollToBottomButton(
                isVisible: isVisible,
                action: action
            )
            .padding(.bottom, Theme.Spacing.large)
            .padding(.leading, Theme.Spacing.large),
            alignment: .bottomLeading
        )
    }
}

#Preview {
    ZStack {
        Theme.Colors.terminalBackground
            .ignoresSafeArea()
        
        ScrollToBottomButton(isVisible: true) {
            print("Scroll to bottom")
        }
    }
}