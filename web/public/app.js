var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
import { LitElement, html } from 'lit';
import { customElement, state } from 'lit/decorators.js';
// Import components
import './components/app-header.js';
import './components/session-create-form.js';
import './components/session-list.js';
import './components/session-view.js';
import './components/session-card.js';
let VibeTunnelApp = class VibeTunnelApp extends LitElement {
    constructor() {
        super(...arguments);
        this.errorMessage = '';
        this.sessions = [];
        this.loading = false;
        this.currentView = 'list';
        this.selectedSession = null;
        this.hideExited = true;
        this.showCreateModal = false;
        this.hotReloadWs = null;
        this.handlePopState = (event) => {
            // Handle browser back/forward navigation
            this.parseUrlAndSetState();
        };
    }
    // Disable shadow DOM to use Tailwind
    createRenderRoot() {
        return this;
    }
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
    showError(message) {
        this.errorMessage = message;
        // Clear error after 5 seconds
        setTimeout(() => {
            this.errorMessage = '';
        }, 5000);
    }
    clearError() {
        this.errorMessage = '';
    }
    async loadSessions() {
        this.loading = true;
        try {
            const response = await fetch('/api/sessions');
            if (response.ok) {
                const sessionsData = await response.json();
                this.sessions = sessionsData.map((session) => ({
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
            }
            else {
                this.showError('Failed to load sessions');
            }
        }
        catch (error) {
            console.error('Error loading sessions:', error);
            this.showError('Failed to load sessions');
        }
        finally {
            this.loading = false;
        }
    }
    startAutoRefresh() {
        // Refresh sessions every 3 seconds, but only when showing session list
        setInterval(() => {
            if (this.currentView === 'list') {
                this.loadSessions();
            }
        }, 3000);
    }
    async handleSessionCreated(e) {
        const sessionId = e.detail.sessionId;
        if (!sessionId) {
            this.showError('Session created but ID not found in response');
            return;
        }
        this.showCreateModal = false;
        // Wait for session to appear in the list and then switch to it
        await this.waitForSessionAndSwitch(sessionId);
    }
    async waitForSessionAndSwitch(sessionId) {
        const maxAttempts = 10;
        const delay = 500; // 500ms between attempts
        for (let attempt = 0; attempt < maxAttempts; attempt++) {
            await this.loadSessions();
            // Try to find by exact ID match first
            let session = this.sessions.find(s => s.id === sessionId);
            // If not found by ID, find the most recently created session
            // This works around tty-fwd potentially using different IDs internally
            if (!session && this.sessions.length > 0) {
                const sortedSessions = [...this.sessions].sort((a, b) => new Date(b.startedAt).getTime() - new Date(a.startedAt).getTime());
                session = sortedSessions[0];
            }
            if (session) {
                // Session found, switch to session view
                this.selectedSession = session;
                this.currentView = 'session';
                // Update URL to include session ID
                this.updateUrl(session.id);
                return;
            }
            // Wait before next attempt
            await new Promise(resolve => setTimeout(resolve, delay));
        }
        // If we get here, session creation might have failed
        console.log('Session not found after all attempts');
        this.showError('Session created but could not be found. Please refresh.');
    }
    handleSessionSelect(e) {
        const session = e.detail;
        console.log('Session selected:', session);
        this.selectedSession = session;
        this.currentView = 'session';
        // Update URL to include session ID
        this.updateUrl(session.id);
    }
    handleBack() {
        this.currentView = 'list';
        this.selectedSession = null;
        // Update URL to remove session parameter
        this.updateUrl();
    }
    handleSessionKilled(e) {
        console.log('Session killed:', e.detail);
        this.loadSessions(); // Refresh the list
    }
    handleRefresh() {
        this.loadSessions();
    }
    handleError(e) {
        this.showError(e.detail);
    }
    handleHideExitedChange(e) {
        this.hideExited = e.detail;
    }
    handleCreateSession() {
        this.showCreateModal = true;
    }
    handleCreateModalClose() {
        this.showCreateModal = false;
    }
    // URL Routing methods
    setupRouting() {
        // Handle browser back/forward navigation
        window.addEventListener('popstate', this.handlePopState.bind(this));
        // Parse initial URL and set state
        this.parseUrlAndSetState();
    }
    parseUrlAndSetState() {
        const url = new URL(window.location.href);
        const sessionId = url.searchParams.get('session');
        if (sessionId) {
            // Load the specific session
            this.loadSessionFromUrl(sessionId);
        }
        else {
            // Show session list
            this.currentView = 'list';
            this.selectedSession = null;
        }
    }
    async loadSessionFromUrl(sessionId) {
        // First ensure sessions are loaded
        if (this.sessions.length === 0) {
            await this.loadSessions();
        }
        // Find the session
        const session = this.sessions.find(s => s.id === sessionId);
        if (session) {
            this.selectedSession = session;
            this.currentView = 'session';
        }
        else {
            // Session not found, go to list view
            this.currentView = 'list';
            this.selectedSession = null;
            // Update URL to remove invalid session ID
            this.updateUrl();
        }
    }
    updateUrl(sessionId) {
        const url = new URL(window.location.href);
        if (sessionId) {
            url.searchParams.set('session', sessionId);
        }
        else {
            url.searchParams.delete('session');
        }
        // Update browser URL without triggering page reload
        window.history.pushState(null, '', url.toString());
    }
    setupHotReload() {
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
        return html `
      <!-- Error notification overlay -->
      ${this.errorMessage ? html `
        <div class="fixed top-4 right-4 z-50">
          <div class="bg-vs-warning text-vs-bg px-4 py-2 rounded shadow-lg font-mono text-sm">
            ${this.errorMessage}
            <button @click=${this.clearError} class="ml-2 text-vs-bg hover:text-vs-muted">✕</button>
          </div>
        </div>
      ` : ''}

      <!-- Main content -->
      ${this.currentView === 'session' ? html `
        <session-view
          .session=${this.selectedSession}
          @back=${this.handleBack}
        ></session-view>
      ` : html `
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
};
__decorate([
    state()
], VibeTunnelApp.prototype, "errorMessage", void 0);
__decorate([
    state()
], VibeTunnelApp.prototype, "sessions", void 0);
__decorate([
    state()
], VibeTunnelApp.prototype, "loading", void 0);
__decorate([
    state()
], VibeTunnelApp.prototype, "currentView", void 0);
__decorate([
    state()
], VibeTunnelApp.prototype, "selectedSession", void 0);
__decorate([
    state()
], VibeTunnelApp.prototype, "hideExited", void 0);
__decorate([
    state()
], VibeTunnelApp.prototype, "showCreateModal", void 0);
VibeTunnelApp = __decorate([
    customElement('vibetunnel-app')
], VibeTunnelApp);
export { VibeTunnelApp };
//# sourceMappingURL=app.js.map