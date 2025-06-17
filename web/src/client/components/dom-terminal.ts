import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { Terminal, IBufferLine, IBufferCell } from '@xterm/xterm';

@customElement('dom-terminal')
export class DomTerminal extends LitElement {
  // Disable shadow DOM for Tailwind compatibility and native text selection
  createRenderRoot() {
    return this as unknown as HTMLElement;
  }

  @property({ type: String }) sessionId = '';
  @property({ type: Number }) cols = 80;
  @property({ type: Number }) rows = 24;
  @property({ type: Number }) fontSize = 14;

  @state() private terminal: Terminal | null = null;
  @state() private viewportY = 0; // Current scroll position
  @state() private actualRows = 24; // Rows that fit in viewport

  private container: HTMLElement | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private resizeTimeout: NodeJS.Timeout | null = null;

  // Virtual scrolling optimization
  private renderPending = false;
  private scrollAccumulator = 0;

  connectedCallback() {
    super.connectedCallback();
  }

  disconnectedCallback() {
    this.cleanup();
    super.disconnectedCallback();
  }

  private cleanup() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
      this.resizeObserver = null;
    }
    if (this.terminal) {
      this.terminal.dispose();
      this.terminal = null;
    }
  }

  updated(changedProperties: Map<string, unknown>) {
    if (changedProperties.has('cols') || changedProperties.has('rows')) {
      if (this.terminal) {
        this.reinitializeTerminal();
      }
    }
  }

  firstUpdated() {
    this.initializeTerminal();
  }

  private async initializeTerminal() {
    try {
      this.requestUpdate();

      this.container = this.querySelector('#dom-terminal-container') as HTMLElement;

      if (!this.container) {
        throw new Error('Terminal container not found');
      }

      await this.setupTerminal();
      this.setupResize();
      this.setupScrolling();

      this.requestUpdate();
    } catch (_error: unknown) {
      this.requestUpdate();
    }
  }

  private async reinitializeTerminal() {
    if (this.terminal) {
      this.terminal.resize(this.cols, this.rows);
      this.fitTerminal();
      this.renderBuffer();
    }
  }

  private async setupTerminal() {
    try {
      console.log('Creating terminal for headless use...');
      // Create regular terminal but don't call .open() to make it headless
      this.terminal = new Terminal({
        cursorBlink: false,
        fontSize: this.fontSize,
        fontFamily: 'Fira Code, ui-monospace, SFMono-Regular, monospace',
        lineHeight: 1.2,
        scrollback: 10000,
        theme: {
          background: '#1e1e1e',
          foreground: '#d4d4d4',
          cursor: '#00ff00',
          black: '#000000',
          red: '#f14c4c',
          green: '#23d18b',
          yellow: '#f5f543',
          blue: '#3b8eea',
          magenta: '#d670d6',
          cyan: '#29b8db',
          white: '#e5e5e5',
        },
      });

      console.log('Terminal created successfully (no DOM attachment)');
      console.log('Terminal object:', this.terminal);
      console.log('Buffer available:', !!this.terminal.buffer);

      // Set terminal size - don't call .open() to keep it headless
      this.terminal.resize(this.cols, this.rows);
      console.log('Terminal resized to:', this.cols, 'x', this.rows);
    } catch (error) {
      console.error('Failed to create terminal:', error);
      throw error;
    }
  }

  private fitTerminal() {
    if (!this.terminal || !this.container) return;

    // Calculate how many rows fit in the viewport
    const containerHeight = this.container.clientHeight;
    const lineHeight = this.fontSize * 1.2;
    this.actualRows = Math.max(1, Math.floor(containerHeight / lineHeight));

    console.log(`Viewport fits ${this.actualRows} rows`);
    this.requestUpdate();
  }

  private setupResize() {
    if (!this.container) return;

    this.resizeObserver = new ResizeObserver(() => {
      if (this.resizeTimeout) {
        clearTimeout(this.resizeTimeout);
      }
      this.resizeTimeout = setTimeout(() => {
        this.fitTerminal();
        this.renderBuffer();
      }, 50);
    });
    this.resizeObserver.observe(this.container);

    window.addEventListener('resize', () => {
      this.fitTerminal();
      this.renderBuffer();
    });
  }

  private setupScrolling() {
    if (!this.container) return;

    // Handle wheel events with accumulator for smooth scrolling
    this.container.addEventListener(
      'wheel',
      (e) => {
        e.preventDefault();
        
        // Accumulate scroll delta for smooth scrolling with small movements
        this.scrollAccumulator += e.deltaY;
        
        const lineHeight = this.fontSize * 1.2;
        const deltaLines = Math.trunc(this.scrollAccumulator / lineHeight);
        
        if (Math.abs(deltaLines) >= 1) {
          this.scrollViewport(deltaLines);
          // Subtract the scrolled amount, keep remainder for next scroll
          this.scrollAccumulator -= deltaLines * lineHeight;
        }
      },
      { passive: false }
    );

    // Handle touch events for mobile scrolling - use shared variables
    let touchStartY = 0;
    let lastY = 0;
    let velocity = 0;
    let lastTouchTime = 0;

    const handleTouchStart = (e: TouchEvent) => {
      touchStartY = e.touches[0].clientY;
      lastY = e.touches[0].clientY;
      velocity = 0;
      lastTouchTime = Date.now();
      console.log('TouchStart:', {
        startY: touchStartY,
        target: (e.target as HTMLElement)?.tagName,
        targetClass: (e.target as HTMLElement)?.className,
      });
    };

    const handleTouchMove = (e: TouchEvent) => {
      const currentY = e.touches[0].clientY;
      const deltaY = lastY - currentY; // Change since last move, not since start
      const currentTime = Date.now();

      // Calculate velocity for momentum (based on total movement from start)
      const totalDelta = touchStartY - currentY;
      const timeDelta = currentTime - lastTouchTime;
      if (timeDelta > 0) {
        velocity = totalDelta / (currentTime - (lastTouchTime - timeDelta));
      }
      lastTouchTime = currentTime;

      const deltaLines = Math.round(deltaY / (this.fontSize * 1.2));

      console.log('TouchMove:', {
        currentY,
        lastY,
        deltaY,
        totalDelta,
        fontSize: this.fontSize,
        lineHeight: this.fontSize * 1.2,
        deltaLines,
        velocity: velocity.toFixed(3),
        timeDelta,
      });

      if (Math.abs(deltaLines) > 0) {
        console.log('Scrolling:', deltaLines, 'lines');
        this.scrollViewport(deltaLines);
      }

      lastY = currentY; // Update for next move event
    };

    const handleTouchEnd = () => {
      console.log('TouchEnd:', {
        finalVelocity: velocity.toFixed(3),
        willStartMomentum: Math.abs(velocity) > 0.5,
      });

      // Add momentum scrolling if needed
      if (Math.abs(velocity) > 0.5) {
        this.startMomentumScroll(velocity);
      }
    };

    // Use event delegation on container with capture phase to catch all touch events
    this.container.addEventListener('touchstart', handleTouchStart, {
      passive: true,
      capture: true,
    });
    this.container.addEventListener('touchmove', handleTouchMove, {
      passive: false,
      capture: true,
    });
    this.container.addEventListener('touchend', handleTouchEnd, { passive: true, capture: true });
  }

  private startMomentumScroll(initialVelocity: number) {
    let velocity = initialVelocity;

    const animate = () => {
      if (Math.abs(velocity) < 0.01) return;

      const deltaLines = Math.round(velocity * 16); // 16ms frame time
      if (Math.abs(deltaLines) > 0) {
        this.scrollViewport(deltaLines);
      }

      velocity *= 0.95; // Friction
      requestAnimationFrame(animate);
    };

    requestAnimationFrame(animate);
  }

  private scrollViewport(deltaLines: number) {
    if (!this.terminal) return;

    const buffer = this.terminal.buffer.active;
    const maxScroll = Math.max(0, buffer.length - this.actualRows);

    const newViewportY = Math.max(0, Math.min(maxScroll, this.viewportY + deltaLines));

    // Only render if we actually moved
    if (newViewportY !== this.viewportY) {
      this.viewportY = newViewportY;

      // Use requestAnimationFrame to throttle rendering
      if (!this.renderPending) {
        this.renderPending = true;
        requestAnimationFrame(() => {
          this.renderBuffer();
          this.renderPending = false;
        });
      }
    }
  }

  private renderBuffer() {
    if (!this.terminal || !this.container) return;

    const buffer = this.terminal.buffer.active;
    const bufferLength = buffer.length;
    const startRow = Math.min(this.viewportY, Math.max(0, bufferLength - this.actualRows));

    // Build complete innerHTML string
    let html = '';
    const cell = buffer.getNullCell();

    for (let i = 0; i < this.actualRows; i++) {
      const row = startRow + i;

      if (row >= bufferLength) {
        html += '<div class="terminal-line"></div>';
        continue;
      }

      const line = buffer.getLine(row);
      if (!line) {
        html += '<div class="terminal-line"></div>';
        continue;
      }

      const lineContent = this.renderLine(line, cell);
      html += `<div class="terminal-line">${lineContent || ''}</div>`;
    }

    // Set the complete innerHTML at once
    this.container.innerHTML = html;
  }

  private renderLine(line: IBufferLine, cell: IBufferCell): string {
    let html = '';
    let currentChars = '';
    let currentClasses = '';
    let currentStyle = '';

    const flushGroup = () => {
      if (currentChars) {
        html += `<span class="${currentClasses}"${currentStyle ? ` style="${currentStyle}"` : ''}>${currentChars}</span>`;
        currentChars = '';
      }
    };

    // Process each cell in the line
    for (let col = 0; col < line.length; col++) {
      line.getCell(col, cell);
      if (!cell) continue;

      // XTerm.js cell API - use || ' ' to ensure we get a space for empty cells
      const char = cell.getChars() || ' ';
      const width = cell.getWidth();

      // Skip zero-width cells (part of wide characters)
      if (width === 0) continue;

      // Get styling attributes
      let classes = 'terminal-char';
      let style = '';

      // Get foreground color
      const fg = cell.getFgColor();
      if (fg !== undefined && typeof fg === 'number' && fg >= 0) {
        style += `color: var(--terminal-color-${fg});`;
      }

      // Get background color
      const bg = cell.getBgColor();
      if (bg !== undefined && typeof bg === 'number' && bg >= 0) {
        style += `background-color: var(--terminal-color-${bg});`;
      }

      // Get text attributes/flags
      const isBold = cell.isBold();
      const isItalic = cell.isItalic();
      const isUnderline = cell.isUnderline();
      const isDim = cell.isDim();

      if (isBold) classes += ' bold';
      if (isItalic) classes += ' italic';
      if (isUnderline) classes += ' underline';
      if (isDim) classes += ' dim';

      // Check if styling changed - if so, flush current group
      if (classes !== currentClasses || style !== currentStyle) {
        flushGroup();
        currentClasses = classes;
        currentStyle = style;
      }

      // Add character to current group
      currentChars += char;
    }

    // Flush final group
    flushGroup();

    return html;
  }

  // Public API methods
  public write(data: string) {
    if (this.terminal) {
      this.terminal.write(data, () => {
        this.renderBuffer();
      });
    }
  }

  public clear() {
    if (this.terminal) {
      this.terminal.clear();
      this.viewportY = 0;
      this.renderBuffer();
    }
  }

  public setViewportSize(cols: number, rows: number) {
    this.cols = cols;
    this.rows = rows;

    if (this.terminal) {
      this.terminal.resize(cols, rows);
      this.fitTerminal();
      this.renderBuffer();
    }

    this.requestUpdate();
  }

  render() {
    return html`
      <style>
        /* Terminal color variables */
        :root {
          --terminal-color-0: #000000;
          --terminal-color-1: #f14c4c;
          --terminal-color-2: #23d18b;
          --terminal-color-3: #f5f543;
          --terminal-color-4: #3b8eea;
          --terminal-color-5: #d670d6;
          --terminal-color-6: #29b8db;
          --terminal-color-7: #e5e5e5;
          --terminal-color-8: #666666;
          --terminal-color-9: #ff6b6b;
          --terminal-color-10: #5af78e;
          --terminal-color-11: #f4f99d;
          --terminal-color-12: #70a5ed;
          --terminal-color-13: #d670d6;
          --terminal-color-14: #5fb3d3;
          --terminal-color-15: #ffffff;
        }

        .dom-terminal-container {
          color: #d4d4d4;
          font-family: 'Fira Code', ui-monospace, SFMono-Regular, monospace;
          font-size: ${this.fontSize}px;
          line-height: ${this.fontSize}px;
          white-space: pre;
        }

        .terminal-line {
          display: block;
          height: ${this.fontSize * 1.2}px;
          line-height: ${this.fontSize * 1.2}px;
        }

        .terminal-char {
          font-family: inherit;
          display: inline-block;
        }

        .terminal-char.bold {
          font-weight: bold;
        }

        .terminal-char.dim {
          opacity: 0.5;
        }

        .terminal-char.italic {
          font-style: italic;
        }

        .terminal-char.underline {
          text-decoration: underline;
        }

        .terminal-char.strikethrough {
          text-decoration: line-through;
        }

        .terminal-char.inverse {
          filter: invert(1);
        }

        .terminal-char.invisible {
          opacity: 0;
        }
      </style>
      <div id="dom-terminal-container" class="dom-terminal-container w-full h-full"></div>
    `;
  }
}
