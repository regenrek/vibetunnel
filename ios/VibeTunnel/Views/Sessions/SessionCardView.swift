import SwiftUI

struct SessionCardView: View {
    let session: Session
    let onTap: () -> Void
    let onKill: () -> Void
    let onCleanup: () -> Void
    
    @State private var isPressed = false
    @State private var terminalSnapshot: TerminalSnapshot?
    @State private var isLoadingSnapshot = false
    @State private var isKilling = false
    @State private var opacity: Double = 1.0
    @State private var scale: CGFloat = 1.0
    
    private var displayWorkingDir: String {
        // Convert absolute paths back to ~ notation for display
        let homePrefix = "/Users/"
        if session.workingDir.hasPrefix(homePrefix),
           let userEndIndex = session.workingDir[homePrefix.endIndex...].firstIndex(of: "/") {
            let restOfPath = String(session.workingDir[userEndIndex...])
            return "~\(restOfPath)"
        }
        return session.workingDir
    }
    
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // Header with session ID/name and kill button
                HStack {
                    Text(session.name ?? String(session.id.prefix(8)))
                        .font(Theme.Typography.terminalSystem(size: 14))
                        .fontWeight(.medium)
                        .foregroundColor(Theme.Colors.primaryAccent)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Button(action: {
                        HapticFeedback.impact(.medium)
                        if session.isRunning {
                            animateKill()
                        } else {
                            animateCleanup()
                        }
                    }) {
                        Text(session.isRunning ? "kill" : "clean")
                            .font(Theme.Typography.terminalSystem(size: 12))
                            .foregroundColor(Theme.Colors.terminalForeground)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                                    .stroke(Theme.Colors.cardBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // Terminal content area showing command and terminal output preview
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                    .fill(Theme.Colors.terminalBackground)
                    .frame(height: 120)
                    .overlay(
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            if session.isRunning {
                                if let snapshot = terminalSnapshot, !snapshot.cleanOutputPreview.isEmpty {
                                    // Show terminal output preview
                                    ScrollView(.vertical, showsIndicators: false) {
                                        Text(snapshot.cleanOutputPreview)
                                            .font(Theme.Typography.terminalSystem(size: 10))
                                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.8))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineLimit(nil)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .padding(Theme.Spacing.sm)
                                } else {
                                    // Show command and working directory info as fallback
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 4) {
                                            Text("$")
                                                .font(Theme.Typography.terminalSystem(size: 12))
                                                .foregroundColor(Theme.Colors.primaryAccent)
                                            Text(session.command)
                                                .font(Theme.Typography.terminalSystem(size: 12))
                                                .foregroundColor(Theme.Colors.terminalForeground)
                                        }
                                        
                                        Text(displayWorkingDir)
                                            .font(Theme.Typography.terminalSystem(size: 10))
                                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.6))
                                            .lineLimit(1)
                                        
                                        if isLoadingSnapshot {
                                            HStack {
                                                ProgressView()
                                                    .progressViewStyle(CircularProgressViewStyle(tint: Theme.Colors.primaryAccent))
                                                    .scaleEffect(0.8)
                                                Text("Loading output...")
                                                    .font(Theme.Typography.terminalSystem(size: 10))
                                                    .foregroundColor(Theme.Colors.terminalForeground.opacity(0.5))
                                            }
                                            .padding(.top, Theme.Spacing.xs)
                                        }
                                    }
                                    .padding(Theme.Spacing.sm)
                                    
                                    Spacer()
                                }
                            } else {
                                if let snapshot = terminalSnapshot, !snapshot.cleanOutputPreview.isEmpty {
                                    // Show last output for exited sessions
                                    ScrollView(.vertical, showsIndicators: false) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Session exited")
                                                .font(Theme.Typography.terminalSystem(size: 10))
                                                .foregroundColor(Theme.Colors.errorAccent)
                                            Text(snapshot.cleanOutputPreview)
                                                .font(Theme.Typography.terminalSystem(size: 10))
                                                .foregroundColor(Theme.Colors.terminalForeground.opacity(0.6))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .lineLimit(nil)
                                                .multilineTextAlignment(.leading)
                                        }
                                    }
                                    .padding(Theme.Spacing.sm)
                                } else {
                                    Text("Session exited")
                                        .font(Theme.Typography.terminalSystem(size: 12))
                                        .foregroundColor(Theme.Colors.terminalForeground.opacity(0.5))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                    )
                
                // Status bar at bottom
                HStack(spacing: Theme.Spacing.sm) {
                    // Status indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(session.isRunning ? Theme.Colors.successAccent : Theme.Colors.terminalForeground.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text(session.isRunning ? "running" : "exited")
                            .font(Theme.Typography.terminalSystem(size: 10))
                            .foregroundColor(session.isRunning ? Theme.Colors.successAccent : Theme.Colors.terminalForeground.opacity(0.5))
                    }
                    
                    Spacer()
                    
                    // PID info
                    if session.isRunning, let pid = session.pid {
                        Text("PID: \(pid)")
                            .font(Theme.Typography.terminalSystem(size: 10))
                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.5))
                            .onTapGesture {
                                UIPasteboard.general.string = String(pid)
                                HapticFeedback.notification(.success)
                            }
                    }
                }
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.card)
                    .fill(Theme.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.card)
                    .stroke(Theme.Colors.cardBorder, lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.98 : scale)
            .opacity(opacity)
        }
        .buttonStyle(PlainButtonStyle())
        .onLongPressGesture(
            minimumDuration: 0.1,
            maximumDistance: .infinity,
            pressing: { pressing in
                withAnimation(Theme.Animation.quick) {
                    isPressed = pressing
                }
            },
            perform: {}
        )
        .contextMenu {
            if session.isRunning {
                Button(action: animateKill) {
                    Label("Kill Session", systemImage: "stop.circle")
                }
            } else {
                Button(action: animateCleanup) {
                    Label("Clean Up", systemImage: "trash")
                }
            }
        }
        .onAppear {
            loadSnapshot()
        }
    }
    
    private func loadSnapshot() {
        guard terminalSnapshot == nil else { return }
        
        isLoadingSnapshot = true
        Task {
            do {
                let snapshot = try await APIClient.shared.getSessionSnapshot(sessionId: session.id)
                await MainActor.run {
                    self.terminalSnapshot = snapshot
                    self.isLoadingSnapshot = false
                }
            } catch {
                // Silently fail - we'll just show the command/cwd fallback
                await MainActor.run {
                    self.isLoadingSnapshot = false
                }
            }
        }
    }
    
    private func animateKill() {
        guard !isKilling else { return }
        isKilling = true
        
        // Shake animation
        withAnimation(.linear(duration: 0.05).repeatCount(4, autoreverses: true)) {
            scale = 0.97
        }
        
        // Fade out after shake
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.3)) {
                opacity = 0.5
                scale = 0.95
            }
            onKill()
            
            // Reset after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isKilling = false
                withAnimation(.easeIn(duration: 0.2)) {
                    opacity = 1.0
                    scale = 1.0
                }
            }
        }
    }
    
    private func animateCleanup() {
        // Shrink and fade animation for cleanup
        withAnimation(.easeOut(duration: 0.3)) {
            scale = 0.8
            opacity = 0
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onCleanup()
        }
    }
}