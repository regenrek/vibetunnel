import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import './session-create-form.js';
import './session-card.js';

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

@customElement('session-list')
export class SessionList extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @property({ type: Array }) sessions: Session[] = [];
  @property({ type: Boolean }) loading = false;
  @property({ type: Boolean }) hideExited = true;
  @property({ type: Boolean }) showCreateModal = false;

  @state() private killingSessionIds = new Set<string>();
  @state() private cleaningExited = false;

  private handleRefresh() {
    this.dispatchEvent(new CustomEvent('refresh'));
  }

  private handleSessionSelect(e: CustomEvent) {
    this.dispatchEvent(new CustomEvent('session-select', {
      detail: e.detail,
      bubbles: true,
      composed: true
    }));
  }

  private async handleSessionKill(e: CustomEvent) {
    const sessionId = e.detail;
    if (this.killingSessionIds.has(sessionId)) return;
    
    this.killingSessionIds.add(sessionId);
    this.requestUpdate();

    try {
      const response = await fetch(`/api/sessions/${sessionId}/kill`, {
        method: 'POST'
      });

      if (response.ok) {
        this.dispatchEvent(new CustomEvent('session-killed', { detail: sessionId }));
      } else {
        this.dispatchEvent(new CustomEvent('error', { detail: 'Failed to kill session' }));
      }
    } catch (error) {
      console.error('Error killing session:', error);
      this.dispatchEvent(new CustomEvent('error', { detail: 'Failed to kill session' }));
    } finally {
      this.killingSessionIds.delete(sessionId);
      this.requestUpdate();
    }
  }

  private async handleCleanupExited() {
    if (this.cleaningExited) return;
    
    this.cleaningExited = true;
    this.requestUpdate();

    try {
      const response = await fetch('/api/cleanup-exited', {
        method: 'POST'
      });

      if (response.ok) {
        this.dispatchEvent(new CustomEvent('refresh'));
      } else {
        this.dispatchEvent(new CustomEvent('error', { detail: 'Failed to cleanup exited sessions' }));
      }
    } catch (error) {
      console.error('Error cleaning up exited sessions:', error);
      this.dispatchEvent(new CustomEvent('error', { detail: 'Failed to cleanup exited sessions' }));
    } finally {
      this.cleaningExited = false;
      this.requestUpdate();
    }
  }

  render() {
    const filteredSessions = this.hideExited 
      ? this.sessions.filter(session => session.status !== 'exited')
      : this.sessions;

    return html`
      <div class="font-mono text-sm p-4">
        <!-- Controls -->
        <div class="mb-4 flex items-center justify-between">
          ${!this.hideExited ? html`
            <button
              class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-4 py-2 border-none rounded transition-colors disabled:opacity-50"
              @click=${this.handleCleanupExited}
              ?disabled=${this.cleaningExited || this.sessions.filter(s => s.status === 'exited').length === 0}
            >
              ${this.cleaningExited ? '[~] CLEANING...' : 'CLEAN EXITED'}
            </button>
          ` : html`<div></div>`}

          <label class="flex items-center gap-2 text-vs-text text-sm cursor-pointer hover:text-vs-accent transition-colors">
            <div class="relative">
              <input
                type="checkbox"
                class="sr-only"
                .checked=${this.hideExited}
                @change=${(e: Event) => this.dispatchEvent(new CustomEvent('hide-exited-change', { detail: (e.target as HTMLInputElement).checked }))}
              >
              <div class="w-4 h-4 border border-vs-border rounded bg-vs-bg-secondary flex items-center justify-center transition-all ${
                this.hideExited ? 'bg-vs-user border-vs-user' : 'hover:border-vs-accent'
              }">
                ${this.hideExited ? html`
                  <svg class="w-3 h-3 text-vs-bg" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd"></path>
                  </svg>
                ` : ''}
              </div>
            </div>
            hide exited
          </label>
        </div>
        ${filteredSessions.length === 0 ? html`
          <div class="text-vs-muted text-center py-8">
            ${this.loading ? 'Loading sessions...' : (this.hideExited && this.sessions.length > 0 ? 'No running sessions' : 'No sessions found')}
          </div>
        ` : html`
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            ${filteredSessions.map(session => html`
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
          @session-created=${(e: CustomEvent) => this.dispatchEvent(new CustomEvent('session-created', { detail: e.detail }))}
          @cancel=${() => this.dispatchEvent(new CustomEvent('create-modal-close'))}
          @error=${(e: CustomEvent) => this.dispatchEvent(new CustomEvent('error', { detail: e.detail }))}
        ></session-create-form>
      </div>
    `;
  }
}