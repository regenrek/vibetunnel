import { LitElement, html } from 'lit';
import { customElement } from 'lit/decorators.js';

@customElement('app-header')
export class AppHeader extends LitElement {
  createRenderRoot() {
    return this;
  }

  render() {
    return html`
      <div class="p-4 border-b border-vs-border">
        <div class="text-vs-user font-mono text-sm">VibeTunnel</div>
      </div>
    `;
  }
}