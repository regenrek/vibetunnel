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
    // Refresh sessions every 3 seconds
    setInterval(() => {
      this.loadSessions();
    }, 3000);
  }

  private async handleSessionCreated(e: CustomEvent) {
    console.log('Session created event detail:', e.detail);
    const sessionId = e.detail.sessionId;
    console.log('Extracted sessionId:', sessionId);
    
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
    
    console.log(`Waiting for session ${sessionId} to appear...`);
    
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      console.log(`Attempt ${attempt + 1}/${maxAttempts} to find session ${sessionId}`);
      await this.loadSessions();
      
      console.log('Current sessions:', this.sessions.map(s => ({ id: s.id, command: s.command })));
      // Try to find by exact ID match first
      let session = this.sessions.find(s => s.id === sessionId);
      
      // If not found by ID, find the most recently created session
      // This works around tty-fwd potentially using different IDs internally
      if (!session && this.sessions.length > 0) {
        console.log('Session not found by ID, trying to find newest session...');
        const sortedSessions = [...this.sessions].sort((a, b) => 
          new Date(b.startedAt).getTime() - new Date(a.startedAt).getTime()
        );
        session = sortedSessions[0];
        console.log('Using newest session:', session.id);
      }
      
      if (session) {
        // Session found, switch to session view
        console.log('Session found, switching to session view');
        this.selectedSession = session;
        this.currentView = 'session';
        // Update URL to include session ID
        this.updateUrl(session.id);
        this.showError('Session created successfully!');
        return;
      }
      
      // Wait before next attempt
      await new Promise(resolve => setTimeout(resolve, delay));
    }
    
    // If we get here, session creation might have failed
    console.log('Session not found after all attempts');
    this.showError('Session created but could not be found. Please refresh.');
  }

  private handleSessionSelect(e: CustomEvent) {
    const session = e.detail as Session;
    console.log('Session selected:', session);
    this.selectedSession = session;
    this.currentView = 'session';
    // Update URL to include session ID
    this.updateUrl(session.id);
  }

  private handleBack() {
    this.currentView = 'list';
    this.selectedSession = null;
    // Update URL to remove session parameter
    this.updateUrl();
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
      // Load the specific session
      this.loadSessionFromUrl(sessionId);
    } else {
      // Show session list
      this.currentView = 'list';
      this.selectedSession = null;
    }
  }

  private async loadSessionFromUrl(sessionId: string) {
    // First ensure sessions are loaded
    if (this.sessions.length === 0) {
      await this.loadSessions();
    }
    
    // Find the session
    const session = this.sessions.find(s => s.id === sessionId);
    if (session) {
      this.selectedSession = session;
      this.currentView = 'session';
    } else {
      // Session not found, go to list view
      this.currentView = 'list';
      this.selectedSession = null;
      // Update URL to remove invalid session ID
      this.updateUrl();
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