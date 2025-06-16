import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import type { Session } from './session-list.js';

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

  render() {
    const runningSessions = this.sessions.filter((session) => session.status === 'running');

    // Reset killing state if no more running sessions
    if (this.killingAll && runningSessions.length === 0) {
      this.killingAll = false;
    }

    return html`
      <div class="p-4 border-b border-vs-border">
        <div class="flex items-center justify-between">
          <div class="text-vs-user font-mono text-sm">VibeTunnel</div>
          <div class="flex items-center gap-3">
            <label
              class="flex items-center gap-2 text-vs-text text-sm cursor-pointer hover:text-vs-accent transition-colors"
            >
              <div class="relative">
                <input
                  type="checkbox"
                  class="sr-only"
                  .checked=${this.hideExited}
                  @change=${(e: Event) =>
                    this.dispatchEvent(
                      new CustomEvent('hide-exited-change', {
                        detail: (e.target as HTMLInputElement).checked,
                      })
                    )}
                />
                <div
                  class="w-4 h-4 border border-vs-border rounded bg-vs-bg-secondary flex items-center justify-center transition-all ${this
                    .hideExited
                    ? 'bg-vs-user border-vs-user'
                    : 'hover:border-vs-accent'}"
                >
                  ${this.hideExited
                    ? html`
                        <svg class="w-3 h-3 text-vs-bg" fill="currentColor" viewBox="0 0 20 20">
                          <path
                            fill-rule="evenodd"
                            d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
                            clip-rule="evenodd"
                          ></path>
                        </svg>
                      `
                    : ''}
                </div>
              </div>
              hide exited
            </label>
            ${runningSessions.length > 0 && !this.killingAll
              ? html`
                  <button
                    class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-4 py-2 border-none rounded transition-colors text-sm"
                    @click=${this.handleKillAll}
                  >
                    KILL ALL (${runningSessions.length})
                  </button>
                `
              : ''}
            <button
              class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-4 py-2 border-none rounded transition-colors text-sm"
              @click=${this.handleCreateSession}
            >
              CREATE SESSION
            </button>
          </div>
        </div>
      </div>
    `;
  }
}
