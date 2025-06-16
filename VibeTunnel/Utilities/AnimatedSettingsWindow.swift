import SwiftUI
import AppKit

/// A view that enables animated window resizing for Settings windows
struct AnimatedWindowContainer<Content: View>: NSViewRepresentable {
    let content: Content
    let targetSize: CGSize
    
    class Coordinator: NSObject {
        var lastSize: CGSize = .zero
        weak var window: NSWindow?
        var isAnimating = false
        
        func animateWindowResize(to newSize: CGSize) {
            guard let window = window,
                  newSize != lastSize,
                  !isAnimating else { return }
            
            lastSize = newSize
            isAnimating = true
            
            // Calculate the new frame maintaining the window's top-left position
            var newFrame = window.frame
            let heightDifference = newSize.height - newFrame.height
            newFrame.size = newSize
            newFrame.origin.y -= heightDifference // Keep top edge in place
            
            // Animate the window frame change
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(newFrame, display: true)
            }, completionHandler: {
                self.isAnimating = false
            })
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        
        // Use async to ensure window is available
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.window = window
                // Disable automatic window resizing
                window.styleMask.remove(.resizable)
                // Set initial size
                context.coordinator.lastSize = window.frame.size
            }
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Ensure we have a window
        if context.coordinator.window == nil, let window = nsView.window {
            context.coordinator.window = window
            window.styleMask.remove(.resizable)
            context.coordinator.lastSize = window.frame.size
        }
        
        // Animate to the new size
        context.coordinator.animateWindowResize(to: targetSize)
    }
}

/// Extension to make it easy to use with any SwiftUI view
extension View {
    func animatedWindowContainer(size: CGSize) -> some View {
        background(
            AnimatedWindowContainer(
                content: Color.clear,
                targetSize: size
            )
            .allowsHitTesting(false)
        )
    }
}
