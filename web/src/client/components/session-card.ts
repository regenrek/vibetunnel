import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import './vibe-terminal-buffer.js';
import './copy-icon.js';

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
  width?: number;
  height?: number;
}

@customElement('session-card')
export class SessionCard extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @property({ type: Object }) session!: Session;
  @state() private killing = false;
  @state() private killingFrame = 0;
  @state() private hasEscPrompt = false;

  private killingInterval: number | null = null;

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this.killingInterval) {
      clearInterval(this.killingInterval);
    }
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

  private handleEscPromptChange(event: CustomEvent) {
    this.hasEscPrompt = event.detail.hasEscPrompt;
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
        const errorData = await response.text();
        console.error('Failed to kill session:', errorData);
        throw new Error(`Kill failed: ${response.status}`);
      }

      // Kill succeeded - dispatch event to notify parent components
      this.dispatchEvent(
        new CustomEvent('session-killed', {
          detail: {
            sessionId: this.session.id,
            session: this.session,
          },
          bubbles: true,
          composed: true,
        })
      );

      console.log(`Session ${this.session.id} killed successfully`);
    } catch (error) {
      console.error('Error killing session:', error);

      // Show error to user (keep animation to indicate something went wrong)
      this.dispatchEvent(
        new CustomEvent('session-kill-error', {
          detail: {
            sessionId: this.session.id,
            error: error instanceof Error ? error.message : 'Unknown error',
          },
          bubbles: true,
          composed: true,
        })
      );
    } finally {
      // Stop animation in all cases
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
      console.log('Text copied to clipboard (fallback):', text);
    } catch (error) {
      console.error('Fallback copy failed:', error);
    }
    document.body.removeChild(textArea);
  }

  private async handlePathClick(e: Event) {
    e.stopPropagation();
    e.preventDefault();

    try {
      await navigator.clipboard.writeText(this.session.workingDir);
      console.log('Path copied to clipboard:', this.session.workingDir);
    } catch (error) {
      console.error('Failed to copy path to clipboard:', error);
      // Fallback: select text manually
      this.fallbackCopyToClipboard(this.session.workingDir);
    }
  }

  render() {
    return html`
      <div
        class="card cursor-pointer overflow-hidden ${this.killing ? 'opacity-60' : ''} ${this
          .hasEscPrompt
          ? 'border-2 border-status-warning'
          : ''}"
        @click=${this.handleCardClick}
      >
        <!-- Compact Header -->
        <div
          class="flex justify-between items-center px-3 py-2 border-b border-dark-border bg-dark-bg-tertiary"
        >
          <div class="text-xs font-mono pr-2 flex-1 min-w-0 text-accent-green">
            <div class="truncate" title="${this.session.name || this.session.command}">
              ${this.session.name || this.session.command}
            </div>
          </div>
          ${this.session.status === 'running'
            ? html`
                <button
                  class="btn-ghost text-status-error disabled:opacity-50 flex-shrink-0 p-1 rounded-full hover:bg-status-error hover:bg-opacity-20 transition-all"
                  @click=${this.handleKillClick}
                  ?disabled=${this.killing}
                  title="Kill session"
                >
                  ${this.killing
                    ? html`<span class="block w-5 h-5 flex items-center justify-center"
                        >${this.getKillingText()}</span
                      >`
                    : html`
                        <svg
                          class="w-5 h-5"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                          xmlns="http://www.w3.org/2000/svg"
                        >
                          <circle cx="12" cy="12" r="10" stroke-width="2" />
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M15 9l-6 6m0-6l6 6"
                          />
                        </svg>
                      `}
                </button>
              `
            : ''}
        </div>

        <!-- Terminal display (main content) -->
        <div class="session-preview bg-dark-bg overflow-hidden" style="aspect-ratio: 640/480;">
          ${this.killing
            ? html`
                <div class="w-full h-full flex items-center justify-center text-status-error">
                  <div class="text-center font-mono">
                    <div class="text-4xl mb-2">${this.getKillingText()}</div>
                    <div class="text-sm">Killing session...</div>
                  </div>
                </div>
              `
            : html`
                <vibe-terminal-buffer
                  .sessionId=${this.session.id}
                  class="w-full h-full"
                  style="pointer-events: none;"
                  @esc-prompt-change=${this.handleEscPromptChange}
                ></vibe-terminal-buffer>
              `}
        </div>

        <!-- Compact Footer -->
        <div
          class="px-3 py-2 text-dark-text-muted text-xs border-t border-dark-border bg-dark-bg-tertiary"
        >
          <div class="flex justify-between items-center min-w-0">
            <span class="${this.getStatusColor()} text-xs flex items-center gap-1 flex-shrink-0">
              <div class="w-2 h-2 rounded-full ${this.getStatusDotColor()}"></div>
              ${this.getStatusText()}
            </span>
            ${this.session.pid
              ? html`
                  <span
                    class="cursor-pointer hover:text-accent-green transition-colors text-xs flex-shrink-0 ml-2 inline-flex items-center gap-1"
                    @click=${this.handlePidClick}
                    title="Click to copy PID"
                  >
                    PID: ${this.session.pid} <copy-icon size="14"></copy-icon>
                  </span>
                `
              : ''}
          </div>
          <div class="text-xs opacity-75 min-w-0 mt-1">
            <div
              class="truncate cursor-pointer hover:text-accent-green transition-colors inline-flex items-center gap-1 max-w-full"
              title="Click to copy path"
              @click=${this.handlePathClick}
            >
              <span class="truncate">${this.session.workingDir}</span>
              <copy-icon size="12" class="flex-shrink-0"></copy-icon>
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
      return 'text-dark-text-muted';
    }
    return this.session.status === 'running' ? 'text-status-success' : 'text-status-warning';
  }

  private getStatusDotColor(): string {
    if (this.session.waiting) {
      return 'bg-dark-text-muted';
    }
    return this.session.status === 'running' ? 'bg-status-success' : 'bg-status-warning';
  }
}
