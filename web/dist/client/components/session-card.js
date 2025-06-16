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
exports.SessionCard = void 0;
const lit_1 = require("lit");
const decorators_js_1 = require("lit/decorators.js");
const renderer_js_1 = require("../renderer.js");
let SessionCard = class SessionCard extends lit_1.LitElement {
    constructor() {
        super(...arguments);
        this.renderer = null;
        this.refreshInterval = null;
    }
    // Disable shadow DOM to use Tailwind
    createRenderRoot() {
        return this;
    }
    firstUpdated(changedProperties) {
        super.firstUpdated(changedProperties);
        this.createRenderer();
        this.startRefresh();
    }
    disconnectedCallback() {
        super.disconnectedCallback();
        if (this.refreshInterval) {
            clearInterval(this.refreshInterval);
        }
        if (this.renderer) {
            this.renderer.dispose();
            this.renderer = null;
        }
    }
    createRenderer() {
        const playerElement = this.querySelector('#player');
        if (!playerElement)
            return;
        // Create single renderer for this card - use larger dimensions for better preview
        this.renderer = new renderer_js_1.Renderer(playerElement, 80, 24, 10000, 8, true);
        // Always use snapshot endpoint for cards
        const url = `/api/sessions/${this.session.id}/snapshot`;
        // Wait a moment for freshly created sessions before connecting
        const sessionAge = Date.now() - new Date(this.session.startedAt).getTime();
        const delay = sessionAge < 5000 ? 2000 : 0; // 2 second delay if session is less than 5 seconds old
        setTimeout(() => {
            if (this.renderer) {
                this.renderer.loadFromUrl(url, false); // false = not a stream, use snapshot
                // Disable pointer events so clicks pass through to the card
                this.renderer.setPointerEventsEnabled(false);
            }
        }, delay);
    }
    startRefresh() {
        this.refreshInterval = window.setInterval(() => {
            if (this.renderer) {
                const url = `/api/sessions/${this.session.id}/snapshot`;
                this.renderer.loadFromUrl(url, false);
                // Ensure pointer events stay disabled after refresh
                this.renderer.setPointerEventsEnabled(false);
            }
        }, 10000); // Refresh every 10 seconds
    }
    handleCardClick() {
        this.dispatchEvent(new CustomEvent('session-select', {
            detail: this.session,
            bubbles: true,
            composed: true
        }));
    }
    handleKillClick(e) {
        e.stopPropagation();
        e.preventDefault();
        this.dispatchEvent(new CustomEvent('session-kill', {
            detail: this.session.id,
            bubbles: true,
            composed: true
        }));
    }
    async handlePidClick(e) {
        e.stopPropagation();
        e.preventDefault();
        if (this.session.pid) {
            try {
                await navigator.clipboard.writeText(this.session.pid.toString());
                console.log('PID copied to clipboard:', this.session.pid);
            }
            catch (error) {
                console.error('Failed to copy PID to clipboard:', error);
                // Fallback: select text manually
                this.fallbackCopyToClipboard(this.session.pid.toString());
            }
        }
    }
    fallbackCopyToClipboard(text) {
        const textArea = document.createElement('textarea');
        textArea.value = text;
        document.body.appendChild(textArea);
        textArea.focus();
        textArea.select();
        try {
            document.execCommand('copy');
            console.log('PID copied to clipboard (fallback):', text);
        }
        catch (error) {
            console.error('Fallback copy failed:', error);
        }
        document.body.removeChild(textArea);
    }
    render() {
        const isRunning = this.session.status === 'running';
        return (0, lit_1.html) `
      <div class="bg-vs-bg border border-vs-border rounded shadow cursor-pointer overflow-hidden"
           @click=${this.handleCardClick}>
        <!-- Compact Header -->
        <div class="flex justify-between items-center px-3 py-2 border-b border-vs-border">
          <div class="text-vs-text text-xs font-mono truncate pr-2 flex-1">${this.session.command}</div>
          ${this.session.status === 'running' ? (0, lit_1.html) `
            <button
              class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-2 py-0.5 border-none text-xs disabled:opacity-50 flex-shrink-0 rounded"
              @click=${this.handleKillClick}
            >
              ${this.session.status === 'running' ? 'kill' : 'clean'}
            </button>
          ` : ''}
        </div>

        <!-- XTerm renderer (main content) -->
        <div class="session-preview bg-black overflow-hidden" style="aspect-ratio: 640/480;">
          <div id="player" class="w-full h-full"></div>
        </div>

        <!-- Compact Footer -->
        <div class="px-3 py-2 text-vs-muted text-xs border-t border-vs-border">
          <div class="flex justify-between items-center">
            <span class="${this.session.status === 'running' ? 'text-vs-user' : 'text-vs-warning'} text-xs">
              ${this.session.status}
            </span>
            ${this.session.pid ? (0, lit_1.html) `
              <span 
                class="cursor-pointer hover:text-vs-accent transition-colors"
                @click=${this.handlePidClick}
                title="Click to copy PID"
              >
                PID: ${this.session.pid} <span class="opacity-50">(click to copy)</span>
              </span>
            ` : ''}
          </div>
          <div class="truncate text-xs opacity-75" title="${this.session.workingDir}">${this.session.workingDir}</div>
        </div>
      </div>
    `;
    }
};
exports.SessionCard = SessionCard;
__decorate([
    (0, decorators_js_1.property)({ type: Object }),
    __metadata("design:type", Object)
], SessionCard.prototype, "session", void 0);
__decorate([
    (0, decorators_js_1.state)(),
    __metadata("design:type", Object)
], SessionCard.prototype, "renderer", void 0);
exports.SessionCard = SessionCard = __decorate([
    (0, decorators_js_1.customElement)('session-card')
], SessionCard);
//# sourceMappingURL=session-card.js.map