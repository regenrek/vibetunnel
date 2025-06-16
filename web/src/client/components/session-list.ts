import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';

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
      // Auto-load all snapshots when sessions change
      setTimeout(() => this.loadAllSnapshots(), 100);
    }
  }

  private createPlayer(sessionId: string) {
    const playerElement = this.querySelector(`#player-${sessionId}`) as HTMLElement;
    if (playerElement && (window as any).AsciinemaPlayer) {
      try {
        const snapshotUrl = `/api/sessions/${sessionId}/snapshot`;
        
        (window as any).AsciinemaPlayer.create(snapshotUrl, playerElement, {
          autoPlay: true,
          loop: false,
          controls: false,
          fit: 'both',
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

  render() {
    return html`
      <div class="font-mono text-sm p-4">
        ${this.sessions.length === 0 ? html`
          <div class="text-vs-muted text-center py-8">
            ${this.loading ? 'Loading sessions...' : 'No sessions found'}
          </div>
        ` : html`
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
            ${this.sessions.map(session => html`
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
                    ${this.killingSessionIds.has(session.id) ? 'killing...' : 'kill'}
                  </button>
                </div>

                <!-- Asciinema player (main content) -->
                <div class="session-preview bg-black flex items-center justify-center" style="aspect-ratio: 640/480;">
                  ${this.loadedSnapshots.has(session.id) ? html`
                    <div id="player-${session.id}" class="w-full h-full" style="overflow: hidden;"></div>
                  ` : html`
                    <div class="text-vs-muted text-xs">
                      ${this.loadingSnapshots.has(session.id) ? 'Loading...' : 'Loading...'}
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
      </div>
    `;
  }
}