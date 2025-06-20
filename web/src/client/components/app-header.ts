import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import type { Session } from './session-list.js';
import './terminal-icon.js';

@customElement('app-header')
export class AppHeader extends LitElement {
  createRenderRoot() {
    return this;
  }

  @property({ type: Array }) sessions: Session[] = [];
  @property({ type: Boolean }) hideExited = true;
  @state() private killingAll = false;

  private handleCreateSession() {
    this.dispatchEvent(new CustomEvent('create-session'));
  }

  private handleKillAll() {
    if (this.killingAll) return;

    this.killingAll = true;
    this.requestUpdate();

    this.dispatchEvent(new CustomEvent('kill-all-sessions'));

    // Reset the state after a delay to allow for the kill operations to complete
    setTimeout(() => {
      this.killingAll = false;
      this.requestUpdate();
    }, 3000); // 3 seconds should be enough for most kill operations
  }

  private handleCleanExited() {
    this.dispatchEvent(new CustomEvent('clean-exited-sessions'));
  }

  render() {
    const runningSessions = this.sessions.filter((session) => session.status === 'running');
    const exitedSessions = this.sessions.filter((session) => session.status === 'exited');

    // Reset killing state if no more running sessions
    if (this.killingAll && runningSessions.length === 0) {
      this.killingAll = false;
    }

    return html`
      <div class="app-header bg-dark-bg-secondary border-b border-dark-border p-6">
        <!-- Mobile layout -->
        <div class="flex flex-col gap-4 sm:hidden">
          <!-- Centered Sessions title with stats -->
          <div class="text-center flex flex-col items-center gap-2">
            <h1 class="text-2xl font-bold text-accent-green flex items-center gap-3">
              <terminal-icon size="28"></terminal-icon>
              <span>Sessions</span>
            </h1>
            <p class="text-dark-text-muted text-sm">
              ${runningSessions.length} ${runningSessions.length === 1 ? 'Session' : 'Sessions'}
              ${exitedSessions.length > 0 ? `• ${exitedSessions.length} Exited` : ''}
            </p>
          </div>

          <!-- Controls row: left buttons and right buttons -->
          <div class="flex items-center justify-between">
            <div class="flex gap-2">
              ${exitedSessions.length > 0
                ? html`
                    <button
                      class="btn-secondary font-mono text-xs px-4 py-2 ${this.hideExited
                        ? ''
                        : 'bg-accent-green text-dark-bg hover:bg-accent-green-darker'}"
                      @click=${() =>
                        this.dispatchEvent(
                          new CustomEvent('hide-exited-change', {
                            detail: !this.hideExited,
                          })
                        )}
                    >
                      ${this.hideExited
                        ? `Show (${exitedSessions.length})`
                        : `Hide (${exitedSessions.length})`}
                    </button>
                  `
                : ''}
              ${!this.hideExited && exitedSessions.length > 0
                ? html`
                    <button
                      class="btn-ghost font-mono text-xs text-status-warning"
                      @click=${this.handleCleanExited}
                    >
                      Clean Exited
                    </button>
                  `
                : ''}
              ${runningSessions.length > 0 && !this.killingAll
                ? html`
                    <button
                      class="btn-ghost font-mono text-xs text-status-error"
                      @click=${this.handleKillAll}
                    >
                      Kill (${runningSessions.length})
                    </button>
                  `
                : ''}
            </div>

            <div class="flex gap-2">
              <button
                class="btn-primary font-mono text-xs px-4 py-2"
                @click=${this.handleCreateSession}
              >
                Create
              </button>
            </div>
          </div>
        </div>

        <!-- Desktop layout: single row -->
        <div class="hidden sm:flex sm:items-center sm:justify-between">
          <div class="flex items-center gap-3">
            <terminal-icon size="32"></terminal-icon>
            <div>
              <h1 class="text-xl font-bold text-accent-green">VibeTunnel</h1>
              <p class="text-dark-text-muted text-sm">
                ${runningSessions.length} ${runningSessions.length === 1 ? 'Session' : 'Sessions'}
                ${exitedSessions.length > 0 ? `• ${exitedSessions.length} Exited` : ''}
              </p>
            </div>
          </div>
          <div class="flex items-center gap-3">
            ${exitedSessions.length > 0
              ? html`
                  <button
                    class="btn-secondary font-mono text-xs px-4 py-2 ${this.hideExited
                      ? ''
                      : 'bg-accent-green text-dark-bg hover:bg-accent-green-darker'}"
                    @click=${() =>
                      this.dispatchEvent(
                        new CustomEvent('hide-exited-change', {
                          detail: !this.hideExited,
                        })
                      )}
                  >
                    ${this.hideExited
                      ? `Show Exited (${exitedSessions.length})`
                      : `Hide Exited (${exitedSessions.length})`}
                  </button>
                `
              : ''}
            <div class="flex gap-2">
              ${!this.hideExited && this.sessions.filter((s) => s.status === 'exited').length > 0
                ? html`
                    <button
                      class="btn-ghost font-mono text-xs text-status-warning"
                      @click=${this.handleCleanExited}
                    >
                      Clean Exited
                    </button>
                  `
                : ''}
              ${runningSessions.length > 0 && !this.killingAll
                ? html`
                    <button
                      class="btn-ghost font-mono text-xs text-status-error"
                      @click=${this.handleKillAll}
                    >
                      Kill All (${runningSessions.length})
                    </button>
                  `
                : ''}
              <button
                class="btn-primary font-mono text-xs px-4 py-2"
                @click=${this.handleCreateSession}
              >
                Create Session
              </button>
            </div>
          </div>
        </div>
      </div>
    `;
  }
}
