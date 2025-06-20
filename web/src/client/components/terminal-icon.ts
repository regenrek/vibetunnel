import { LitElement, html, css } from 'lit';
import { customElement, property } from 'lit/decorators.js';

@customElement('terminal-icon')
export class TerminalIcon extends LitElement {
  @property({ type: Number }) size = 24;

  static styles = css`
    :host {
      display: inline-flex;
      align-items: center;
      justify-content: center;
    }

    svg {
      display: block;
      width: var(--icon-size, 24px);
      height: var(--icon-size, 24px);
    }
  `;

  render() {
    return html`
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linecap="round"
        stroke-linejoin="round"
        style="--icon-size: ${this.size}px"
        class="terminal-icon"
      >
        <polyline points="4 17 10 11 4 5"></polyline>
        <line x1="12" y1="19" x2="20" y2="19"></line>
      </svg>
    `;
  }
}
