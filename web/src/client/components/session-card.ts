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
  @state() private killing = false;
  @state() private killingFrame = 0;
  
  private refreshInterval: number | null = null;
  private killingInterval: number | null = null;

  firstUpdated(changedProperties: PropertyValues) {
    super.firstUpdated(changedProperties);
    this.createRenderer();
    this.startRefresh();
  }


  disconnectedCallback() {
    super.disconnectedCallback();
    if (this.refreshInterval) {
      clearInterval(this.refreshInterval);
    }
    if (this.killingInterval) {
      clearInterval(this.killingInterval);
    }
    if (this.renderer) {
      this.renderer.dispose();
      this.renderer = null;
    }
  }

  private createRenderer() {
    const playerElement = this.querySelector('#player') as HTMLElement;
    if (!playerElement) return;

    // Create single renderer for this card
    this.renderer = new Renderer(playerElement, 80, 24, 10000, 4, true);

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
        // Force fit after loading to ensure proper scaling in card
        setTimeout(() => {
          if (this.renderer) {
            this.renderer.fit();
          }
        }, 100);
      }
    }, delay);
  }

  private startRefresh() {
    this.refreshInterval = window.setInterval(() => {
      if (this.renderer) {
        const url = `/api/sessions/${this.session.id}/snapshot`;
        this.renderer.loadFromUrl(url, false);
        // Ensure pointer events stay disabled after refresh
        this.renderer.setPointerEventsEnabled(false);
        // Force fit after refresh to maintain proper scaling
        setTimeout(() => {
          if (this.renderer) {
            this.renderer.fit();
          }
        }, 100);
      }
    }, 10000); // Refresh every 10 seconds
  }

  private handleCardClick() {
    this.dispatchEvent(new CustomEvent('session-select', {
      detail: this.session,
      bubbles: true,
      composed: true
    }));
  }

  private async handleKillClick(e: Event) {
    e.stopPropagation();
    e.preventDefault();
    
    // Start killing animation
    this.killing = true;
    this.killingFrame = 0;
    this.killingInterval = window.setInterval(() => {
      this.killingFrame = (this.killingFrame + 1) % 4;
      this.requestUpdate();
    }, 200);

    // Send kill request
    try {
      const response = await fetch(`/api/sessions/${this.session.id}`, {
        method: 'DELETE'
      });

      if (!response.ok) {
        console.error('Failed to kill session');
        // Stop animation on error
        this.stopKillingAnimation();
      }
      // Note: We don't stop the animation on success - let the session list refresh handle it
    } catch (error) {
      console.error('Error killing session:', error);
      // Stop animation on error
      this.stopKillingAnimation();
    }
  }

  private stopKillingAnimation() {
    this.killing = false;
    if (this.killingInterval) {
      clearInterval(this.killingInterval);
      this.killingInterval = null;
    }
  }

  private getKillingText(): string {
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    return frames[this.killingFrame % frames.length];
  }

  private async handlePidClick(e: Event) {
    e.stopPropagation();
    e.preventDefault();
    
    if (this.session.pid) {
      try {
        await navigator.clipboard.writeText(this.session.pid.toString());
        console.log('PID copied to clipboard:', this.session.pid);
      } catch (error) {
        console.error('Failed to copy PID to clipboard:', error);
        // Fallback: select text manually
        this.fallbackCopyToClipboard(this.session.pid.toString());
      }
    }
  }

  private fallbackCopyToClipboard(text: string) {
    const textArea = document.createElement('textarea');
    textArea.value = text;
    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();
    try {
      document.execCommand('copy');
      console.log('PID copied to clipboard (fallback):', text);
    } catch (error) {
      console.error('Fallback copy failed:', error);
    }
    document.body.removeChild(textArea);
  }

  render() {
    const isRunning = this.session.status === 'running';
    
    return html`
      <div class="bg-vs-bg border border-vs-border rounded shadow cursor-pointer overflow-hidden ${this.killing ? 'opacity-60' : ''}"
           @click=${this.handleCardClick}>
        <!-- Compact Header -->
        <div class="flex justify-between items-center px-3 py-2 border-b border-vs-border">
          <div class="text-vs-text text-xs font-mono truncate pr-2 flex-1">${this.session.command}</div>
          ${this.session.status === 'running' ? html`
            <button
              class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-2 py-0.5 border-none text-xs disabled:opacity-50 flex-shrink-0 rounded"
              @click=${this.handleKillClick}
              ?disabled=${this.killing}
            >
              ${this.killing ? 'killing...' : 'kill'}
            </button>
          ` : ''}
        </div>

        <!-- XTerm renderer (main content) -->
        <div class="session-preview bg-black overflow-hidden" style="aspect-ratio: 640/480;">
          ${this.killing ? html`
            <div class="w-full h-full flex items-center justify-center text-vs-warning">
              <div class="text-center font-mono">
                <div class="text-4xl mb-2">${this.getKillingText()}</div>
                <div class="text-sm">Killing session...</div>
              </div>
            </div>
          ` : html`
            <div id="player" class="w-full h-full"></div>
          `}
        </div>

        <!-- Compact Footer -->
        <div class="px-3 py-2 text-vs-muted text-xs border-t border-vs-border">
          <div class="flex justify-between items-center">
            <span class="${this.session.status === 'running' ? 'text-vs-user' : 'text-vs-warning'} text-xs">
              ${this.session.status}
            </span>
            ${this.session.pid ? html`
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

}