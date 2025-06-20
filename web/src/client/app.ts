import { LitElement, html } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import { keyed } from 'lit/directives/keyed.js';

// Import components
import './components/app-header.js';
import './components/session-create-form.js';
import './components/session-list.js';
import './components/session-view.js';
import './components/session-card.js';

import type { Session } from './components/session-list.js';
import type { SessionCard } from './components/session-card.js';

@customElement('vibetunnel-app')
export class VibeTunnelApp extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @state() private errorMessage = '';
  @state() private successMessage = '';
  @state() private sessions: Session[] = [];
  @state() private loading = false;
  @state() private currentView: 'list' | 'session' = 'list';
  @state() private selectedSessionId: string | null = null;
  @state() private hideExited = this.loadHideExitedState();
  @state() private showCreateModal = false;

  private hotReloadWs: WebSocket | null = null;

  connectedCallback() {
    super.connectedCallback();
    this.setupHotReload();
    this.loadSessions();
    this.startAutoRefresh();
    this.setupRouting();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this.hotReloadWs) {
      this.hotReloadWs.close();
    }
    // Clean up routing listeners
    window.removeEventListener('popstate', this.handlePopState);
  }

  private showError(message: string) {
    this.errorMessage = message;
    // Clear error after 5 seconds
    setTimeout(() => {
      this.errorMessage = '';
    }, 5000);
  }

  private showSuccess(message: string) {
    this.successMessage = message;
    // Clear success after 5 seconds
    setTimeout(() => {
      this.successMessage = '';
    }, 5000);
  }

  private clearError() {
    this.errorMessage = '';
  }

  private clearSuccess() {
    this.successMessage = '';
  }

  private async loadSessions() {
    this.loading = true;
    try {
      const response = await fetch('/api/sessions');
      if (response.ok) {
        this.sessions = (await response.json()) as Session[];
        this.clearError();
      } else {
        this.showError('Failed to load sessions');
      }
    } catch (error) {
      console.error('Error loading sessions:', error);
      this.showError('Failed to load sessions');
    } finally {
      this.loading = false;
    }
  }

  private startAutoRefresh() {
    // Refresh sessions every 3 seconds, but only when showing session list
    setInterval(() => {
      if (this.currentView === 'list') {
        this.loadSessions();
      }
    }, 3000);
  }

  private async handleSessionCreated(e: CustomEvent) {
    const sessionId = e.detail.sessionId;
    const message = e.detail.message;

    if (!sessionId) {
      this.showError('Session created but ID not found in response');
      return;
    }

    this.showCreateModal = false;

    // Check if this was a terminal spawn (not a web session)
    if (message && message.includes('Terminal spawned successfully')) {
      // Don't try to switch to the session - it's running in a terminal window
      this.showSuccess('Terminal window opened successfully');
      return;
    }

    // Wait for session to appear in the list and then switch to it
    await this.waitForSessionAndSwitch(sessionId);
  }

  private async waitForSessionAndSwitch(sessionId: string) {
    const maxAttempts = 10;
    const delay = 500; // 500ms between attempts

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      await this.loadSessions();

      // Try to find by exact ID match
      const session = this.sessions.find((s) => s.id === sessionId);

      if (session) {
        // Session found, switch to session view via URL
        window.location.search = `?session=${session.id}`;
        return;
      }

      // Wait before next attempt
      await new Promise((resolve) => setTimeout(resolve, delay));
    }

    // If we get here, session creation might have failed
    console.log('Session not found after all attempts');
    this.showError('Session created but could not be found. Please refresh.');
  }

  private handleSessionKilled(e: CustomEvent) {
    console.log('Session killed:', e.detail);
    this.loadSessions(); // Refresh the list
  }

  private handleRefresh() {
    this.loadSessions();
  }

  private handleError(e: CustomEvent) {
    this.showError(e.detail);
  }

  private handleHideExitedChange(e: CustomEvent) {
    this.hideExited = e.detail;
    this.saveHideExitedState(this.hideExited);
  }

  private handleCreateSession() {
    this.showCreateModal = true;
  }

  private handleCreateModalClose() {
    this.showCreateModal = false;
  }

  private async handleNavigateToSession(e: CustomEvent): Promise<void> {
    const { sessionId } = e.detail;

    // Check if View Transitions API is supported
    if ('startViewTransition' in document && typeof document.startViewTransition === 'function') {
      // Debug: Check what elements have view-transition-name before transition
      console.log('Before transition - elements with view-transition-name:');
      document.querySelectorAll('[style*="view-transition-name"]').forEach((el) => {
        console.log('Element:', el, 'Style:', el.getAttribute('style'));
      });

      // Use View Transitions API for smooth animation
      const transition = document.startViewTransition(async () => {
        // Update state which will trigger a re-render
        this.selectedSessionId = sessionId;
        this.currentView = 'session';
        this.updateUrl(sessionId);

        // Wait for LitElement to complete its update
        await this.updateComplete;

        // Debug: Check what elements have view-transition-name after transition
        console.log('After transition - elements with view-transition-name:');
        document.querySelectorAll('[style*="view-transition-name"]').forEach((el) => {
          console.log('Element:', el, 'Style:', el.getAttribute('style'));
        });
      });

      // Log if transition is ready
      transition.ready
        .then(() => {
          console.log('View transition ready');
        })
        .catch((err) => {
          console.error('View transition failed:', err);
        });
    } else {
      // Fallback for browsers without View Transitions support
      this.selectedSessionId = sessionId;
      this.currentView = 'session';
      this.updateUrl(sessionId);
    }
  }

  private handleNavigateToList(): void {
    // Check if View Transitions API is supported
    if ('startViewTransition' in document && typeof document.startViewTransition === 'function') {
      // Use View Transitions API for smooth animation
      document.startViewTransition(() => {
        // Update state which will trigger a re-render
        this.selectedSessionId = null;
        this.currentView = 'list';
        this.updateUrl();

        // Force update to ensure DOM changes happen within the transition
        return this.updateComplete;
      });
    } else {
      // Fallback for browsers without View Transitions support
      this.selectedSessionId = null;
      this.currentView = 'list';
      this.updateUrl();
    }
  }

  private async handleKillAll() {
    // Find all session cards and trigger their kill buttons
    const sessionCards = this.querySelectorAll<SessionCard>('session-card');

    sessionCards.forEach((card: SessionCard) => {
      // Check if this session is running
      if (card.session && card.session.status === 'running') {
        // Find all buttons within this card and look for the kill button
        const buttons = card.querySelectorAll('button');
        buttons.forEach((button: HTMLButtonElement) => {
          const buttonText = button.textContent?.toLowerCase() || '';
          if (buttonText.includes('kill') && !buttonText.includes('killing')) {
            // This is the kill button, click it to trigger the animation
            button.click();
          }
        });
      }
    });
  }

  private handleCleanExited() {
    // Find the session list and call its cleanup method directly
    const sessionList = this.querySelector('session-list') as HTMLElement & {
      handleCleanupExited?: () => void;
    };
    if (sessionList && sessionList.handleCleanupExited) {
      sessionList.handleCleanupExited();
    }
  }

  // State persistence methods
  private loadHideExitedState(): boolean {
    try {
      const saved = localStorage.getItem('hideExitedSessions');
      return saved !== null ? saved === 'true' : true; // Default to true if not set
    } catch (error) {
      console.error('Error loading hideExited state:', error);
      return true; // Default to true on error
    }
  }

  private saveHideExitedState(value: boolean): void {
    try {
      localStorage.setItem('hideExitedSessions', String(value));
    } catch (error) {
      console.error('Error saving hideExited state:', error);
    }
  }

  // URL Routing methods
  private setupRouting() {
    // Handle browser back/forward navigation
    window.addEventListener('popstate', this.handlePopState.bind(this));

    // Parse initial URL and set state
    this.parseUrlAndSetState();
  }

  private handlePopState = (_event: PopStateEvent) => {
    // Handle browser back/forward navigation
    this.parseUrlAndSetState();
  };

  private parseUrlAndSetState() {
    const url = new URL(window.location.href);
    const sessionId = url.searchParams.get('session');

    if (sessionId) {
      this.selectedSessionId = sessionId;
      this.currentView = 'session';
    } else {
      this.selectedSessionId = null;
      this.currentView = 'list';
    }
  }

  private updateUrl(sessionId?: string) {
    const url = new URL(window.location.href);

    if (sessionId) {
      url.searchParams.set('session', sessionId);
    } else {
      url.searchParams.delete('session');
    }

    // Update browser URL without triggering page reload
    window.history.pushState(null, '', url.toString());
  }

  private setupHotReload(): void {
    if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
      try {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = `${protocol}//${window.location.host}?hotReload=true`;

        this.hotReloadWs = new WebSocket(wsUrl);
        this.hotReloadWs.onmessage = (event) => {
          const message = JSON.parse(event.data);
          if (message.type === 'reload') {
            window.location.reload();
          }
        };
      } catch (error) {
        console.log('Error setting up hot reload:', error);
      }
    }
  }

  render() {
    return html`
      <!-- Error notification overlay -->
      ${this.errorMessage
        ? html`
            <div class="fixed top-4 right-4 z-50">
              <div
                class="bg-status-error text-dark-bg px-4 py-2 rounded shadow-lg font-mono text-sm"
              >
                ${this.errorMessage}
                <button @click=${this.clearError} class="ml-2 text-dark-bg hover:text-dark-text">
                  ✕
                </button>
              </div>
            </div>
          `
        : ''}
      ${this.successMessage
        ? html`
            <div class="fixed top-4 right-4 z-50">
              <div
                class="bg-status-success text-dark-bg px-4 py-2 rounded shadow-lg font-mono text-sm"
              >
                ${this.successMessage}
                <button @click=${this.clearSuccess} class="ml-2 text-dark-bg hover:text-dark-text">
                  ✕
                </button>
              </div>
            </div>
          `
        : ''}

      <!-- Main content -->
      ${this.currentView === 'session' && this.selectedSessionId
        ? keyed(
            this.selectedSessionId,
            html`
              <session-view
                .session=${this.sessions.find((s) => s.id === this.selectedSessionId)}
              ></session-view>
            `
          )
        : html`
            <div class="max-w-4xl mx-auto">
              <app-header
                .sessions=${this.sessions}
                .hideExited=${this.hideExited}
                @create-session=${this.handleCreateSession}
                @hide-exited-change=${this.handleHideExitedChange}
                @kill-all-sessions=${this.handleKillAll}
                @clean-exited-sessions=${this.handleCleanExited}
              ></app-header>
              <session-list
                .sessions=${this.sessions}
                .loading=${this.loading}
                .hideExited=${this.hideExited}
                .showCreateModal=${this.showCreateModal}
                @session-killed=${this.handleSessionKilled}
                @session-created=${this.handleSessionCreated}
                @create-modal-close=${this.handleCreateModalClose}
                @refresh=${this.handleRefresh}
                @error=${this.handleError}
                @hide-exited-change=${this.handleHideExitedChange}
                @kill-all-sessions=${this.handleKillAll}
              ></session-list>
            </div>
          `}
    `;
  }
}
