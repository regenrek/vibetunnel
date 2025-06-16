import { LitElement, html, css, PropertyValues } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { Renderer } from '../renderer.js';

export interface Session {
  id: string;
  command: string;
  workingDir: string;
  status: 'running' | 'exited';
  exitCode?: number;
  startedAt: string;
  lastModified: string;
  pid?: number;
}

@customElement('session-card')
export class SessionCard extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @property({ type: Object }) session!: Session;
  @state() private renderer: Renderer | null = null;

  firstUpdated(changedProperties: PropertyValues) {
    super.firstUpdated(changedProperties);
    this.createRenderer();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this.renderer) {
      this.renderer.dispose();
      this.renderer = null;
    }
  }

  private createRenderer() {
    const playerElement = this.querySelector('#player') as HTMLElement;
    if (!playerElement) return;

    // Create single renderer for this card
    this.renderer = new Renderer(playerElement, 40, 12, 10000, 6, true);

    // Connect to appropriate endpoint based on session status
    const isStream = this.session.status !== 'exited';
    const url = isStream
      ? `/api/sessions/${this.session.id}/stream`
      : `/api/sessions/${this.session.id}/snapshot`;

    // Wait a moment for freshly created sessions before connecting
    const sessionAge = Date.now() - new Date(this.session.startedAt).getTime();
    const delay = sessionAge < 5000 ? 2000 : 0; // 2 second delay if session is less than 5 seconds old

    setTimeout(() => {
      if (this.renderer) {
        this.renderer.loadFromUrl(url, isStream);
      }
    }, delay);
  }

  private handleCardClick() {
    this.dispatchEvent(new CustomEvent('session-select', {
      detail: this.session,
      bubbles: true,
      composed: true
    }));
  }

  private handleKillClick(e: Event) {
    e.stopPropagation();
    this.dispatchEvent(new CustomEvent('session-kill', {
      detail: this.session.id,
      bubbles: true,
      composed: true
    }));
  }

  render() {
    const isRunning = this.session.status === 'running';
    const statusColor = isRunning ? 'text-green-400' : 'text-red-400';

    return html`
      <div class="bg-vs-bg border border-vs-border rounded shadow cursor-pointer overflow-hidden"
           @click=${this.handleCardClick}>
        <!-- Session Info Header -->
        <div class="p-3 border-b border-vs-border">
          <div class="flex justify-between items-start mb-2">
            <div class="flex-1 min-w-0">
              <h3 class="text-vs-foreground font-mono text-sm truncate">
                ${this.session.command}
              </h3>
              <p class="text-vs-muted text-xs truncate mt-1">
                ${this.session.workingDir}
              </p>
            </div>
            <div class="flex items-center gap-2 ml-2">
              <span class="${statusColor} text-xs font-medium uppercase tracking-wide">
                ${this.session.status}
              </span>
              ${isRunning ? html`
                <button @click=${this.handleKillClick}
                        class="bg-red-600 hover:bg-red-700 text-white text-xs px-2 py-1 rounded">
                  kill
                </button>
              ` : ''}
            </div>
          </div>
        </div>

        <!-- Terminal Preview -->
        <div class="h-32 bg-vs-bg">
          <div id="player" class="w-full h-full"></div>
        </div>

        <!-- Session Metadata -->
        <div class="p-2 text-xs text-vs-muted border-t border-vs-border">
          <div class="flex justify-between">
            <span>Started: ${new Date(this.session.startedAt).toLocaleString()}</span>
            ${this.session.pid ? html`<span>PID: ${this.session.pid}</span>` : ''}
          </div>
        </div>
      </div>
    `;
  }
}