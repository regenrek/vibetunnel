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

@customElement('vibetunnel-app')
export class VibeTunnelApp extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @state() private errorMessage = '';
  @state() private sessions: Session[] = [];
  @state() private loading = false;
  @state() private currentView: 'list' | 'session' = 'list';
  @state() private selectedSessionId: string | null = null;
  @state() private hideExited = true;
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

  private clearError() {
    this.errorMessage = '';
  }

  private async loadSessions() {
    this.loading = true;
    try {
      const response = await fetch('/api/sessions');
      if (response.ok) {
        const sessionsData = await response.json();
        this.sessions = sessionsData.map((session: any) => ({
          id: session.id,
          command: session.command,
          workingDir: session.workingDir,
          status: session.status,
          exitCode: session.exitCode,
          startedAt: session.startedAt,
          lastModified: session.lastModified,
          pid: session.pid
        }));
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

    if (!sessionId) {
      this.showError('Session created but ID not found in response');
      return;
    }

    this.showCreateModal = false;

    // Wait for session to appear in the list and then switch to it
    await this.waitForSessionAndSwitch(sessionId);
  }

  private async waitForSessionAndSwitch(sessionId: string) {
    const maxAttempts = 10;
    const delay = 500; // 500ms between attempts

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      await this.loadSessions();

      // Try to find by exact ID match first
      let session = this.sessions.find(s => s.id === sessionId);

      // If not found by ID, find the most recently created session
      // This works around tty-fwd potentially using different IDs internally
      if (!session && this.sessions.length > 0) {
        const sortedSessions = [...this.sessions].sort((a, b) =>
          new Date(b.startedAt).getTime() - new Date(a.startedAt).getTime()
        );
        session = sortedSessions[0];
      }

      if (session) {
        // Session found, switch to session view via URL
        window.location.search = `?session=${session.id}`;
        return;
      }

      // Wait before next attempt
      await new Promise(resolve => setTimeout(resolve, delay));
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
  }

  private handleCreateSession() {
    this.showCreateModal = true;
  }

  private handleCreateModalClose() {
    this.showCreateModal = false;
  }

  private async handleKillAll() {
    // Find all session cards and trigger their kill buttons
    const sessionCards = this.querySelectorAll('session-card');

    sessionCards.forEach((card: any) => {
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

  // URL Routing methods
  private setupRouting() {
    // Handle browser back/forward navigation
    window.addEventListener('popstate', this.handlePopState.bind(this));

    // Parse initial URL and set state
    this.parseUrlAndSetState();
  }

  private handlePopState = (event: PopStateEvent) => {
    // Handle browser back/forward navigation
    this.parseUrlAndSetState();
  }

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
      ${this.errorMessage ? html`
        <div class="fixed top-4 right-4 z-50">
          <div class="bg-vs-warning text-vs-bg px-4 py-2 rounded shadow-lg font-mono text-sm">
            ${this.errorMessage}
            <button @click=${this.clearError} class="ml-2 text-vs-bg hover:text-vs-muted">✕</button>
          </div>
        </div>
      ` : ''}

      <!-- Main content -->
      ${this.currentView === 'session' && this.selectedSessionId ?
        keyed(this.selectedSessionId, html`
          <session-view
            .session=${this.sessions.find(s => s.id === this.selectedSessionId)}
          ></session-view>
        `) : html`
        <div class="max-w-4xl mx-auto">
          <app-header
            @create-session=${this.handleCreateSession}
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