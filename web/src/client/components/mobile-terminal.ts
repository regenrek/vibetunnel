import { LitElement, html, css, nothing } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { Terminal } from '@xterm/xterm';
import { WebLinksAddon } from '@xterm/addon-web-links';
import { ScaleFitAddon } from '../scale-fit-addon.js';

// Simplified - only fit-both mode

@customElement('responsive-terminal')
export class ResponsiveTerminal extends LitElement {
  // Disable shadow DOM for Tailwind compatibility
  createRenderRoot() { return this; }

  @property({ type: String }) sessionId = '';
  @property({ type: Number }) cols = 80;
  @property({ type: Number }) rows = 24;
  @property({ type: Number }) fontSize = 14;
  // Removed fitMode - always fit-both
  @property({ type: Boolean }) showControls = false;
  @property({ type: Boolean }) enableInput = false;
  @property({ type: String }) containerClass = '';

  @state() private terminal: Terminal | null = null;
  @state() private scaleFitAddon: ScaleFitAddon | null = null;
  @state() private webLinksAddon: WebLinksAddon | null = null;
  @state() private isMobile = false;
  @state() private touches = new Map<number, any>();
  @state() private currentTerminalSize = { cols: 80, rows: 24 };
  @state() private actualLineHeight = 16;
  @state() private touchCount = 0;
  @state() private terminalStatus = 'Initializing...';

  private container: HTMLElement | null = null;
  private wrapper: HTMLElement | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private boundCopyHandler: ((e: ClipboardEvent) => void) | null = null;
  private resizeTimeout: number | null = null;

  connectedCallback() {
    super.connectedCallback();
    this.detectMobile();
    this.currentTerminalSize = { cols: this.cols, rows: this.rows };
  }

  disconnectedCallback() {
    this.cleanup();
    super.disconnectedCallback();
  }

  private detectMobile() {
    this.isMobile = window.innerWidth <= 768 || 'ontouchstart' in window;
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
    // Remove copy event listener
    if (this.boundCopyHandler) {
      document.removeEventListener('copy', this.boundCopyHandler);
      this.boundCopyHandler = null;
    }
    this.scaleFitAddon = null;
    this.webLinksAddon = null;
  }

  updated(changedProperties: Map<string, any>) {
    if (changedProperties.has('cols') || changedProperties.has('rows')) {
      this.currentTerminalSize = { cols: this.cols, rows: this.rows };
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
      this.terminalStatus = 'Initializing...';
      this.requestUpdate();

      this.container = this.querySelector('#terminal-container') as HTMLElement;
      this.wrapper = this.querySelector('#terminal-wrapper') as HTMLElement;

      if (!this.container || !this.wrapper) {
        throw new Error('Terminal container or wrapper not found');
      }

      await this.setupTerminal();
      this.setupTouchHandling();
      this.setupResize();
      this.generateMockData();

      this.terminalStatus = 'Ready';
      this.requestUpdate();
    } catch (error) {
      console.error('Failed to initialize terminal:', error);
      this.terminalStatus = `Error: ${error instanceof Error ? error.message : String(error)}`;
      this.requestUpdate();
    }
  }

  private async reinitializeTerminal() {
    if (this.terminal) {
      this.terminal.clear();
      this.fitTerminal();
      this.generateMockData();
    }
  }

  private async setupTerminal() {
    // EXACT terminal config from working file
    this.terminal = new Terminal({
      cursorBlink: false,
      fontSize: 14,
      fontFamily: 'Consolas, "Liberation Mono", monospace',
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
      }
    });

    // No addons - keep it simple like working version

    // Open terminal
    this.terminal.open(this.wrapper!);

    // Always disable default terminal handlers like working version
    this.disableDefaultTerminalHandlers();

