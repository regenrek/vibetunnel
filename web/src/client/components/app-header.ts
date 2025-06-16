import { LitElement, html } from 'lit';
import { customElement } from 'lit/decorators.js';

@customElement('app-header')
export class AppHeader extends LitElement {
  createRenderRoot() {
    return this;
  }

  render() {
    return html`
      <div class="p-4">
        <h1 class="text-vs-user font-mono text-sm m-0">VibeTunnel</h1>
      </div>
    `;
  }
}