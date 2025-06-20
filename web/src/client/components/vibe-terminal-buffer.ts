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

  private container: HTMLElement | null = null;
  private pollTimer: NodeJS.Timeout | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private lastModified: string | null = null;

  connectedCallback() {
    super.connectedCallback();
    this.startPolling();
  }

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

    const containerHeight = this.container.clientHeight;
    const lineHeight = this.fontSize * 1.2;
    const newActualRows = Math.floor(containerHeight / lineHeight);

    if (this.fitHorizontally && this.buffer) {
      // Calculate font size to fit terminal width
      const containerWidth = this.container.clientWidth;
      const charWidth = this.fontSize * 0.6; // Approximate char width
      const requiredWidth = this.buffer.cols * charWidth;

      if (requiredWidth > containerWidth) {
        const scale = containerWidth / requiredWidth;
        this.displayedFontSize = Math.floor(this.fontSize * scale);
      } else {
        this.displayedFontSize = this.fontSize;
      }
    } else {
      this.displayedFontSize = this.fontSize;
    }

    if (newActualRows !== this.actualRows) {
      this.actualRows = newActualRows;
      this.fetchBuffer();
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

      // Fetch buffer data - request lines from bottom
      const lines = Math.min(this.actualRows, stats.totalRows);
      const response = await fetch(
        `/api/sessions/${this.sessionId}/buffer?lines=${lines}&format=json`
      );

      if (!response.ok) {
        throw new Error(`Failed to fetch buffer: ${response.statusText}`);
      }

      this.buffer = await response.json();
      this.lastModified = stats.lastModified;
      this.error = null;

      // Debug logging
      console.log(`Buffer loaded for ${this.sessionId}:`, {
        cols: this.buffer.cols,
        rows: this.buffer.rows,
        cellCount: this.buffer.cells.length,
        firstLineSample: this.buffer.cells[0]?.slice(0, 10),
      });

      this.requestUpdate();
    } catch (error) {
      console.error('Error fetching buffer:', error);
      this.error = error instanceof Error ? error.message : 'Failed to fetch buffer';
    } finally {
      this.loading = false;
    }
  }

  render() {
    return html`
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
                style="font-size: ${this.displayedFontSize}px; line-height: 1.2;"
              >
                ${this.renderBuffer()}
              </div>
            `}
      </div>
    `;
  }

  private renderBuffer() {
    if (!this.buffer) {
      return html`<div class="terminal-line"></div>`;
    }

    const lineHeight = this.displayedFontSize * 1.2;

    // Render lines
    return this.buffer.cells.map((row, index) => {
      const isCursorLine = index === this.buffer.cursorY;
      const cursorCol = isCursorLine ? this.buffer.cursorX : -1;
      const lineContent = TerminalRenderer.renderLineFromCells(row, cursorCol);

      return html`
        <div
          class="terminal-line"
          style="height: ${lineHeight}px; line-height: ${lineHeight}px;"
          .innerHTML=${lineContent}
        ></div>
      `;
    });
  }

  /**
   * Public method to fetch buffer on demand
   */
  async refresh() {
    await this.fetchBuffer();
  }
}
