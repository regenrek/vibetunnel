import { LitElement, html, PropertyValues } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import './terminal.js';
import type { Terminal } from './terminal.js';

export interface Session {
  id: string;
  command: string;
  workingDir: string;
  name?: string;
  status: 'running' | 'exited';
  exitCode?: number;
  startedAt: string;
  lastModified: string;
  pid?: number;
  waiting?: boolean;
}

@customElement('session-card')
export class SessionCard extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @property({ type: Object }) session!: Session;
  @state() private terminal: Terminal | null = null;
  @state() private killing = false;
  @state() private killingFrame = 0;

  private refreshInterval: number | null = null;
  private killingInterval: number | null = null;

  firstUpdated(changedProperties: PropertyValues) {
    super.firstUpdated(changedProperties);
    this.setupTerminal();
    this.startRefresh();
  }

  updated(changedProperties: PropertyValues) {
    super.updated(changedProperties);

    // Initialize terminal after first render when terminal element exists
    if (!this.terminal && !this.killing) {
      const terminalElement = this.querySelector('vibe-terminal') as Terminal;
      if (terminalElement) {
        this.initializeTerminal();
      }
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this.refreshInterval) {
      clearInterval(this.refreshInterval);
    }
    if (this.killingInterval) {
      clearInterval(this.killingInterval);
    }
    // Terminal cleanup is handled by the component itself
    this.terminal = null;
  }

  private setupTerminal() {
    // Terminal element will be created in render()
    // We'll initialize it in updated() after first render
  }

  private async initializeTerminal() {
    const terminalElement = this.querySelector('vibe-terminal') as Terminal;
    if (!terminalElement) return;

    this.terminal = terminalElement;

    // Configure terminal for card display
    this.terminal.cols = 80;
    this.terminal.rows = 24;
    this.terminal.fontSize = 10; // Smaller font for card display
    this.terminal.fitHorizontally = true; // Fit to card width

    // Load snapshot data
    const url = `/api/sessions/${this.session.id}/snapshot`;

    // Wait a moment for freshly created sessions before connecting
    const sessionAge = Date.now() - new Date(this.session.startedAt).getTime();
    const delay = sessionAge < 5000 ? 2000 : 0; // 2 second delay if session is less than 5 seconds old

    setTimeout(async () => {
      await this.loadSnapshot(url);
    }, delay);
  }

  private async loadSnapshot(url: string) {
    if (!this.terminal) return;

    try {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`Failed to fetch snapshot: ${response.status}`);

      const castContent = await response.text();

      // Clear terminal and write snapshot data
      this.terminal.clear();

      // Parse cast file and write content
      const lines = castContent.trim().split('\n');
      for (const line of lines) {
        if (line.trim()) {
          try {
            const event = JSON.parse(line);
            if (event.length >= 3 && event[1] === 'o') {
              // Output event: [timestamp, 'o', data]
              this.terminal.write(event[2], false); // Don't follow cursor for snapshot
            }
          } catch (_e) {
            // Skip invalid lines
            continue;
          }
        }
      }

      // Scroll to bottom after loading
      this.terminal.queueCallback(() => {
        if (this.terminal) {
          this.terminal.scrollToBottom();
        }
      });
    } catch (error) {
      console.error('Failed to load session snapshot:', error);
    }
  }

  private startRefresh() {
    this.refreshInterval = window.setInterval(async () => {
      if (this.terminal) {
        const url = `/api/sessions/${this.session.id}/snapshot`;
        await this.loadSnapshot(url);
      }
    }, 10000); // Refresh every 10 seconds
  }

  private handleCardClick() {
    this.dispatchEvent(
      new CustomEvent('session-select', {
        detail: this.session,
        bubbles: true,
        composed: true,
      })
    );
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
        method: 'DELETE',
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
    const _isRunning = this.session.status === 'running';

    return html`
      <div
        class="bg-vs-bg border border-vs-border rounded shadow cursor-pointer overflow-hidden ${this
          .killing
          ? 'opacity-60'
          : ''}"
        @click=${this.handleCardClick}
      >
        <!-- Compact Header -->
        <div class="flex justify-between items-center px-3 py-2 border-b border-vs-border">
          <div class="text-vs-text text-xs font-mono pr-2 flex-1 min-w-0">
            <div class="truncate" title="${this.session.name || this.session.command}">
              ${this.session.name || this.session.command}
            </div>
          </div>
          ${this.session.status === 'running'
            ? html`
                <button
                  class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-2 py-0.5 border-none text-xs disabled:opacity-50 flex-shrink-0 rounded"
                  @click=${this.handleKillClick}
                  ?disabled=${this.killing}
                >
                  ${this.killing ? 'killing...' : 'kill'}
                </button>
              `
            : ''}
        </div>

        <!-- Terminal display (main content) -->
        <div class="session-preview bg-black overflow-hidden" style="aspect-ratio: 640/480;">
          ${this.killing
            ? html`
                <div class="w-full h-full flex items-center justify-center text-vs-warning">
                  <div class="text-center font-mono">
                    <div class="text-4xl mb-2">${this.getKillingText()}</div>
                    <div class="text-sm">Killing session...</div>
                  </div>
                </div>
              `
            : html`
                <vibe-terminal
                  .sessionId=${this.session.id}
                  .cols=${80}
                  .rows=${24}
                  .fontSize=${10}
                  .fitHorizontally=${true}
                  class="w-full h-full"
                  style="pointer-events: none;"
                ></vibe-terminal>
              `}
        </div>

        <!-- Compact Footer -->
        <div class="px-3 py-2 text-vs-muted text-xs border-t border-vs-border">
          <div class="flex justify-between items-center min-w-0">
            <span class="${this.getStatusColor()} text-xs flex items-center gap-1 flex-shrink-0">
              <div class="w-2 h-2 rounded-full ${this.getStatusDotColor()}"></div>
              ${this.getStatusText()}
            </span>
            ${this.session.pid
              ? html`
                  <span
                    class="cursor-pointer hover:text-vs-accent transition-colors text-xs flex-shrink-0 ml-2"
                    @click=${this.handlePidClick}
                    title="Click to copy PID"
                  >
                    PID: ${this.session.pid} <span class="opacity-50">(click to copy)</span>
                  </span>
                `
              : ''}
          </div>
          <div class="text-xs opacity-75 min-w-0 mt-1">
            <div class="truncate" title="${this.session.workingDir}">
              ${this.session.workingDir}
            </div>
          </div>
        </div>
      </div>
    `;
  }

  private getStatusText(): string {
    if (this.session.waiting) {
      return 'waiting';
    }
    return this.session.status;
  }

  private getStatusColor(): string {
    if (this.session.waiting) {
      return 'text-vs-muted';
    }
    return this.session.status === 'running' ? 'text-vs-user' : 'text-vs-warning';
  }

  private getStatusDotColor(): string {
    if (this.session.waiting) {
      return 'bg-gray-500';
    }
    return this.session.status === 'running' ? 'bg-green-500' : 'bg-orange-500';
  }
}
