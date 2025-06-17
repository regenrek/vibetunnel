import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { Terminal as XtermTerminal, IBufferLine, IBufferCell } from '@xterm/xterm';

@customElement('vibe-terminal')
export class Terminal extends LitElement {
  // Disable shadow DOM for Tailwind compatibility and native text selection
  createRenderRoot() {
    return this as unknown as HTMLElement;
  }

  @property({ type: String }) sessionId = '';
  @property({ type: Number }) cols = 80;
  @property({ type: Number }) rows = 24;
  @property({ type: Number }) fontSize = 14;
  @property({ type: Boolean }) fitHorizontally = false;

  private originalFontSize: number = 14;

  @state() private terminal: XtermTerminal | null = null;
  @state() private viewportY = 0; // Current scroll position
  @state() private actualRows = 24; // Rows that fit in viewport

  private container: HTMLElement | null = null;
  private resizeObserver: ResizeObserver | null = null;
  private resizeTimeout: NodeJS.Timeout | null = null;

  // Virtual scrolling optimization
  private renderPending = false;
  private scrollAccumulator = 0;
  private touchScrollAccumulator = 0;
  private isTouchActive = false;

  // Operation queue for batching buffer modifications
  private operationQueue: (() => void)[] = [];

  private queueOperation(operation: () => void) {
    this.operationQueue.push(operation);

    if (!this.renderPending) {
      this.renderPending = true;
      requestAnimationFrame(() => {
        this.processOperationQueue();
        this.renderPending = false;
      });
    }
  }

