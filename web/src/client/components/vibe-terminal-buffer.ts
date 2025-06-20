import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { TerminalRenderer, type BufferCell } from '../utils/terminal-renderer.js';
import { bufferSubscriptionService } from '../services/buffer-subscription-service.js';

interface BufferSnapshot {
  cols: number;
  rows: number;
  viewportY: number;
  cursorX: number;
  cursorY: number;
  cells: BufferCell[][];
}

@customElement('vibe-terminal-buffer')
export class VibeTerminalBuffer extends LitElement {
  // Disable shadow DOM for Tailwind compatibility
  createRenderRoot() {
    return this as unknown as HTMLElement;
  }

  @property({ type: String }) sessionId = '';

  @state() private buffer: BufferSnapshot | null = null;
  @state() private error: string | null = null;
  @state() private displayedFontSize = 14;

  private container: HTMLElement | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private unsubscribe: (() => void) | null = null;

  // Moved to render() method above

  disconnectedCallback() {
    this.unsubscribeFromBuffer();
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }
    super.disconnectedCallback();
  }

  firstUpdated() {
    this.container = this.querySelector('#buffer-container') as HTMLElement;
    if (this.container) {
      this.setupResize();
      if (this.sessionId) {
        this.subscribeToBuffer();
      }
    }
  }

  updated(changedProperties: Map<string, unknown>) {
    super.updated(changedProperties);

    if (changedProperties.has('sessionId')) {
      this.buffer = null;
      this.error = null;
      this.unsubscribeFromBuffer();
      if (this.sessionId) {
        this.subscribeToBuffer();
      }
    }

    // Update buffer content after any render
    if (this.container && this.buffer) {
      this.updateBufferContent();
    }
  }

  private setupResize() {
    if (!this.container) return;

    this.resizeObserver = new ResizeObserver(() => {
      this.calculateDimensions();
    });
    this.resizeObserver.observe(this.container);
  }

  private calculateDimensions() {
    if (!this.container) return;

    const containerWidth = this.container.clientWidth;

    // Always fit horizontally
    // Step 1: Measure container width
    // Step 2: Divide by cols to get target character width
    const cols = this.buffer?.cols || 80;
    const targetCharWidth = containerWidth / cols;

    // Step 3: Scale font size so we can fit cols characters into the container width
    // Estimate font size needed (assuming monospace font with ~0.6 char/font ratio)
    const calculatedFontSize = targetCharWidth / 0.6;
    this.displayedFontSize = Math.max(4, Math.min(32, Math.floor(calculatedFontSize)));

    // Always update when dimensions change
    if (this.buffer) {
      this.requestUpdate();
    }
  }

  private subscribeToBuffer() {
    if (!this.sessionId) return;

    // Subscribe to buffer updates
    this.unsubscribe = bufferSubscriptionService.subscribe(this.sessionId, (snapshot) => {
      this.buffer = snapshot;
      this.error = null;

      // Recalculate dimensions now that we have the actual cols
      this.calculateDimensions();

      // Request update which will trigger updated() lifecycle
      this.requestUpdate();
    });
  }

  private unsubscribeFromBuffer() {
    if (this.unsubscribe) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
  }

  connectedCallback() {
    super.connectedCallback();
    // Subscription happens in firstUpdated or when sessionId changes
  }

  render() {
    const lineHeight = this.displayedFontSize * 1.2;

    return html`
      <style>
        /* Dynamic terminal sizing for this instance */
        vibe-terminal-buffer .terminal-container {
          font-size: ${this.displayedFontSize}px;
          line-height: ${lineHeight}px;
        }

        vibe-terminal-buffer .terminal-line {
          height: ${lineHeight}px;
          line-height: ${lineHeight}px;
        }
      </style>
      <div class="relative w-full h-full overflow-hidden bg-black">
        ${this.error
          ? html`
              <div class="absolute inset-0 flex items-center justify-center">
                <div class="text-red-500 text-sm">${this.error}</div>
              </div>
            `
          : html`
              <div
                id="buffer-container"
                class="terminal-container w-full h-full overflow-x-auto overflow-y-hidden font-mono antialiased"
              ></div>
            `}
      </div>
    `;
  }

  private updateBufferContent() {
    if (!this.container || !this.buffer) return;

    const lineHeight = this.displayedFontSize * 1.2;
    let html = '';

    // Render all cells from the buffer
    // The buffer contains the bottom portion of the terminal, starting at viewportY
    this.buffer.cells.forEach((row, index) => {
      // Check if cursor is on this line
      // cursorY is relative to the viewport (can be negative if cursor is above viewport)
      const isCursorLine = index === this.buffer.cursorY;
      const cursorCol = isCursorLine ? this.buffer.cursorX : -1;
      const lineContent = TerminalRenderer.renderLineFromCells(row, cursorCol);

      html += `<div class="terminal-line" style="height: ${lineHeight}px; line-height: ${lineHeight}px;">${lineContent}</div>`;
    });

    // Set innerHTML directly like terminal.ts does
    this.container.innerHTML = html;
  }

  /**
   * Public method to refresh buffer display
   */
  refresh() {
    if (this.buffer) {
      this.requestUpdate();
    }
  }
}
