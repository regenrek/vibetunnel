import { LitElement, html } from 'lit';
import { customElement, state } from 'lit/decorators.js';

// Import components
import './components/app-header.js';
import './components/session-create-form.js';
import './components/session-list.js';
import './components/session-view.js';

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
  @state() private selectedSession: Session | null = null;
  @state() private hideExited = true;
  @state() private showCreateModal = false;

  private hotReloadWs: WebSocket | null = null;

  connectedCallback() {
    super.connectedCallback();
    this.setupHotReload();
    this.loadSessions();
    this.startAutoRefresh();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this.hotReloadWs) {
      this.hotReloadWs.close();
    }
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
    // Refresh sessions every 3 seconds
    setInterval(() => {
      this.loadSessions();
    }, 3000);
  }

  private handleSessionCreated(e: CustomEvent) {
    console.log('Session created:', e.detail);
    this.showError('Session created successfully!');
    this.showCreateModal = false;
    this.loadSessions(); // Refresh the list
  }

  private handleSessionSelect(e: CustomEvent) {
    const session = e.detail as Session;
    console.log('Session selected:', session);
    this.selectedSession = session;
    this.currentView = 'session';
  }

  private handleBack() {
    this.currentView = 'list';
    this.selectedSession = null;
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

  private setupHotReload(): void {
    if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsUrl = `${protocol}//${window.location.host}?hotReload=true`;

      this.hotReloadWs = new WebSocket(wsUrl);
      this.hotReloadWs.onmessage = (event) => {
        const message = JSON.parse(event.data);
        if (message.type === 'reload') {
          window.location.reload();
        }
      };
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
      ${this.currentView === 'session' ? html`
        <session-view
          .session=${this.selectedSession}
          @back=${this.handleBack}
        ></session-view>
      ` : html`
        <div class="max-w-4xl mx-auto">
          <app-header
            @create-session=${this.handleCreateSession}
          ></app-header>
          <session-list
            .sessions=${this.sessions}
            .loading=${this.loading}
            .hideExited=${this.hideExited}
            .showCreateModal=${this.showCreateModal}
            @session-select=${this.handleSessionSelect}
            @session-killed=${this.handleSessionKilled}
            @session-created=${this.handleSessionCreated}
            @create-modal-close=${this.handleCreateModalClose}
            @refresh=${this.handleRefresh}
            @error=${this.handleError}
            @hide-exited-change=${this.handleHideExitedChange}
          ></session-list>
        </div>
      `}
    `;
  }
}