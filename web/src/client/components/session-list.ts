import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { repeat } from 'lit/directives/repeat.js';
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

  @state() private cleaningExited = false;
  private previousRunningCount = 0;

  private handleRefresh() {
    this.dispatchEvent(new CustomEvent('refresh'));
  }

  private handleSessionSelect(e: CustomEvent) {
    const session = e.detail as Session;
    window.location.search = `?session=${session.id}`;
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
        ${!this.hideExited && this.sessions.filter(s => s.status === 'exited').length > 0 ? html`
          <div class="mb-4">
            <button
              class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-4 py-2 border-none rounded transition-colors disabled:opacity-50"
              @click=${this.handleCleanupExited}
              ?disabled=${this.cleaningExited}
            >
              ${this.cleaningExited ? '[~] CLEANING...' : 'CLEAN EXITED'}
            </button>
          </div>
        ` : ''}
        ${filteredSessions.length === 0 ? html`
          <div class="text-vs-muted text-center py-8">
            ${this.loading ? 'Loading sessions...' : (this.hideExited && this.sessions.length > 0 ? 'No running sessions' : 'No sessions found')}
          </div>
        ` : html`
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            ${repeat(filteredSessions, (session) => session.id, (session) => html`
              <session-card 
                .session=${session}
                @session-select=${this.handleSessionSelect}>
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