  private processOperationQueue() {
    const queueStart = performance.now();
    const operationCount = this.operationQueue.length;

    // Process all queued operations in order
    while (this.operationQueue.length > 0) {
      const operation = this.operationQueue.shift()!;
      operation();
    }

    const queueEnd = performance.now();
    console.log(
      `Processed ${operationCount} operations in ${(queueEnd - queueStart).toFixed(2)}ms`
    );

    // Render once after all operations are complete
    this.renderBuffer();
  }

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
    if (changedProperties.has('fontSize')) {
      // Store original font size when it changes (but not during horizontal fitting)
      if (!this.fitHorizontally) {
        this.originalFontSize = this.fontSize;
      }
    }
    if (changedProperties.has('fitHorizontally')) {
      if (!this.fitHorizontally) {
        // Restore original font size when turning off horizontal fitting
        this.fontSize = this.originalFontSize;
      }
      this.fitTerminal();
    }
  }

  firstUpdated() {
    // Store the initial font size as original
    this.originalFontSize = this.fontSize;
    this.initializeTerminal();
  }

  private async initializeTerminal() {
    try {
      this.requestUpdate();

      this.container = this.querySelector('#terminal-container') as HTMLElement;

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
      this.terminal = new XtermTerminal({
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

  private measureCharacterWidth(): number {
    if (!this.container) return 8;

    // Create temporary element with same styles as terminal content, attached to container
    const measureEl = document.createElement('div');
    measureEl.className = 'terminal-line';
    measureEl.style.position = 'absolute';
    measureEl.style.visibility = 'hidden';
    measureEl.style.top = '0';
    measureEl.style.left = '0';
    measureEl.style.fontSize = `${this.fontSize}px`;
    measureEl.style.fontFamily = 'Fira Code, monospace';

    // Use a mix of characters that represent typical terminal content
    const testString =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:,.<>?';
    const repeatCount = Math.ceil(this.cols / testString.length);
    const testContent = testString.repeat(repeatCount).substring(0, this.cols);
    measureEl.textContent = testContent;

    // Attach to container so it inherits all the proper CSS context
    this.container.appendChild(measureEl);
    const measureRect = measureEl.getBoundingClientRect();
    const actualCharWidth = measureRect.width / this.cols;
    this.container.removeChild(measureEl);

    return actualCharWidth;
  }

  private fitTerminal() {
    if (!this.terminal || !this.container) return;

    if (this.fitHorizontally) {
      // Horizontal fitting: calculate fontSize to fit this.cols characters in container width
      const containerWidth = this.container.clientWidth;
      const containerHeight = this.container.clientHeight;
      const targetCharWidth = containerWidth / this.cols;

      // Calculate fontSize needed for target character width
      // Use current font size as starting point and measure actual character width
      const currentCharWidth = this.measureCharacterWidth();
      const scaleFactor = targetCharWidth / currentCharWidth;
      const calculatedFontSize = this.fontSize * scaleFactor;
      const newFontSize = Math.max(4, Math.min(32, calculatedFontSize));

      this.fontSize = newFontSize;

      // Also fit rows to use full container height with the new font size
      const lineHeight = this.fontSize * 1.2;
      const fittedRows = Math.max(1, Math.floor(containerHeight / lineHeight));

      // Update both actualRows and the terminal's actual row count
      this.actualRows = fittedRows;
      this.rows = fittedRows;

      // Resize the terminal to the new dimensions
      if (this.terminal) {
        this.terminal.resize(this.cols, this.rows);
      }
    } else {
      // Normal mode: just calculate how many rows fit in the viewport
      const containerHeight = this.container.clientHeight;
      const lineHeight = this.fontSize * 1.2;
      this.actualRows = Math.max(1, Math.floor(containerHeight / lineHeight));
    }

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

    // Handle pointer events for mobile/touch scrolling only
    let pointerStartY = 0;
    let lastY = 0;
    let isScrolling = false;
    let velocity = 0;
    let lastPointerTime = 0;

    const handlePointerDown = (e: PointerEvent) => {
      // Only handle touch pointers, not mouse
      if (e.pointerType !== 'touch' || !e.isPrimary) return;

      this.isTouchActive = true;
      isScrolling = false;
      pointerStartY = e.clientY;
      lastY = e.clientY;
      velocity = 0;
      lastPointerTime = Date.now();
      this.touchScrollAccumulator = 0; // Reset accumulator on new pointer down

      // Capture the pointer so we continue to receive events even if DOM rebuilds
      this.container?.setPointerCapture(e.pointerId);
    };

    const handlePointerMove = (e: PointerEvent) => {
      // Only handle touch pointers that we have captured
      if (e.pointerType !== 'touch' || !this.container?.hasPointerCapture(e.pointerId)) return;

      const currentY = e.clientY;
      const deltaY = lastY - currentY; // Change since last move, not since start
      const currentTime = Date.now();

      // Start scrolling if we've moved more than a few pixels
      if (!isScrolling && Math.abs(currentY - pointerStartY) > 5) {
        isScrolling = true;
      }

      if (!isScrolling) return;

      // Calculate velocity for momentum (pixels per millisecond, recent movement only)
      const timeDelta = currentTime - lastPointerTime;
      if (timeDelta > 0) {
        velocity = deltaY / timeDelta; // Use recent deltaY, not total
      }
      lastPointerTime = currentTime;

      // Accumulate pointer scroll delta for smooth scrolling with small movements
      this.touchScrollAccumulator += deltaY;

      const lineHeight = this.fontSize * 1.2;
      const deltaLines = Math.trunc(this.touchScrollAccumulator / lineHeight);

      if (Math.abs(deltaLines) >= 1) {
        this.scrollViewport(deltaLines);
        // Subtract the scrolled amount, keep remainder for next pointer move
        this.touchScrollAccumulator -= deltaLines * lineHeight;
      }

      lastY = currentY; // Update for next move event
    };

    const handlePointerUp = (e: PointerEvent) => {
      // Only handle touch pointers
      if (e.pointerType !== 'touch') return;

      this.isTouchActive = false;

      // Release pointer capture
      this.container?.releasePointerCapture(e.pointerId);

      // Add momentum scrolling if needed (only after touch scrolling)
      if (isScrolling && Math.abs(velocity) > 0.5) {
        this.startMomentumScroll(velocity);
      }
    };

    const handlePointerCancel = (e: PointerEvent) => {
      // Only handle touch pointers
      if (e.pointerType !== 'touch') return;

      this.isTouchActive = false;

      // Release pointer capture
      this.container?.releasePointerCapture(e.pointerId);
    };

    // Attach pointer events to the container (touch only)
    this.container.addEventListener('pointerdown', handlePointerDown);
    this.container.addEventListener('pointermove', handlePointerMove);
    this.container.addEventListener('pointerup', handlePointerUp);
    this.container.addEventListener('pointercancel', handlePointerCancel);
  }

  private startMomentumScroll(initialVelocity: number) {
    let velocity = initialVelocity * 0.8; // Scale down initial velocity for smoother feel
    let accumulatedScroll = 0;
    let frameCount = 0;

    const animate = () => {
      // Stop when velocity becomes very small
      if (Math.abs(velocity) < 0.001) return;

      frameCount++;

      // macOS-like deceleration curve - more natural feel
      const friction = frameCount < 10 ? 0.98 : frameCount < 30 ? 0.96 : 0.92;

      // Convert velocity (pixels/ms) to pixels per frame
      const pixelsPerFrame = velocity * 16; // 16ms frame time
      accumulatedScroll += pixelsPerFrame;

      // Convert accumulated pixels to lines
      const lineHeight = this.fontSize * 1.2;
      const deltaLines = Math.trunc(accumulatedScroll / lineHeight);

      if (Math.abs(deltaLines) >= 1) {
        this.scrollViewport(deltaLines);
        // Subtract the scrolled amount, keep remainder
        accumulatedScroll -= deltaLines * lineHeight;
      }

      // Apply friction
      velocity *= friction;
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

    const renderStart = performance.now();

    const buffer = this.terminal.buffer.active;
    const bufferLength = buffer.length;
    const startRow = Math.min(this.viewportY, Math.max(0, bufferLength - this.actualRows));

    const bufferPrepStart = performance.now();

    // Build complete innerHTML string
    let html = '';
    const cell = buffer.getNullCell();

    // Get cursor position
    const cursorX = this.terminal.buffer.active.cursorX;
    const cursorY = this.terminal.buffer.active.cursorY;

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

      // Check if cursor is on this line (relative to viewport)
      const isCursorLine = row === cursorY;
      const lineContent = this.renderLine(line, cell, isCursorLine ? cursorX : -1);
      html += `<div class="terminal-line">${lineContent || ''}</div>`;
    }

    const bufferPrepEnd = performance.now();
    const domUpdateStart = performance.now();

    // Set the complete innerHTML at once
    this.container.innerHTML = html;

    const domUpdateEnd = performance.now();
    const linkProcessStart = performance.now();

    // Process links after rendering
    this.processLinks();

    const linkProcessEnd = performance.now();
    const renderEnd = performance.now();

    const totalTime = renderEnd - renderStart;
    const bufferPrepTime = bufferPrepEnd - bufferPrepStart;
    const domUpdateTime = domUpdateEnd - domUpdateStart;
    const linkProcessTime = linkProcessEnd - linkProcessStart;

    console.log(
      `Render performance: ${totalTime.toFixed(2)}ms total (buffer: ${bufferPrepTime.toFixed(2)}ms, DOM: ${domUpdateTime.toFixed(2)}ms, links: ${linkProcessTime.toFixed(2)}ms) - ${this.actualRows} rows`
    );
  }

  private renderLine(line: IBufferLine, cell: IBufferCell, cursorCol: number = -1): string {
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

      // Check if this is the cursor position
      const isCursor = col === cursorCol;
      if (isCursor) {
        classes += ' cursor';
      }

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

      // Override background for cursor
      if (isCursor) {
        style += `background-color: #23d18b;`;
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

  /**
   * DOM Terminal Public API
   *
   * This component provides a DOM-based terminal renderer with XTerm.js backend.
   * All buffer-modifying operations are queued and executed in requestAnimationFrame
   * to ensure optimal batching and rendering performance.
   */

  // === BUFFER MODIFICATION METHODS (Queued) ===

  /**
   * Write data to the terminal buffer.
   * @param data - String data to write (supports ANSI escape sequences)
   */
  public write(data: string) {
    if (!this.terminal) return;

    this.queueOperation(() => {
      const writeStart = performance.now();
      this.terminal!.write(data);
      const writeEnd = performance.now();
      console.log(
        `XTerm write took: ${(writeEnd - writeStart).toFixed(2)}ms for ${data.length} chars`
      );
    });
  }

  /**
   * Clear the terminal buffer and reset scroll position.
   */
  public clear() {
    if (!this.terminal) return;

    this.queueOperation(() => {
      this.terminal!.clear();
      this.viewportY = 0;
    });
  }

  /**
   * Resize the terminal to specified dimensions.
   * @param cols - Number of columns
   * @param rows - Number of rows
   */
  public setTerminalSize(cols: number, rows: number) {
    this.cols = cols;
    this.rows = rows;

    if (!this.terminal) return;

    this.queueOperation(() => {
      this.terminal!.resize(cols, rows);
      this.fitTerminal();
      this.requestUpdate();
    });
  }

  // === SCROLL CONTROL METHODS (Queued) ===

  /**
   * Scroll to the bottom of the buffer.
   */
  public scrollToBottom() {
    if (!this.terminal) return;

    this.queueOperation(() => {
      const buffer = this.terminal!.buffer.active;
      const maxScroll = Math.max(0, buffer.length - this.actualRows);
      this.viewportY = maxScroll;
    });
  }

  /**
   * Scroll to a specific position in the buffer.
   * @param position - Line position (0 = top, max = bottom)
   */
  public scrollTo(position: number) {
    if (!this.terminal) return;

    this.queueOperation(() => {
      const buffer = this.terminal!.buffer.active;
      const maxScroll = Math.max(0, buffer.length - this.actualRows);
      this.viewportY = Math.max(0, Math.min(maxScroll, position));
    });
  }

  /**
   * Queue a custom operation to be executed after the next render is complete.
   * Useful for actions that need to happen after terminal state is fully updated.
   * @param callback - Function to execute after render
   */
  public queueCallback(callback: () => void) {
    this.queueOperation(callback);
  }

  // === QUERY METHODS (Immediate) ===

  private checkPendingOperations() {
    if (this.operationQueue.length > 0) {
      throw new Error(
        `Cannot read terminal state: ${this.operationQueue.length} operations pending in RAF queue. Data may be stale.`
      );
    }
  }

  /**
   * Get terminal dimensions.
   * @returns Object with cols and rows
   * @throws Error if operations are pending in RAF queue
   */
  public getTerminalSize(): { cols: number; rows: number } {
    this.checkPendingOperations();
    return {
      cols: this.cols,
      rows: this.rows,
    };
  }

  /**
   * Get number of visible rows in the current viewport.
   * @returns Number of rows that fit in the viewport
   * @throws Error if operations are pending in RAF queue
   */
  public getVisibleRows(): number {
    this.checkPendingOperations();
    return this.actualRows;
  }

  /**
   * Get total number of lines in the scrollback buffer.
   * @returns Total lines in buffer
   * @throws Error if operations are pending in RAF queue
   */
  public getBufferSize(): number {
    this.checkPendingOperations();
    if (!this.terminal) return 0;
    return this.terminal.buffer.active.length;
  }

  /**
   * Get current scroll position.
   * @returns Current scroll position (0 = top)
   * @throws Error if operations are pending in RAF queue
   */
  public getScrollPosition(): number {
    this.checkPendingOperations();
    return this.viewportY;
  }

  /**
   * Get maximum possible scroll position.
   * @returns Maximum scroll position
   * @throws Error if operations are pending in RAF queue
   */
  public getMaxScrollPosition(): number {
    this.checkPendingOperations();
    if (!this.terminal) return 0;
    const buffer = this.terminal.buffer.active;
    return Math.max(0, buffer.length - this.actualRows);
  }

  private processLinks() {
    if (!this.container) return;

    // Get all terminal lines
    const lines = this.container.querySelectorAll('.terminal-line');
    if (lines.length === 0) return;

    for (let i = 0; i < lines.length; i++) {
      const lineText = this.getLineText(lines[i]);

      // Look for http(s):// in this line
      const httpMatch = lineText.match(/(https?:\/\/)/);
      if (httpMatch) {
        const urlStart = httpMatch.index!;
        let fullUrl = '';
        let endLine = i;

        // Build the URL by scanning from the http part until we hit whitespace
        for (let j = i; j < lines.length; j++) {
          let remainingText = '';

          if (j === i) {
            // Current line: start from http position
            remainingText = lineText.substring(urlStart);
          } else {
            // Subsequent lines: take the whole trimmed line
            remainingText = this.getLineText(lines[j]).trim();
          }

          // Stop if line is empty (after trimming)
          if (remainingText === '') {
            endLine = j - 1; // URL ended on previous line
            break;
          }

          // Find first whitespace character in this line's text
          const whitespaceMatch = remainingText.match(/\s/);
          if (whitespaceMatch) {
            // Found whitespace, URL ends here
            fullUrl += remainingText.substring(0, whitespaceMatch.index);
            endLine = j;
            break;
          } else {
            // No whitespace, take the whole line
            fullUrl += remainingText;
            endLine = j;

            // If this is the last line, we're done
            if (j === lines.length - 1) break;
          }
        }

        // Now create links for this URL across the lines it spans
        if (fullUrl.length > 7) {
          // More than just "http://"
          this.createUrlLinks(lines, fullUrl, i, endLine, urlStart);
        }
      }
    }
  }

  private createUrlLinks(
    lines: NodeListOf<Element>,
    fullUrl: string,
    startLine: number,
    endLine: number,
    startCol: number
  ) {
    let remainingUrl = fullUrl;

    for (let lineIdx = startLine; lineIdx <= endLine; lineIdx++) {
      const line = lines[lineIdx];
      const lineText = this.getLineText(line);

      if (lineIdx === startLine) {
        // First line: URL starts at startCol
        const lineUrlPart = lineText.substring(startCol);
        const urlPartLength = Math.min(lineUrlPart.length, remainingUrl.length);

        this.createClickableInLine(line, fullUrl, 'url', startCol, startCol + urlPartLength);
        remainingUrl = remainingUrl.substring(urlPartLength);
      } else {
        // Subsequent lines: take from start of trimmed content
        const trimmedLine = lineText.trim();
        const urlPartLength = Math.min(trimmedLine.length, remainingUrl.length);

        if (urlPartLength > 0) {
          const startColForLine = lineText.indexOf(trimmedLine);
          this.createClickableInLine(
            line,
            fullUrl,
            'url',
            startColForLine,
            startColForLine + urlPartLength
          );
          remainingUrl = remainingUrl.substring(urlPartLength);
        }
      }

      if (remainingUrl.length === 0) break;
    }
  }

  private getLineText(lineElement: Element): string {
    // Get the text content, preserving spaces but removing HTML tags
    const textContent = lineElement.textContent || '';
    return textContent;
  }

  private createClickableInLine(
    lineElement: Element,
    url: string,
    type: 'url',
    startCol: number,
    endCol: number
  ) {
    if (startCol >= endCol) return;

    // We need to work with the actual DOM structure, not just text
    const walker = document.createTreeWalker(lineElement, NodeFilter.SHOW_TEXT, null);

    const textNodes: Text[] = [];
    let node;
    while ((node = walker.nextNode())) {
      textNodes.push(node as Text);
    }

    let currentPos = 0;
    let foundStart = false;
    let foundEnd = false;

    for (const textNode of textNodes) {
      const nodeText = textNode.textContent || '';
      const nodeStart = currentPos;
      const nodeEnd = currentPos + nodeText.length;

      // Check if this text node contains part of our link
      if (!foundEnd && nodeEnd > startCol && nodeStart < endCol) {
        const linkStart = Math.max(0, startCol - nodeStart);
        const linkEnd = Math.min(nodeText.length, endCol - nodeStart);

        if (linkStart < linkEnd) {
          this.wrapTextInClickable(
            textNode,
            linkStart,
            linkEnd,
            url,
            !foundStart,
            nodeEnd >= endCol
          );
          foundStart = true;
          if (nodeEnd >= endCol) {
            foundEnd = true;
            break;
          }
        }
      }

      currentPos = nodeEnd;
    }
  }

  private wrapTextInClickable(
    textNode: Text,
    start: number,
    end: number,
    url: string,
    _isFirst: boolean,
    _isLast: boolean
  ) {
    const parent = textNode.parentNode;
    if (!parent) return;

    const nodeText = textNode.textContent || '';
    const beforeText = nodeText.substring(0, start);
    const linkText = nodeText.substring(start, end);
    const afterText = nodeText.substring(end);

    // Create the link element
    const linkElement = document.createElement('a');
    linkElement.className = 'terminal-link';
    linkElement.href = url;
    linkElement.target = '_blank';
    linkElement.rel = 'noopener noreferrer';
    linkElement.style.color = '#4fc3f7';
    linkElement.style.textDecoration = 'underline';
    linkElement.style.cursor = 'pointer';
    linkElement.textContent = linkText;

    // Add hover effects
    linkElement.addEventListener('mouseenter', () => {
      linkElement.style.backgroundColor = 'rgba(79, 195, 247, 0.2)';
    });

    linkElement.addEventListener('mouseleave', () => {
      linkElement.style.backgroundColor = '';
    });

    // Replace the text node with the new structure
    const fragment = document.createDocumentFragment();

    if (beforeText) {
      fragment.appendChild(document.createTextNode(beforeText));
    }

    fragment.appendChild(linkElement);

    if (afterText) {
      fragment.appendChild(document.createTextNode(afterText));
    }

    parent.replaceChild(fragment, textNode);
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

        .terminal-container {
          color: #d4d4d4;
          font-family: 'Fira Code', ui-monospace, SFMono-Regular, monospace;
          font-size: ${this.fontSize}px;
          line-height: ${this.fontSize * 1.2}px;
          white-space: pre;
          touch-action: none;
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

        .terminal-char.cursor {
          animation: cursor-blink 1s infinite;
        }

        @keyframes cursor-blink {
          0%,
          50% {
            opacity: 1;
          }
          51%,
          100% {
            opacity: 0.3;
          }
        }

        .terminal-link {
          color: #4fc3f7;
          text-decoration: underline;
          cursor: pointer;
          transition: background-color 0.2s ease;
        }

        .terminal-link:hover {
          background-color: rgba(79, 195, 247, 0.2);
        }
      </style>
      <div id="terminal-container" class="terminal-container w-full h-full"></div>
    `;
  }
}
