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
let VibeTunnelAppNew = class VibeTunnelAppNew extends LitElement {
    constructor() {
        super(...arguments);
        this.errorMessage = '';
        this.sessions = [];
        this.loading = false;
        this.hotReloadWs = null;
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
    }
    disconnectedCallback() {
        super.disconnectedCallback();
        if (this.hotReloadWs) {
            this.hotReloadWs.close();
        }
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
        // Refresh sessions every 3 seconds
        setInterval(() => {
            this.loadSessions();
        }, 3000);
    }
    handleSessionCreated(e) {
        console.log('Session created:', e.detail);
        this.showError('Session created successfully!');
        this.loadSessions(); // Refresh the list
    }
    handleSessionSelect(e) {
        const session = e.detail;
        console.log('Session selected:', session);
        this.showError(`Terminal view not implemented yet for session: ${session.id}`);
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
      <div class="max-w-4xl mx-auto">
        <app-header></app-header>
        <session-list
          .sessions=${this.sessions}
          .loading=${this.loading}
          @session-select=${this.handleSessionSelect}
          @session-killed=${this.handleSessionKilled}
          @session-created=${this.handleSessionCreated}
          @refresh=${this.handleRefresh}
          @error=${this.handleError}
        ></session-list>
      </div>
    `;
    }
};
__decorate([
    state()
], VibeTunnelAppNew.prototype, "errorMessage", void 0);
__decorate([
    state()
], VibeTunnelAppNew.prototype, "sessions", void 0);
__decorate([
    state()
], VibeTunnelAppNew.prototype, "loading", void 0);
VibeTunnelAppNew = __decorate([
    customElement('vibetunnel-app-new')
], VibeTunnelAppNew);
export { VibeTunnelAppNew };
//# sourceMappingURL=app-new.js.map