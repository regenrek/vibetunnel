import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { TerminalRenderer, type BufferCell } from '../utils/terminal-renderer.js';

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
  @property({ type: Number }) fontSize = 14;
  @property({ type: Boolean }) fitHorizontally = false;
  @property({ type: Number }) pollInterval = 1000; // Poll interval in ms

  @state() private buffer: BufferSnapshot | null = null;
  @state() private error: string | null = null;
  @state() private loading = false;
  @state() private actualRows = 0;
  @state() private displayedFontSize = 14;
  @state() private containerCols = 80; // Calculated columns that fit

  private container: HTMLElement | null = null;
  private pollTimer: NodeJS.Timeout | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private lastModified: string | null = null;

  // Moved to render() method above

  disconnectedCallback() {
    this.stopPolling();
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
      this.fetchBuffer();
    }
  }

  updated(changedProperties: Map<string, unknown>) {
    super.updated(changedProperties);

    if (changedProperties.has('sessionId')) {
      this.buffer = null;
      this.error = null;
      this.lastModified = null;
      if (this.sessionId) {
        this.fetchBuffer();
      }
    }
    if (changedProperties.has('pollInterval')) {
      this.stopPolling();
      this.startPolling();
    }
    if (changedProperties.has('fontSize') || changedProperties.has('fitHorizontally')) {
      this.calculateDimensions();
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

    if (this.fitHorizontally && this.buffer) {
      // Horizontal fitting: calculate fontSize to fit buffer.cols characters in container width
      const targetCharWidth = containerWidth / this.buffer.cols;

      // Estimate font size needed (assuming monospace font with ~0.6 char/font ratio)
      const calculatedFontSize = targetCharWidth / 0.6;
      this.displayedFontSize = Math.max(4, Math.min(32, Math.floor(calculatedFontSize)));

      // Calculate actual rows with new font size
      const lineHeight = this.displayedFontSize * 1.2;
      const newActualRows = Math.max(1, Math.floor(containerHeight / lineHeight));

      if (newActualRows !== this.actualRows) {
        this.actualRows = newActualRows;
        this.fetchBuffer();
      }
    } else {
      // Normal mode: use original font size and calculate cols that fit
      this.displayedFontSize = this.fontSize;
      const lineHeight = this.fontSize * 1.2;
      const charWidth = this.fontSize * 0.6;

      const newActualRows = Math.max(1, Math.floor(containerHeight / lineHeight));
      this.containerCols = Math.max(20, Math.floor(containerWidth / charWidth));

      if (newActualRows !== this.actualRows) {
        this.actualRows = newActualRows;
        this.fetchBuffer();
      }
    }
  }

  private startPolling() {
    if (this.pollInterval > 0) {
      this.pollTimer = setInterval(() => {
        if (!this.loading) {
          this.fetchBuffer();
        }
      }, this.pollInterval);
    }
  }

  private stopPolling() {
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }

  private async fetchBuffer() {
    if (!this.sessionId || this.actualRows === 0) return;

    try {
      this.loading = true;

      // First fetch stats to check if we need to update
      const statsResponse = await fetch(`/api/sessions/${this.sessionId}/buffer/stats`);
      if (!statsResponse.ok) {
        throw new Error(`Failed to fetch buffer stats: ${statsResponse.statusText}`);
      }
      const stats = await statsResponse.json();

      // Check if buffer changed
      if (this.lastModified && this.lastModified === stats.lastModified) {
        this.loading = false;
        return; // No changes
      }

      // Always fetch the entire buffer to show all content
      const response = await fetch(
        `/api/sessions/${this.sessionId}/buffer?viewportY=0&lines=${stats.totalRows}&format=json`
      );

      if (!response.ok) {
        throw new Error(`Failed to fetch buffer: ${response.statusText}`);
      }

      this.buffer = await response.json();
      this.lastModified = stats.lastModified;
      this.error = null;

      // Request update which will trigger updated() lifecycle
      this.requestUpdate();
    } catch (error) {
      console.error('Error fetching buffer:', error);
      this.error = error instanceof Error ? error.message : 'Failed to fetch buffer';
    } finally {
      this.loading = false;
    }
  }

  connectedCallback() {
    super.connectedCallback();
    this.startPolling();
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
      <div class="relative w-full h-full overflow-hidden bg-[#1e1e1e]">
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

    // In fitHorizontally mode, we show all content scaled to fit
    // Otherwise, we show from the top and let it overflow
    const cellsToRender = this.fitHorizontally
      ? this.buffer.cells
      : this.buffer.cells.slice(0, this.actualRows);

    cellsToRender.forEach((row, index) => {
      const isCursorLine = index === this.buffer.cursorY;
      const cursorCol = isCursorLine ? this.buffer.cursorX : -1;
      const lineContent = TerminalRenderer.renderLineFromCells(row, cursorCol);

      html += `<div class="terminal-line" style="height: ${lineHeight}px; line-height: ${lineHeight}px;">${lineContent}</div>`;
    });

    // Set innerHTML directly like terminal.ts does
    this.container.innerHTML = html;
  }

  /**
   * Public method to fetch buffer on demand
   */
  async refresh() {
    await this.fetchBuffer();
  }
}