    // Fit terminal to container
    this.fitTerminal();
  }

  private disableDefaultTerminalHandlers() {
    if (!this.terminal || !this.wrapper) return;

    // EXACT copy from working file
    const terminalEl = this.wrapper.querySelector('.xterm');
    const screenEl = this.wrapper.querySelector('.xterm-screen');
    const rowsEl = this.wrapper.querySelector('.xterm-rows');
    const textareaEl = this.wrapper.querySelector('.xterm-helper-textarea');

    if (terminalEl) {
      // Disable all default behaviors on terminal elements
      [terminalEl, screenEl, rowsEl].forEach(el => {
        if (el) {
          el.addEventListener('touchstart', (e) => e.preventDefault(), { passive: false });
          el.addEventListener('touchmove', (e) => e.preventDefault(), { passive: false });
          el.addEventListener('touchend', (e) => e.preventDefault(), { passive: false });
          el.addEventListener('wheel', this.handleWheel.bind(this), { passive: false });
          el.addEventListener('contextmenu', (e) => e.preventDefault());
        }
      });

      // Disable the hidden textarea that XTerm uses for input
      if (textareaEl) {
        textareaEl.disabled = true;
        textareaEl.readOnly = true;
        textareaEl.style.pointerEvents = 'none';
        textareaEl.addEventListener('focus', (e) => {
          e.preventDefault();
          textareaEl.blur();
        });
        console.log('Disabled XTerm input textarea');
      }

      console.log('Disabled XTerm default touch behaviors');
    }
  }

  private setupTouchHandling() {
    if (!this.wrapper) return;

    // ONLY attach touch handlers to the terminal wrapper (the XTerm content area)
    // This way buttons and other elements outside aren't affected
    this.wrapper.addEventListener('touchstart', this.handleTouchStart.bind(this), { passive: false });
    this.wrapper.addEventListener('touchmove', this.handleTouchMove.bind(this), { passive: false });
    this.wrapper.addEventListener('touchend', this.handleTouchEnd.bind(this), { passive: false });
    this.wrapper.addEventListener('touchcancel', this.handleTouchEnd.bind(this), { passive: false });

    // Prevent context menu ONLY on terminal wrapper
    this.wrapper.addEventListener('contextmenu', (e) => e.preventDefault());

    // Mouse wheel ONLY on terminal wrapper
    this.wrapper.addEventListener('wheel', this.handleWheel.bind(this) as EventListener, { passive: false });
    
    // Copy support for desktop
    this.boundCopyHandler = this.handleCopy.bind(this);
    document.addEventListener('copy', this.boundCopyHandler);
  }

  private setupResize() {
    if (!this.container) return;

    // Use debounced ResizeObserver to avoid infinite resize loops
    this.resizeObserver = new ResizeObserver(() => {
      console.log('ResizeObserver triggered, container size:', this.container?.clientWidth, 'x', this.container?.clientHeight);
      // Debounce to avoid resize loops
      clearTimeout(this.resizeTimeout);
      this.resizeTimeout = setTimeout(() => {
        this.fitTerminal();
      }, 50);
    });
    this.resizeObserver.observe(this.container);

    window.addEventListener('resize', () => {
      console.log('Window resize event triggered');
      this.detectMobile();
      this.fitTerminal();
    });
  }

  private fitTerminal() {
    if (!this.terminal || !this.container) return;

    // Use the actual rendered dimensions of the component itself
    const hostElement = this as HTMLElement;
    const containerWidth = hostElement.clientWidth;
    const containerHeight = hostElement.clientHeight;

    console.log(`Host element actual dimensions: ${containerWidth}x${containerHeight}px`);
    console.log('Host element details:', {
      element: hostElement,
      clientHeight: hostElement.clientHeight,
      offsetHeight: hostElement.offsetHeight,
      boundingRect: hostElement.getBoundingClientRect()
    });
    
    // Mobile viewport debugging
    console.log('Mobile viewport debug:', {
      windowInnerHeight: window.innerHeight,
      visualViewportHeight: window.visualViewport?.height || 'not supported',
      documentElementClientHeight: document.documentElement.clientHeight,
      bodyClientHeight: document.body.clientHeight,
      screenHeight: screen.height,
      isMobile: this.isMobile
    });

    // EXACT copy of working fitTerminal() method from mobile-terminal-test-fixed.html
    
    // Resize to target dimensions first
    this.terminal.resize(this.currentTerminalSize.cols, this.currentTerminalSize.rows);
    
    // Calculate font size to fit the target columns exactly in container width
    const charWidthRatio = 0.6; // More conservative estimate
    const calculatedFontSize = containerWidth / (this.currentTerminalSize.cols * charWidthRatio);
    const fontSize = Math.max(1, calculatedFontSize); // Allow very small fonts
    
    // Apply font size
    this.terminal.options.fontSize = fontSize;
    if (this.terminal.element) {
      this.terminal.element.style.fontSize = `${fontSize}px`;
    }
    
    // Calculate line height and rows
    const lineHeight = fontSize * 1.2;
    this.actualLineHeight = lineHeight;
    const rows = Math.max(1, Math.floor(containerHeight / lineHeight));
    
    console.log(`Height calc: container=${containerHeight}px, lineHeight=${lineHeight.toFixed(2)}px, calculated rows=${rows}`);
    
    console.log(`Fitting terminal: ${this.currentTerminalSize.cols}x${rows}, fontSize: ${fontSize.toFixed(1)}px`);
    this.terminal.resize(this.currentTerminalSize.cols, rows);
    
    // Force a refresh to apply the new sizing
    requestAnimationFrame(() => {
      if (this.terminal) {
        this.terminal.refresh(0, this.terminal.rows - 1);
        
        // After rendering, check if we need to adjust row count
        setTimeout(() => {
          const xtermRows = this.terminal.element?.querySelector('.xterm-rows');
          const firstRow = xtermRows?.children[0];
          if (firstRow && xtermRows) {
            // Use the REAL CSS line-height, not offsetHeight
            const realLineHeight = parseFloat(getComputedStyle(firstRow).lineHeight) || firstRow.offsetHeight;
            const rowsThatFit = Math.floor(containerHeight / realLineHeight);
            
            console.log(`Mobile debug: container=${containerHeight}px, realLineHeight=${realLineHeight}px, shouldFit=${rowsThatFit}, current=${this.terminal.rows}`);
            
            if (rowsThatFit !== this.terminal.rows) {
              console.log(`Adjusting from ${this.terminal.rows} to ${rowsThatFit} rows using real line height`);
              this.actualLineHeight = realLineHeight;
              this.terminal.resize(this.currentTerminalSize.cols, rowsThatFit);
            }
          }
        }, 100);
      }
    });
  }

  // Removed - not needed in simplified version

  private handleTouchStart(e: TouchEvent) {
    e.preventDefault();
    
    for (let i = 0; i < e.changedTouches.length; i++) {
      const touch = e.changedTouches[i];
      this.touches.set(touch.identifier, {
        x: touch.clientX,
        y: touch.clientY,
        startX: touch.clientX,
        startY: touch.clientY,
        startTime: Date.now()
      });
    }
    
    this.touchCount = this.touches.size;
    this.requestUpdate();
  }

  private handleTouchMove(e: TouchEvent) {
    e.preventDefault();
    
    for (let i = 0; i < e.changedTouches.length; i++) {
      const touch = e.changedTouches[i];
      const stored = this.touches.get(touch.identifier);
      if (stored) {
        stored.x = touch.clientX;
        stored.y = touch.clientY;
      }
    }
    
    if (this.touches.size === 1) {
      this.handleSingleTouch();
    }
    
    this.requestUpdate();
  }

  private handleTouchEnd(e: TouchEvent) {
    e.preventDefault();
    
    for (let i = 0; i < e.changedTouches.length; i++) {
      const touch = e.changedTouches[i];
      this.touches.delete(touch.identifier);
    }
    
    this.touchCount = this.touches.size;
    this.requestUpdate();
  }

  private handleSingleTouch() {
    const touch = Array.from(this.touches.values())[0];
    const deltaY = touch.y - touch.startY;
    
    // Only handle vertical scroll
    if (Math.abs(deltaY) > 2) {
      this.handleScroll(deltaY);
      touch.startY = touch.y; // Update immediately for smooth tracking
    }
  }

  private handleScroll(deltaY: number) {
    if (!this.terminal) return;
    
    // Simple, direct scroll calculation like the working version
    const scrollLines = Math.round(deltaY / this.actualLineHeight);
    
    if (scrollLines !== 0) {
      this.terminal.scrollLines(-scrollLines); // Negative for natural scroll direction
    }
  }

  private handleWheel(e: Event) {
    e.preventDefault();
    e.stopPropagation();
    
    const wheelEvent = e as WheelEvent;
    
    if (this.terminal) {
      // EXACT same logic as working version
      let scrollLines = 0;
      
      if (wheelEvent.deltaMode === WheelEvent.DOM_DELTA_LINE) {
        // deltaY is already in lines
        scrollLines = Math.round(wheelEvent.deltaY);
      } else if (wheelEvent.deltaMode === WheelEvent.DOM_DELTA_PIXEL) {
        // deltaY is in pixels, convert to lines
        scrollLines = Math.round(wheelEvent.deltaY / this.actualLineHeight);
      } else if (wheelEvent.deltaMode === WheelEvent.DOM_DELTA_PAGE) {
        // deltaY is in pages, convert to lines
        scrollLines = Math.round(wheelEvent.deltaY * this.terminal.rows);
      }
      
      if (scrollLines !== 0) {
        this.terminal.scrollLines(scrollLines);
      }
    }
  }

  private handleCopy(e: ClipboardEvent) {
    if (!this.terminal) return;
    
    // Get selected text from XTerm regardless of focus
    const selection = this.terminal.getSelection();
    
    if (selection && selection.trim()) {
      e.preventDefault();
      e.clipboardData?.setData('text/plain', selection);
      console.log('Copied terminal text:', selection);
    }
  }

  private handleSizeChange(cols: number, rows: number) {
    // Old method that regenerates content - keeping for backward compatibility
    this.cols = cols;
    this.rows = rows;
    this.currentTerminalSize = { cols, rows };
    
    if (this.terminal) {
      this.terminal.clear();
      this.fitTerminal();
      this.generateMockData();
    }
  }

  // New method for viewport size changes without content regeneration
  public setViewportSize(cols: number, rows: number) {
    console.log(`Setting viewport size to ${cols}x${rows} (keeping existing content)`);
    
    this.cols = cols;
    this.rows = rows;
    this.currentTerminalSize = { cols, rows };
    
    if (this.terminal) {
      // Just resize the viewport - XTerm will reflow the existing content
      this.fitTerminal();
    }
    
    this.requestUpdate(); // Update the UI to show new size in status
  }

  // Removed fitMode handling - only fit-both mode now

  private generateMockData() {
    if (!this.terminal) return;

    console.log('Generating page-based content for 120x40 (content will reflow for other sizes)...');

    // Always generate content for 120x40, regardless of current viewport size
    // This way we can see XTerm reflow the same content for different viewport sizes
    const contentCols = 120;
    const contentRows = 40;
    const numPages = 5;

    let lineNumber = 1;

    for (let page = 1; page <= numPages; page++) {
      // Page header with special characters and highlighting
      const headerLine = '\x1b[43m◄\x1b[0m' + '='.repeat(contentCols - 2) + '\x1b[43m►\x1b[0m';
      this.terminal.writeln(headerLine);
      lineNumber++;

      // Fill the page with numbered lines (rows - 2 for header/footer only)
      const contentLines = contentRows - 2;
      for (let line = 1; line <= contentLines; line++) {
        this.terminal.writeln(`Line ${lineNumber.toString().padStart(4, '0')}: Content originally sized for ${contentCols}x${contentRows} terminal - watch it reflow!`);
        lineNumber++;
      }

      // Page footer with special characters and highlighting
      const footerLine = '\x1b[43m◄\x1b[0m' + '='.repeat(contentCols - 2) + '\x1b[43m►\x1b[0m';
      this.terminal.writeln(footerLine);
      lineNumber++;
    }

    this.terminal.writeln('\x1b[1;31m>>> END OF ALL CONTENT - THIS IS THE BOTTOM <<<\x1b[0m');
    this.terminal.writeln('\x1b[1;33mIf you can see this, you reached the end. Scroll up to see all pages.\x1b[0m');

    // Ensure we can scroll to the bottom
    this.terminal.scrollToBottom();

    console.log(`Generated ${numPages} pages of content for ${contentCols}x${contentRows}`);
  }

  // Public API methods
  public write(data: string) {
    if (this.terminal) {
      this.terminal.write(data);
    }
  }

  public clear() {
    if (this.terminal) {
      this.terminal.clear();
    }
  }

  public getTerminal(): Terminal | null {
    return this.terminal;
  }

  render() {
    // EXACT aggressive CSS constraints from working file (keep as CSS for XTerm)
    const aggressiveXTermStyles = html`
      <style>
        /* Hide XTerm scrollbar */
        .xterm-viewport {
          overflow: hidden !important;
        }

        /* Ensure XTerm fills container */
        .xterm {
          width: 100% !important;
          height: 100% !important;
        }

        /* Disable text selection completely */
        * {
          -webkit-user-select: none;
          -moz-user-select: none;
          -ms-user-select: none;
          user-select: none;
          -webkit-touch-callout: none;
        }

        /* Ensure all XTerm elements don't interfere with touch */
        .xterm-screen,
        .xterm-rows,
        .xterm-row,
        .xterm span {
          pointer-events: none !important;
        }

        /* Aggressively force XTerm to stay within container bounds */
        .xterm {
          position: relative !important;
          width: 100% !important;
          height: 100% !important;
          max-width: 100% !important;
          max-height: 100% !important;
          min-width: 0 !important;
          min-height: 0 !important;
          overflow: hidden !important;
          box-sizing: border-box !important;
        }

        .xterm .xterm-screen {
          position: relative !important;
          width: 100% !important;
          height: 100% !important;
          max-width: 100% !important;
          max-height: 100% !important;
          overflow: hidden !important;
        }

        .xterm .xterm-viewport {
          width: 100% !important;
          max-width: 100% !important;
          max-height: 100% !important;
          overflow: hidden !important;
        }

        .xterm .xterm-rows {
          width: 100% !important;
          max-width: 100% !important;
          max-height: 100% !important;
          height: 100% !important;
          overflow: hidden !important;
          box-sizing: border-box !important;
        }
      </style>
    `;

    return html`
      ${aggressiveXTermStyles}
      <div id="terminal-container" class="relative w-full h-full bg-gray-900">
        ${this.showControls ? this.renderControls() : nothing}
        ${this.renderStatus()}
        <div id="terminal-wrapper" class="w-full h-full touch-none"></div>
      </div>
    `;
  }

  private renderControls() {
    const sizeOptions = [
      { cols: 60, rows: 15, label: '60x15' },
      { cols: 80, rows: 20, label: '80x20' },
      { cols: 120, rows: 40, label: '120x40' },
      { cols: 160, rows: 50, label: '160x50' },
    ];

    // Use position: fixed like working version so controls don't affect layout
    return html`
      <div class="fixed top-2 left-2 z-50 flex gap-1 flex-wrap max-w-xs">
        ${sizeOptions.map(size => html`
          <button
            class="px-2 py-1 text-xs font-mono bg-black/80 text-white border border-gray-600 rounded hover:bg-gray-800 cursor-pointer
                   ${this.cols === size.cols && this.rows === size.rows ? 'bg-blue-600 border-blue-400' : ''}"
            @click=${() => this.handleSizeChange(size.cols, size.rows)}
          >
            ${size.label}
          </button>
        `)}
      </div>
    `;
  }

  private renderStatus() {
    // Position relative to the component, not the viewport
    return html`
      <div class="absolute top-2 left-2 bg-black/80 text-white p-2 rounded text-xs z-40 pointer-events-none font-mono">
        <div>Size: ${this.currentTerminalSize.cols}x${this.currentTerminalSize.rows}</div>
        <div>Font: ${this.terminal?.options.fontSize?.toFixed(1) || 14}px</div>
        <div>Touch: ${this.touchCount}</div>
        <div>Status: ${this.terminalStatus}</div>
        <div>Device: ${this.isMobile ? 'Mobile' : 'Desktop'}</div>
      </div>
    `;
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'responsive-terminal': ResponsiveTerminal;
  }
}