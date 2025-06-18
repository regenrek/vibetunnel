import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { repeat } from 'lit/directives/repeat.js';
import './session-create-form.js';
import './session-card.js';

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

  private handleSessionKilled(e: CustomEvent) {
    const { sessionId } = e.detail;
    console.log(`Session ${sessionId} killed, updating session list...`);

    // Immediately remove the session from the local state for instant UI feedback
    this.sessions = this.sessions.filter((session) => session.id !== sessionId);

    // Then trigger a refresh to get the latest server state
    this.dispatchEvent(new CustomEvent('refresh'));
  }

  private handleSessionKillError(e: CustomEvent) {
    const { sessionId, error } = e.detail;
    console.error(`Failed to kill session ${sessionId}:`, error);

    // Dispatch error event to parent for user notification
    this.dispatchEvent(
      new CustomEvent('error', {
        detail: `Failed to kill session: ${error}`,
      })
    );
  }

  public async handleCleanupExited() {
    if (this.cleaningExited) return;

    this.cleaningExited = true;
    this.requestUpdate();

    try {
      const response = await fetch('/api/cleanup-exited', {
        method: 'POST',
      });

      if (response.ok) {
        this.dispatchEvent(new CustomEvent('refresh'));
      } else {
        this.dispatchEvent(
          new CustomEvent('error', { detail: 'Failed to cleanup exited sessions' })
        );
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
      ? this.sessions.filter((session) => session.status !== 'exited')
      : this.sessions;

    return html`
      <div class="font-mono text-sm p-4" style="background: black;">
        ${filteredSessions.length === 0
          ? html`
              <div class="text-vs-muted text-center py-8">
                ${this.loading
                  ? 'Loading sessions...'
                  : this.hideExited && this.sessions.length > 0
                    ? 'No running sessions'
                    : 'No sessions found'}
              </div>
            `
          : html`
              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                ${repeat(
                  filteredSessions,
                  (session) => session.id,
                  (session) => html`
                    <session-card
                      .session=${session}
                      @session-select=${this.handleSessionSelect}
                      @session-killed=${this.handleSessionKilled}
                      @session-kill-error=${this.handleSessionKillError}
                    >
                    </session-card>
                  `
                )}
              </div>
            `}

        <session-create-form
          .visible=${this.showCreateModal}
          @session-created=${(e: CustomEvent) =>
            this.dispatchEvent(new CustomEvent('session-created', { detail: e.detail }))}
          @cancel=${() => this.dispatchEvent(new CustomEvent('create-modal-close'))}
          @error=${(e: CustomEvent) =>
            this.dispatchEvent(new CustomEvent('error', { detail: e.detail }))}
        ></session-create-form>
      </div>
    `;
  }
}
