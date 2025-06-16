import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import './session-create-form.js';

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

  @state() private killingSessionIds = new Set<string>();
  @state() private loadedSnapshots = new Map<string, string>();
  @state() private loadingSnapshots = new Set<string>();
  @state() private hideExited = true;
  @state() private showCreateModal = false;
  @state() private cleaningExited = false;
  @state() private newSessionIds = new Set<string>();

  private handleRefresh() {
    this.dispatchEvent(new CustomEvent('refresh'));
  }

  private async loadSnapshot(sessionId: string) {
    if (this.loadedSnapshots.has(sessionId) || this.loadingSnapshots.has(sessionId)) {
      return;
    }

    this.loadingSnapshots.add(sessionId);
    this.requestUpdate();

    try {
      // Just mark as loaded and create the player with the endpoint URL
      this.loadedSnapshots.set(sessionId, sessionId);
      this.requestUpdate();

      // Create asciinema player after the element is rendered
      setTimeout(() => this.createPlayer(sessionId), 10);
    } catch (error) {
      console.error('Error loading snapshot:', error);
    } finally {
      this.loadingSnapshots.delete(sessionId);
      this.requestUpdate();
    }
  }

  private loadAllSnapshots() {
    this.sessions.forEach(session => {
      this.loadSnapshot(session.id);
    });
  }

  updated(changedProperties: any) {
    super.updated(changedProperties);
    if (changedProperties.has('sessions')) {
      // Auto-load snapshots for existing sessions immediately, but delay for new ones
      const prevSessions = changedProperties.get('sessions') || [];
      const newSessionIdsList = this.sessions
        .filter(session => !prevSessions.find((prev: Session) => prev.id === session.id))
        .map(session => session.id);

      // Track new sessions
      newSessionIdsList.forEach(id => this.newSessionIds.add(id));

      // Load existing sessions immediately
      const existingSessions = this.sessions.filter(session =>
        !newSessionIdsList.includes(session.id)
      );
      existingSessions.forEach(session => this.loadSnapshot(session.id));

      // Load new sessions after a delay to let them generate some output
      if (newSessionIdsList.length > 0) {
        setTimeout(() => {
          newSessionIdsList.forEach(sessionId => {
            this.newSessionIds.delete(sessionId); // Remove from new sessions set
            this.loadSnapshot(sessionId);
          });
          this.requestUpdate(); // Update UI to show the players
        }, 500); // Wait 500ms for new sessions
      }
    }
  }

  private createPlayer(sessionId: string) {
    const playerElement = this.querySelector(`#player-${sessionId}`) as HTMLElement;
    if (playerElement && (window as any).AsciinemaPlayer) {
      try {
        const streamUrl = `/api/sessions/${sessionId}/stream`;

        (window as any).AsciinemaPlayer.create({driver: "eventsource", url: streamUrl}, playerElement, {
          autoPlay: true,
          loop: false,
          controls: false,
          fit: 'width',
          terminalFontSize: '8px',
          idleTimeLimit: 0.5,
          preload: true,
          poster: 'npt:999999'
        });
      } catch (error) {
        console.error('Error creating asciinema player:', error);
      }
    }
  }

  private handleSessionClick(session: Session) {
    this.dispatchEvent(new CustomEvent('session-select', {
      detail: session
    }));
  }

  private async handleKillSession(e: Event, sessionId: string) {
    e.stopPropagation(); // Prevent session selection

    if (!confirm('Are you sure you want to kill this session?')) {
      return;
    }

    this.killingSessionIds.add(sessionId);
    this.requestUpdate();

    try {
      const response = await fetch(`/api/sessions/${sessionId}`, {
        method: 'DELETE'
      });

      if (response.ok) {
        this.dispatchEvent(new CustomEvent('session-killed', {
          detail: { sessionId }
        }));
        // Refresh the list after a short delay
        setTimeout(() => {
          this.handleRefresh();
        }, 1000);
      } else {
        const error = await response.json();
        this.dispatchEvent(new CustomEvent('error', {
          detail: `Failed to kill session: ${error.error}`
        }));
      }
    } catch (error) {
      console.error('Error killing session:', error);
      this.dispatchEvent(new CustomEvent('error', {
        detail: 'Failed to kill session'
      }));
    } finally {
      this.killingSessionIds.delete(sessionId);
      this.requestUpdate();
    }
  }

  private formatTime(timestamp: string): string {
    try {
      const date = new Date(timestamp);
      return date.toLocaleTimeString();
    } catch {
      return 'Unknown';
    }
  }

  private truncateId(id: string): string {
    return id.length > 8 ? `${id.substring(0, 8)}...` : id;
  }

  private handleSessionCreated(e: CustomEvent) {
    this.showCreateModal = false;
    this.dispatchEvent(new CustomEvent('session-created', {
      detail: e.detail
    }));
  }

  private handleCreateError(e: CustomEvent) {
    this.dispatchEvent(new CustomEvent('error', {
      detail: e.detail
    }));
  }

  private async handleCleanExited() {
    const exitedSessions = this.sessions.filter(session => session.status === 'exited');

    if (exitedSessions.length === 0) {
      this.dispatchEvent(new CustomEvent('error', {
        detail: 'No exited sessions to clean'
      }));
      return;
    }

    if (!confirm(`Are you sure you want to delete ${exitedSessions.length} exited session${exitedSessions.length > 1 ? 's' : ''}?`)) {
      return;
    }

    this.cleaningExited = true;
    this.requestUpdate();

    try {
      // Use the bulk cleanup API endpoint
      const response = await fetch('/api/cleanup-exited', {
        method: 'POST'
      });

      if (!response.ok) {
        throw new Error('Failed to cleanup exited sessions');
      }

      this.dispatchEvent(new CustomEvent('error', {
        detail: `Successfully cleaned ${exitedSessions.length} exited session${exitedSessions.length > 1 ? 's' : ''}`
      }));

      // Refresh the list after cleanup
      setTimeout(() => {
        this.handleRefresh();
      }, 500);

    } catch (error) {
      console.error('Error cleaning exited sessions:', error);
      this.dispatchEvent(new CustomEvent('error', {
        detail: 'Failed to clean exited sessions'
      }));
    } finally {
      this.cleaningExited = false;
      this.requestUpdate();
    }
  }

  private get filteredSessions() {
    return this.hideExited
      ? this.sessions.filter(session => session.status === 'running')
      : this.sessions;
  }

  render() {
    const sessionsToShow = this.filteredSessions;

    return html`
      <div class="font-mono text-sm p-4">
        <!-- Controls -->
        <div class="mb-4 space-y-3 md:space-y-0">
          <!-- Mobile: Stack everything -->
          <div class="flex flex-col space-y-3 md:hidden">
            <div class="flex items-center gap-2">
              <button
                class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-3 py-2 border-none rounded transition-colors text-sm flex-1"
                @click=${() => this.showCreateModal = true}
              >
CREATE
              </button>

              <button
                class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-3 py-2 border-none rounded transition-colors disabled:opacity-50 text-sm flex-1"
                @click=${this.handleCleanExited}
                ?disabled=${this.cleaningExited || this.sessions.filter(s => s.status === 'exited').length === 0}
              >
                ${this.cleaningExited ? '[~] CLEANING...' : 'CLEAN'}
              </button>
            </div>

            <label class="flex items-center gap-2 text-vs-text text-sm cursor-pointer hover:text-vs-accent transition-colors">
              <div class="relative">
                <input
                  type="checkbox"
                  class="sr-only"
                  .checked=${this.hideExited}
                  @change=${(e: Event) => this.hideExited = (e.target as HTMLInputElement).checked}
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
              --filter-exited
            </label>
          </div>

          <!-- Desktop: Side by side -->
          <div class="hidden md:flex md:items-center md:justify-between">
            <div class="flex items-center gap-3">
              <button
                class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-4 py-2 border-none rounded transition-colors"
                @click=${() => this.showCreateModal = true}
              >
CREATE SESSION
              </button>

              <button
                class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-4 py-2 border-none rounded transition-colors disabled:opacity-50"
                @click=${this.handleCleanExited}
                ?disabled=${this.cleaningExited || this.sessions.filter(s => s.status === 'exited').length === 0}
              >
                ${this.cleaningExited ? '[~] CLEANING...' : 'CLEAN EXITED'}
              </button>
            </div>

            <label class="flex items-center gap-2 text-vs-text text-sm cursor-pointer hover:text-vs-accent transition-colors">
              <div class="relative">
                <input
                  type="checkbox"
                  class="sr-only"
                  .checked=${this.hideExited}
                  @change=${(e: Event) => this.hideExited = (e.target as HTMLInputElement).checked}
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
              --filter-exited
            </label>
          </div>
        </div>

        ${sessionsToShow.length === 0 ? html`
          <div class="text-vs-muted text-center py-8">
            ${this.loading ? 'Loading sessions...' : (this.hideExited && this.sessions.length > 0 ? 'No running sessions' : 'No sessions found')}
          </div>
        ` : html`
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            ${sessionsToShow.map(session => html`
              <div
                class="bg-vs-bg border border-vs-border rounded shadow cursor-pointer overflow-hidden"
                @click=${() => this.handleSessionClick(session)}
              >
                <!-- Compact Header -->
                <div class="flex justify-between items-center px-3 py-2 border-b border-vs-border">
                  <div class="text-vs-text text-xs font-mono truncate pr-2 flex-1">${session.command}</div>
                  <button
                    class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-2 py-0.5 border-none text-xs disabled:opacity-50 flex-shrink-0 rounded"
                    @click=${(e: Event) => this.handleKillSession(e, session.id)}
                    ?disabled=${this.killingSessionIds.has(session.id)}
                  >
                    ${this.killingSessionIds.has(session.id) ? '[~] killing...' : 'kill'}
                  </button>
                </div>

                <!-- Asciinema player (main content) -->
                <div class="session-preview bg-black flex items-center justify-center overflow-hidden" style="aspect-ratio: 640/480;">
                  ${this.loadedSnapshots.has(session.id) ? html`
                    <div id="player-${session.id}" class="w-full h-full overflow-hidden"></div>
                  ` : html`
                    <div class="text-vs-muted text-xs">
                      ${this.newSessionIds.has(session.id)
                        ? '[~] init_session...'
                        : (this.loadingSnapshots.has(session.id) ? '[~] loading...' : '[~] loading...')
                      }
                    </div>
                  `}
                </div>

                <!-- Compact Footer -->
                <div class="px-3 py-2 text-vs-muted text-xs border-t border-vs-border">
                  <div class="flex justify-between items-center">
                    <span class="${session.status === 'running' ? 'text-vs-user' : 'text-vs-warning'} text-xs">
                      ${session.status}
                    </span>
                    <span class="truncate">${this.truncateId(session.id)}</span>
                  </div>
                  <div class="truncate text-xs opacity-75" title="${session.workingDir}">${session.workingDir}</div>
                </div>
              </div>
            `)}
          </div>
        `}

        <session-create-form
          .visible=${this.showCreateModal}
          @session-created=${this.handleSessionCreated}
          @cancel=${() => this.showCreateModal = false}
          @error=${this.handleCreateError}
        ></session-create-form>
      </div>
    `;
  }
}