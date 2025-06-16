import { LitElement, html } from 'lit';
import { customElement } from 'lit/decorators.js';

@customElement('app-header')
export class AppHeader extends LitElement {
  createRenderRoot() {
    return this;
  }

  private handleCreateSession() {
    this.dispatchEvent(new CustomEvent('create-session'));
  }

  render() {
    return html`
      <div class="p-4 border-b border-vs-border">
        <div class="flex items-center justify-between">
          <div class="text-vs-user font-mono text-sm">VibeTunnel</div>
          <button
            class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-4 py-2 border-none rounded transition-colors text-sm"
            @click=${this.handleCreateSession}
          >
            CREATE SESSION
          </button>
        </div>
      </div>
    `;
  }
}