import AppKit
import SwiftUI

/// A custom window size animator that works with SwiftUI Settings windows
@MainActor
final class WindowSizeAnimator: ObservableObject {
    static let shared = WindowSizeAnimator()

    private weak var window: NSWindow?
    private var animator: NSViewAnimation?

    private init() {}

    /// Find and store reference to the settings window
    func captureSettingsWindow() {
        // Try multiple strategies to find the window
        if let window = NSApp.windows.first(where: { window in
            // Check if it's a settings-like window
            window.isVisible &&
                window.level == .normal &&
                !window.isKind(of: NSPanel.self) &&
                window.canBecomeKey &&
                (window.title.isEmpty || window.title.contains("VibeTunnel") ||
                    window.title.lowercased().contains("settings") ||
                    window.title.lowercased().contains("preferences")
                )
        }) {
            self.window = window
            // Disable user resizing
            window.styleMask.remove(.resizable)
        }
    }

    /// Animate window to new size using NSViewAnimation
    func animateWindowSize(to newSize: CGSize, duration: TimeInterval = 0.25) {
        guard let window else {
            // Try to capture window if we haven't yet
            captureSettingsWindow()
            guard self.window != nil else { return }
            animateWindowSize(to: newSize, duration: duration)
            return
        }

        // Cancel any existing animation
        animator?.stop()

        // Calculate new frame keeping top-left corner fixed
        var newFrame = window.frame
        let heightDifference = newSize.height - newFrame.height
        newFrame.size = newSize
        newFrame.origin.y -= heightDifference

        // Create animation dictionary
        let windowDict: [NSViewAnimation.Key: Any] = [
            .target: window,
            .startFrame: window.frame,
            .endFrame: newFrame
        ]

        // Create and configure animation
        let animation = NSViewAnimation(viewAnimations: [windowDict])
        animation.animationBlockingMode = .nonblocking
        animation.animationCurve = .easeInOut
        animation.duration = duration

        // Store animator reference
        self.animator = animation

        // Start animation
        animation.start()
    }
}

/// A view modifier that captures the window and enables animated resizing
struct AnimatedWindowSizing: ViewModifier {
    let size: CGSize
    @StateObject private var animator = WindowSizeAnimator.shared

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Capture window after a delay to ensure it's created
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    await MainActor.run {
                        animator.captureSettingsWindow()
                        // Set initial size without animation
                        if let window = NSApp.keyWindow {
                            var frame = window.frame
                            frame.size = size
                            window.setFrame(frame, display: true)
                        }
                    }
                }
            }
            .onChange(of: size) { _, newSize in
                animator.animateWindowSize(to: newSize)
            }
    }
}

extension View {
    func animatedWindowSizing(size: CGSize) -> some View {
        modifier(AnimatedWindowSizing(size: size))
    }
}
