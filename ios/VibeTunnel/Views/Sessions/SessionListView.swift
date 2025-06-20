import Observation
import SwiftUI

struct SessionListView: View {
    @Environment(ConnectionManager.self) var connectionManager
    @Environment(NavigationManager.self) var navigationManager
    @State private var viewModel = SessionListViewModel()
    @State private var showingCreateSession = false
    @State private var selectedSession: Session?
    @State private var showExitedSessions = true

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Theme.Colors.terminalBackground
                    .ignoresSafeArea()

                if viewModel.isLoading && viewModel.sessions.isEmpty {
                    ProgressView("Loading sessions...")
                        .progressViewStyle(CircularProgressViewStyle(tint: Theme.Colors.primaryAccent))
                        .font(Theme.Typography.terminalSystem(size: 14))
                        .foregroundColor(Theme.Colors.terminalForeground)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.sessions.isEmpty {
                    emptyStateView
                } else {
                    sessionList
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        HapticFeedback.impact(.medium)
                        connectionManager.disconnect()
                    }, label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text("Disconnect")
                        }
                        .foregroundColor(Theme.Colors.errorAccent)
                    })
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        HapticFeedback.impact(.light)
                        showingCreateSession = true
                    }, label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(Theme.Colors.primaryAccent)
                    })
                }
            }
            .sheet(isPresented: $showingCreateSession) {
                SessionCreateView(isPresented: $showingCreateSession) { newSessionId in
                    Task {
                        await viewModel.loadSessions()
                        // Find and select the new session
                        if let newSession = viewModel.sessions.first(where: { $0.id == newSessionId }) {
                            selectedSession = newSession
                        }
                    }
                }
            }
            .sheet(item: $selectedSession) { session in
                TerminalView(session: session)
            }
            .refreshable {
                await viewModel.loadSessions()
            }
            .onAppear {
                viewModel.startAutoRefresh()
            }
            .onDisappear {
                viewModel.stopAutoRefresh()
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: navigationManager.shouldNavigateToSession) { _, shouldNavigate in
            if shouldNavigate,
               let sessionId = navigationManager.selectedSessionId,
               let session = viewModel.sessions.first(where: { $0.id == sessionId }) {
                selectedSession = session
                navigationManager.clearNavigation()
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: Theme.Spacing.extraLarge) {
            ZStack {
                Image(systemName: "terminal")
                    .font(.system(size: 60))
                    .foregroundColor(Theme.Colors.primaryAccent)
                    .blur(radius: 20)
                    .opacity(0.3)

                Image(systemName: "terminal")
                    .font(.system(size: 60))
                    .foregroundColor(Theme.Colors.primaryAccent)
            }

            VStack(spacing: Theme.Spacing.small) {
                Text("No Sessions")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(Theme.Colors.terminalForeground)

                Text("Create a new terminal session to get started")
                    .font(Theme.Typography.terminalSystem(size: 14))
                    .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            Button(action: {
                HapticFeedback.impact(.medium)
                showingCreateSession = true
            }, label: {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "plus.circle")
                    Text("Create Session")
                }
                .font(Theme.Typography.terminalSystem(size: 16))
                .fontWeight(.medium)
            })
            .terminalButton()
        }
        .padding()
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.large) {
                // Header with session count and kill all button
                HStack {
                    let runningCount = viewModel.sessions.count(where: { $0.isRunning })
                    let exitedCount = viewModel.sessions.count(where: { !$0.isRunning })

                    HStack(spacing: Theme.Spacing.medium) {
                        if runningCount > 0 {
                            HStack(spacing: 4) {
                                Text("Running:")
                                    .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                                Text("\(runningCount)")
                                    .foregroundColor(Theme.Colors.successAccent)
                                    .fontWeight(.semibold)
                            }
                        }

                        if exitedCount > 0 {
                            HStack(spacing: 4) {
                                Text("Exited:")
                                    .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                                Text("\(exitedCount)")
                                    .foregroundColor(Theme.Colors.errorAccent)
                                    .fontWeight(.semibold)
                            }
                        }

                        if runningCount == 0 && exitedCount == 0 {
                            Text("No Sessions")
                                .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                        }
                    }
                    .font(Theme.Typography.terminalSystem(size: 16))

                    Spacer()

                    // Toggle to show/hide exited sessions
                    if exitedCount > 0 {
                        Button(action: {
                            HapticFeedback.selection()
                            withAnimation(Theme.Animation.smooth) {
                                showExitedSessions.toggle()
                            }
                        }, label: {
                            HStack(spacing: 4) {
                                Image(systemName: showExitedSessions ? "eye.slash" : "eye")
                                    .font(.caption)
                                Text(showExitedSessions ? "Hide Exited" : "Show Exited")
                                    .font(Theme.Typography.terminalSystem(size: 12))
                            }
                            .foregroundColor(Theme.Colors.terminalForeground.opacity(0.7))
                            .padding(.horizontal, Theme.Spacing.small)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                                    .fill(Theme.Colors.terminalForeground.opacity(0.1))
                            )
                        })
                        .buttonStyle(PlainButtonStyle())
                    }

                    if viewModel.sessions.contains(where: \.isRunning) {
                        Button(action: {
                            HapticFeedback.impact(.medium)
                            Task {
                                await viewModel.killAllSessions()
                            }
                        }, label: {
                            HStack(spacing: Theme.Spacing.small) {
                                Image(systemName: "stop.circle")
                                Text("Kill All")
                            }
                            .font(Theme.Typography.terminalSystem(size: 14))
                            .foregroundColor(Theme.Colors.errorAccent)
                            .padding(.horizontal, Theme.Spacing.medium)
                            .padding(.vertical, Theme.Spacing.small)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                                    .fill(Theme.Colors.errorAccent.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                                    .stroke(Theme.Colors.errorAccent.opacity(0.3), lineWidth: 1)
                            )
                        })
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal)

                // Sessions grid
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: Theme.Spacing.medium),
                    GridItem(.flexible(), spacing: Theme.Spacing.medium)
                ], spacing: Theme.Spacing.medium) {
                    // Clean up all button if there are exited sessions
                    if showExitedSessions && viewModel.sessions.contains(where: { !$0.isRunning }) {
                        Button(action: {
                            HapticFeedback.impact(.medium)
                            Task {
                                await viewModel.cleanupAllExited()
                            }
                        }, label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Clean Up All Exited")
                                Spacer()
                            }
                            .font(Theme.Typography.terminalSystem(size: 14))
                            .foregroundColor(Theme.Colors.warningAccent)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.card)
                                    .fill(Theme.Colors.warningAccent.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.CornerRadius.card)
                                    .stroke(Theme.Colors.warningAccent.opacity(0.3), lineWidth: 1)
                            )
                        })
                        .buttonStyle(PlainButtonStyle())
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .scale.combined(with: .opacity)
                        ))
                    }

                    ForEach(viewModel.sessions.filter { showExitedSessions || $0.isRunning }) { session in
                        SessionCardView(session: session) {
                            HapticFeedback.selection()
                            if session.isRunning {
                                selectedSession = session
                            }
                        } onKill: {
                            HapticFeedback.impact(.medium)
                            Task {
                                await viewModel.killSession(session.id)
                            }
                        } onCleanup: {
                            HapticFeedback.impact(.medium)
                            Task {
                                await viewModel.cleanupSession(session.id)
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.8).combined(with: .opacity),
                            removal: .scale(scale: 0.8).combined(with: .opacity)
                        ))
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .animation(Theme.Animation.smooth, value: viewModel.sessions)
        }
    }
}

@MainActor
@Observable
class SessionListViewModel {
    var sessions: [Session] = []
    var isLoading = false
    var errorMessage: String?

    private var refreshTask: Task<Void, Never>?
    private let sessionService = SessionService.shared

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            await loadSessions()

            // Refresh every 3 seconds using modern async approach
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                if !Task.isCancelled {
                    await loadSessions()
                }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func loadSessions() async {
        if sessions.isEmpty {
            isLoading = true
        }

        do {
            sessions = try await sessionService.getSessions()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func killSession(_ sessionId: String) async {
        do {
            try await sessionService.killSession(sessionId)
            await loadSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cleanupSession(_ sessionId: String) async {
        do {
            try await sessionService.cleanupSession(sessionId)
            await loadSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cleanupAllExited() async {
        do {
            _ = try await sessionService.cleanupAllExitedSessions()
            await loadSessions()
            HapticFeedback.notification(.success)
        } catch {
            errorMessage = error.localizedDescription
            HapticFeedback.notification(.error)
        }
    }

    func killAllSessions() async {
        let runningSessions = sessions.filter(\.isRunning)
        for session in runningSessions {
            do {
                try await sessionService.killSession(session.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        await loadSessions()
    }
}
