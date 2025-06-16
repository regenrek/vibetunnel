"use strict";
var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
var __metadata = (this && this.__metadata) || function (k, v) {
    if (typeof Reflect === "object" && typeof Reflect.metadata === "function") return Reflect.metadata(k, v);
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.SessionList = void 0;
const lit_1 = require("lit");
const decorators_js_1 = require("lit/decorators.js");
const repeat_js_1 = require("lit/directives/repeat.js");
require("./session-create-form.js");
require("./session-card.js");
let SessionList = class SessionList extends lit_1.LitElement {
    constructor() {
        super(...arguments);
        this.sessions = [];
        this.loading = false;
        this.hideExited = true;
        this.showCreateModal = false;
        this.killingSessionIds = new Set();
        this.cleaningExited = false;
    }
    // Disable shadow DOM to use Tailwind
    createRenderRoot() {
        return this;
    }
    handleRefresh() {
        this.dispatchEvent(new CustomEvent('refresh'));
    }
    handleSessionSelect(e) {
        const session = e.detail;
        window.location.search = `?session=${session.id}`;
    }
    async handleSessionKill(e) {
        const sessionId = e.detail;
        if (this.killingSessionIds.has(sessionId))
            return;
        this.killingSessionIds.add(sessionId);
        this.requestUpdate();
        try {
            const response = await fetch(`/api/sessions/${sessionId}`, {
                method: 'DELETE'
            });
            if (response.ok) {
                this.dispatchEvent(new CustomEvent('session-killed', { detail: sessionId }));
            }
            else {
                this.dispatchEvent(new CustomEvent('error', { detail: 'Failed to kill session' }));
            }
        }
        catch (error) {
            console.error('Error killing session:', error);
            this.dispatchEvent(new CustomEvent('error', { detail: 'Failed to kill session' }));
        }
        finally {
            this.killingSessionIds.delete(sessionId);
            this.requestUpdate();
        }
    }
    async handleCleanupExited() {
        if (this.cleaningExited)
            return;
        this.cleaningExited = true;
        this.requestUpdate();
        try {
            const response = await fetch('/api/cleanup-exited', {
                method: 'POST'
            });
            if (response.ok) {
                this.dispatchEvent(new CustomEvent('refresh'));
            }
            else {
                this.dispatchEvent(new CustomEvent('error', { detail: 'Failed to cleanup exited sessions' }));
            }
        }
        catch (error) {
            console.error('Error cleaning up exited sessions:', error);
            this.dispatchEvent(new CustomEvent('error', { detail: 'Failed to cleanup exited sessions' }));
        }
        finally {
            this.cleaningExited = false;
            this.requestUpdate();
        }
    }
    render() {
        const filteredSessions = this.hideExited
            ? this.sessions.filter(session => session.status !== 'exited')
            : this.sessions;
        return (0, lit_1.html) `
      <div class="font-mono text-sm p-4">
        <!-- Controls -->
        <div class="mb-4 flex items-center justify-between">
          ${!this.hideExited ? (0, lit_1.html) `
            <button
              class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-4 py-2 border-none rounded transition-colors disabled:opacity-50"
              @click=${this.handleCleanupExited}
              ?disabled=${this.cleaningExited || this.sessions.filter(s => s.status === 'exited').length === 0}
            >
              ${this.cleaningExited ? '[~] CLEANING...' : 'CLEAN EXITED'}
            </button>
          ` : (0, lit_1.html) `<div></div>`}

          <label class="flex items-center gap-2 text-vs-text text-sm cursor-pointer hover:text-vs-accent transition-colors">
            <div class="relative">
              <input
                type="checkbox"
                class="sr-only"
                .checked=${this.hideExited}
                @change=${(e) => this.dispatchEvent(new CustomEvent('hide-exited-change', { detail: e.target.checked }))}
              >
              <div class="w-4 h-4 border border-vs-border rounded bg-vs-bg-secondary flex items-center justify-center transition-all ${this.hideExited ? 'bg-vs-user border-vs-user' : 'hover:border-vs-accent'}">
                ${this.hideExited ? (0, lit_1.html) `
                  <svg class="w-3 h-3 text-vs-bg" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd"></path>
                  </svg>
                ` : ''}
              </div>
            </div>
            hide exited
          </label>
        </div>
        ${filteredSessions.length === 0 ? (0, lit_1.html) `
          <div class="text-vs-muted text-center py-8">
            ${this.loading ? 'Loading sessions...' : (this.hideExited && this.sessions.length > 0 ? 'No running sessions' : 'No sessions found')}
          </div>
        ` : (0, lit_1.html) `
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            ${(0, repeat_js_1.repeat)(filteredSessions, (session) => session.id, (session) => (0, lit_1.html) `
              <session-card 
                .session=${session}
                @session-select=${this.handleSessionSelect}
                @session-kill=${this.handleSessionKill}>
              </session-card>
            `)}
          </div>
        `}

        <session-create-form
          .visible=${this.showCreateModal}
          @session-created=${(e) => this.dispatchEvent(new CustomEvent('session-created', { detail: e.detail }))}
          @cancel=${() => this.dispatchEvent(new CustomEvent('create-modal-close'))}
          @error=${(e) => this.dispatchEvent(new CustomEvent('error', { detail: e.detail }))}
        ></session-create-form>
      </div>
    `;
    }
};
exports.SessionList = SessionList;
__decorate([
    (0, decorators_js_1.property)({ type: Array }),
    __metadata("design:type", Array)
], SessionList.prototype, "sessions", void 0);
__decorate([
    (0, decorators_js_1.property)({ type: Boolean }),
    __metadata("design:type", Object)
], SessionList.prototype, "loading", void 0);
__decorate([
    (0, decorators_js_1.property)({ type: Boolean }),
    __metadata("design:type", Object)
], SessionList.prototype, "hideExited", void 0);
__decorate([
    (0, decorators_js_1.property)({ type: Boolean }),
    __metadata("design:type", Object)
], SessionList.prototype, "showCreateModal", void 0);
__decorate([
    (0, decorators_js_1.state)(),
    __metadata("design:type", Object)
], SessionList.prototype, "killingSessionIds", void 0);
__decorate([
    (0, decorators_js_1.state)(),
    __metadata("design:type", Object)
], SessionList.prototype, "cleaningExited", void 0);
exports.SessionList = SessionList = __decorate([
    (0, decorators_js_1.customElement)('session-list')
], SessionList);
//# sourceMappingURL=session-list.js.map