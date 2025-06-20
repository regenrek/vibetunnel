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
  @state() private visibleRows = 0;
  @state() private containsEscPrompt = false;

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
    const containerHeight = this.container.clientHeight;

    // Step 1: Calculate font size to fit horizontally
    const cols = this.buffer?.cols || 80;

    // Measure actual character width at 14px font size
    const testElement = document.createElement('div');
    testElement.className = 'terminal-line';
    testElement.style.position = 'absolute';
    testElement.style.visibility = 'hidden';
    testElement.style.fontSize = '14px';
    testElement.textContent = '0'.repeat(cols);

    document.body.appendChild(testElement);
    const totalWidth = testElement.getBoundingClientRect().width;
    document.body.removeChild(testElement);

    // Calculate the exact font size needed to fit the container width
    const calculatedFontSize = (containerWidth / totalWidth) * 14;
    // Don't floor - keep the decimal for exact fit
    this.displayedFontSize = Math.min(32, calculatedFontSize);

    // Step 2: Calculate how many lines fit vertically with this font size
    const lineHeight = this.displayedFontSize * 1.2;
    this.visibleRows = Math.floor(containerHeight / lineHeight);

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

      // Check if buffer contains "esc to interrupt" text
      this.checkForEscPrompt();

      // Recalculate dimensions now that we have the actual cols
      this.calculateDimensions();

      // Request update which will trigger updated() lifecycle
      this.requestUpdate();
    });
  }

  private checkForEscPrompt() {
    if (!this.buffer) {
      this.containsEscPrompt = false;
      return;
    }

    // Check if any line contains "esc to interrupt" (case insensitive)
    const searchText = 'esc to interrupt';
    const found = this.buffer.cells.some((row) => {
      const lineText = row
        .map((cell) => cell.char)
        .join('')
        .toLowerCase();
      return lineText.includes(searchText);
    });

    if (found !== this.containsEscPrompt) {
      this.containsEscPrompt = found;
      // Dispatch event to notify parent
      this.dispatchEvent(
        new CustomEvent('esc-prompt-change', {
          detail: { hasEscPrompt: found },
          bubbles: true,
          composed: true,
        })
      );
    }
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
    if (!this.container || !this.buffer || this.visibleRows === 0) return;

    const lineHeight = this.displayedFontSize * 1.2;
    let html = '';

    // Step 3: Show bottom N lines that fit
    let startIndex = 0;
    if (this.buffer.cells.length > this.visibleRows) {
      // More content than visible rows - show bottom portion
      startIndex = this.buffer.cells.length - this.visibleRows;
    }

    // Render only the visible rows
    for (let i = startIndex; i < this.buffer.cells.length; i++) {
      const row = this.buffer.cells[i];

      // Check if cursor is on this line
      const isCursorLine = i === this.buffer.cursorY;
      const cursorCol = isCursorLine ? this.buffer.cursorX : -1;
      const lineContent = TerminalRenderer.renderLineFromCells(row, cursorCol);

      html += `<div class="terminal-line" style="height: ${lineHeight}px; line-height: ${lineHeight}px;">${lineContent}</div>`;
    }

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
