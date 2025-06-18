import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import type { Session } from './session-list.js';
import './vibe-logo.js';

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
      <div class="app-header p-4" style="background: black;">
        <!-- Mobile layout -->
        <div class="flex flex-col gap-3 sm:hidden">
          <!-- Centered VibeTunnel title -->
          <div class="text-center">
            <vibe-logo></vibe-logo>
          </div>

          <!-- Controls row: left buttons and right buttons -->
          <div class="flex items-center justify-between">
            <div class="flex gap-1">
              ${exitedSessions.length > 0
                ? html`
                    <button
                      class="font-mono px-2 py-1 rounded transition-colors text-xs whitespace-nowrap"
                      style="background: black; color: #d4d4d4; border: 1px solid ${this.hideExited
                        ? '#23d18b'
                        : '#888'};"
                      @click=${() =>
                        this.dispatchEvent(
                          new CustomEvent('hide-exited-change', {
                            detail: !this.hideExited,
                          })
                        )}
                      @mouseover=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        const borderColor = this.hideExited ? '#23d18b' : '#888';
                        btn.style.background = borderColor;
                        btn.style.color = 'black';
                      }}
                      @mouseout=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        btn.style.background = 'black';
                        btn.style.color = '#d4d4d4';
                      }}
                    >
                      ${this.hideExited
                        ? `SHOW EXITED (${exitedSessions.length})`
                        : `HIDE EXITED (${exitedSessions.length})`}
                    </button>
                  `
                : ''}
              ${!this.hideExited && exitedSessions.length > 0
                ? html`
                    <button
                      class="font-mono px-2 py-1 rounded transition-colors text-xs whitespace-nowrap"
                      style="background: black; color: #d4d4d4; border: 1px solid #d19a66;"
                      @click=${this.handleCleanExited}
                      @mouseover=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        btn.style.background = '#d19a66';
                        btn.style.color = 'black';
                      }}
                      @mouseout=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        btn.style.background = 'black';
                        btn.style.color = '#d4d4d4';
                      }}
                    >
                      CLEAN EXITED
                    </button>
                  `
                : ''}
              ${runningSessions.length > 0 && !this.killingAll
                ? html`
                    <button
                      class="font-mono px-2 py-1 rounded transition-colors text-xs whitespace-nowrap"
                      style="background: black; color: #d4d4d4; border: 1px solid #d19a66;"
                      @click=${this.handleKillAll}
                      @mouseover=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        btn.style.background = '#d19a66';
                        btn.style.color = 'black';
                      }}
                      @mouseout=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        btn.style.background = 'black';
                        btn.style.color = '#d4d4d4';
                      }}
                    >
                      KILL (${runningSessions.length})
                    </button>
                  `
                : ''}
            </div>

            <div class="flex gap-1">
              <button
                class="font-mono px-2 py-1 rounded transition-colors text-xs whitespace-nowrap"
                style="background: black; color: #d4d4d4; border: 1px solid #569cd6;"
                @click=${this.handleCreateSession}
                @mouseover=${(e: Event) => {
                  const btn = e.target as HTMLElement;
                  btn.style.background = '#569cd6';
                  btn.style.color = 'black';
                }}
                @mouseout=${(e: Event) => {
                  const btn = e.target as HTMLElement;
                  btn.style.background = 'black';
                  btn.style.color = '#d4d4d4';
                }}
              >
                CREATE
              </button>
            </div>
          </div>
        </div>

        <!-- Desktop layout: single row -->
        <div class="hidden sm:flex sm:items-center sm:justify-between">
          <vibe-logo></vibe-logo>
          <div class="flex items-center gap-3">
            ${exitedSessions.length > 0
              ? html`
                  <button
                    class="font-mono px-2 py-1 rounded transition-colors text-xs whitespace-nowrap"
                    style="background: black; color: #d4d4d4; border: 1px solid ${this.hideExited
                      ? '#23d18b'
                      : '#888'};"
                    @click=${() =>
                      this.dispatchEvent(
                        new CustomEvent('hide-exited-change', {
                          detail: !this.hideExited,
                        })
                      )}
                    @mouseover=${(e: Event) => {
                      const btn = e.target as HTMLElement;
                      const borderColor = this.hideExited ? '#23d18b' : '#888';
                      btn.style.background = borderColor;
                      btn.style.color = 'black';
                    }}
                    @mouseout=${(e: Event) => {
                      const btn = e.target as HTMLElement;
                      btn.style.background = 'black';
                      btn.style.color = '#d4d4d4';
                    }}
                  >
                    ${this.hideExited
                      ? `SHOW EXITED (${exitedSessions.length})`
                      : `HIDE EXITED (${exitedSessions.length})`}
                  </button>
                `
              : ''}
            <div class="flex gap-2">
              ${!this.hideExited && this.sessions.filter((s) => s.status === 'exited').length > 0
                ? html`
                    <button
                      class="font-mono px-2 py-1 rounded transition-colors text-xs whitespace-nowrap"
                      style="background: black; color: #d4d4d4; border: 1px solid #d19a66;"
                      @click=${this.handleCleanExited}
                      @mouseover=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        btn.style.background = '#d19a66';
                        btn.style.color = 'black';
                      }}
                      @mouseout=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        btn.style.background = 'black';
                        btn.style.color = '#d4d4d4';
                      }}
                    >
                      CLEAN EXITED
                    </button>
                  `
                : ''}
              ${runningSessions.length > 0 && !this.killingAll
                ? html`
                    <button
                      class="font-mono px-2 py-1 rounded transition-colors text-xs whitespace-nowrap"
                      style="background: black; color: #d4d4d4; border: 1px solid #d19a66;"
                      @click=${this.handleKillAll}
                      @mouseover=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        btn.style.background = '#d19a66';
                        btn.style.color = 'black';
                      }}
                      @mouseout=${(e: Event) => {
                        const btn = e.target as HTMLElement;
                        btn.style.background = 'black';
                        btn.style.color = '#d4d4d4';
                      }}
                    >
                      KILL ALL (${runningSessions.length})
                    </button>
                  `
                : ''}
              <button
                class="font-mono px-2 py-1 rounded transition-colors text-xs whitespace-nowrap"
                style="background: black; color: #d4d4d4; border: 1px solid #569cd6;"
                @click=${this.handleCreateSession}
                @mouseover=${(e: Event) => {
                  const btn = e.target as HTMLElement;
                  btn.style.background = '#569cd6';
                  btn.style.color = 'black';
                }}
                @mouseout=${(e: Event) => {
                  const btn = e.target as HTMLElement;
                  btn.style.background = 'black';
                  btn.style.color = '#d4d4d4';
                }}
              >
                CREATE SESSION
              </button>
            </div>
          </div>
        </div>
      </div>
    `;
  }
}
