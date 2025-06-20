import { Terminal as XtermTerminal } from '@xterm/headless';
import * as fs from 'fs';
import * as path from 'path';

interface SessionTerminal {
  terminal: XtermTerminal;
  watcher?: fs.FSWatcher;
  lastUpdate: number;
}

interface BufferCell {
  char: string;
  width: number;
  fg?: number;
  bg?: number;
  attributes?: number;
}

interface BufferSnapshot {
  cols: number;
  rows: number;
  viewportY: number;
  cursorX: number;
  cursorY: number;
  cells: BufferCell[][];
}

export class TerminalManager {
  private terminals: Map<string, SessionTerminal> = new Map();
  private controlDir: string;

  constructor(controlDir: string) {
    this.controlDir = controlDir;
  }

  /**
   * Get or create a terminal for a session
   */
  async getTerminal(sessionId: string): Promise<XtermTerminal> {
    let sessionTerminal = this.terminals.get(sessionId);

    if (!sessionTerminal) {
      // Create new terminal
      const terminal = new XtermTerminal({
        cols: 80,
        rows: 24,
        scrollback: 10000,
        allowProposedApi: true,
        convertEol: true,
      });

      sessionTerminal = {
        terminal,
        lastUpdate: Date.now(),
      };

      this.terminals.set(sessionId, sessionTerminal);

      // Start watching the stream file
      await this.watchStreamFile(sessionId);
    }

    sessionTerminal.lastUpdate = Date.now();
    return sessionTerminal.terminal;
  }

  /**
   * Watch stream file for changes
   */
  private async watchStreamFile(sessionId: string): Promise<void> {
    const sessionTerminal = this.terminals.get(sessionId);
    if (!sessionTerminal) return;

    const streamPath = path.join(this.controlDir, sessionId, 'stream-out');
    let lastOffset = 0;
    let lineBuffer = '';

    // Check if the file exists
    if (!fs.existsSync(streamPath)) {
      console.warn(`Stream file does not exist for session ${sessionId}: ${streamPath}`);
      return;
    }

    try {
      // Read existing content first
      const content = fs.readFileSync(streamPath, 'utf8');
      lastOffset = Buffer.byteLength(content, 'utf8');

      // Process existing content
      const lines = content.split('\n');
      for (const line of lines) {
        if (line.trim()) {
          this.handleStreamLine(sessionId, sessionTerminal, line);
        }
      }

      // Watch for changes
      sessionTerminal.watcher = fs.watch(streamPath, (eventType) => {
        if (eventType === 'change') {
          try {
            const stats = fs.statSync(streamPath);
            if (stats.size > lastOffset) {
              // Read only the new data
              const fd = fs.openSync(streamPath, 'r');
              const buffer = Buffer.alloc(stats.size - lastOffset);
              fs.readSync(fd, buffer, 0, buffer.length, lastOffset);
              fs.closeSync(fd);

              // Update offset
              lastOffset = stats.size;

              // Process new data
              const newData = buffer.toString('utf8');
              lineBuffer += newData;

              // Process complete lines
              const lines = lineBuffer.split('\n');
              lineBuffer = lines.pop() || ''; // Keep incomplete line for next time

              for (const line of lines) {
                if (line.trim()) {
                  this.handleStreamLine(sessionId, sessionTerminal, line);
                }
              }
            }
          } catch (error) {
            console.error(`Error reading stream file for session ${sessionId}:`, error);
          }
        }
      });

      console.log(`Watching stream file for session ${sessionId}`);
    } catch (error) {
      console.error(`Failed to watch stream file for session ${sessionId}:`, error);
      throw error;
    }
  }

  /**
   * Handle stream line
   */
  private handleStreamLine(sessionId: string, sessionTerminal: SessionTerminal, line: string) {
    try {
      const data = JSON.parse(line);

      // Handle asciinema header
      if (data.version && data.width && data.height) {
        sessionTerminal.terminal.resize(data.width, data.height);
        return;
      }

      // Handle asciinema events [timestamp, type, data]
      if (Array.isArray(data) && data.length >= 3) {
        const [timestamp, type, eventData] = data;

        if (timestamp === 'exit') {
          // Session exited
          console.log(`Session ${sessionId} exited with code ${data[1]}`);
          if (sessionTerminal.watcher) {
            sessionTerminal.watcher.close();
          }
          return;
        }

        if (type === 'o') {
          // Output event - write to terminal
          sessionTerminal.terminal.write(eventData);
        } else if (type === 'r') {
          // Resize event
          const match = eventData.match(/^(\d+)x(\d+)$/);
          if (match) {
            const cols = parseInt(match[1], 10);
            const rows = parseInt(match[2], 10);
            sessionTerminal.terminal.resize(cols, rows);
          }
        }
        // Ignore 'i' (input) events
      }
    } catch (error) {
      console.error(`Failed to parse stream line for session ${sessionId}:`, error);
    }
  }

  /**
   * Get buffer stats for a session
   */
  async getBufferStats(sessionId: string) {
    const terminal = await this.getTerminal(sessionId);
    const buffer = terminal.buffer.active;

    return {
      totalRows: buffer.length,
      cols: terminal.cols,
      rows: terminal.rows,
      viewportY: buffer.viewportY,
      cursorX: buffer.cursorX,
      cursorY: buffer.cursorY,
      scrollback: terminal.options.scrollback || 0,
    };
  }

  /**
   * Get buffer snapshot for a session
   */
  async getBufferSnapshot(
    sessionId: string,
    viewportY: number | undefined,
    lines: number
  ): Promise<BufferSnapshot> {
    const terminal = await this.getTerminal(sessionId);
    const buffer = terminal.buffer.active;

    let startLine: number;
    let actualViewportY: number;

    if (viewportY === undefined) {
      // Get lines from bottom - calculate start position
      startLine = Math.max(0, buffer.length - lines);
      actualViewportY = startLine;
    } else {
      // Use specified viewport position
      startLine = Math.max(0, viewportY);
      actualViewportY = viewportY;
    }

    const endLine = Math.min(buffer.length, startLine + lines);
    const actualLines = endLine - startLine;

    // Get cursor position relative to our viewport
    const cursorX = buffer.cursorX;
    const cursorY = buffer.cursorY + buffer.viewportY - actualViewportY;

    // Extract cells
    const cells: BufferCell[][] = [];
    const cell = buffer.getNullCell();

    for (let row = 0; row < actualLines; row++) {
      const line = buffer.getLine(startLine + row);
      const rowCells: BufferCell[] = [];

      if (line) {
        for (let col = 0; col < terminal.cols; col++) {
          line.getCell(col, cell);

          const char = cell.getChars() || ' ';
          const width = cell.getWidth();

          // Skip zero-width cells (part of wide characters)
          if (width === 0) continue;

          // Build attributes byte
          let attributes = 0;
          if (cell.isBold()) attributes |= 0x01;
          if (cell.isItalic()) attributes |= 0x02;
          if (cell.isUnderline()) attributes |= 0x04;
          if (cell.isDim()) attributes |= 0x08;
          if (cell.isInverse()) attributes |= 0x10;
          if (cell.isInvisible()) attributes |= 0x20;
          if (cell.isStrikethrough()) attributes |= 0x40;

          const bufferCell: BufferCell = {
            char,
            width,
          };

          // Only include non-default values
          const fg = cell.getFgColor();
          const bg = cell.getBgColor();

          // Handle color values - -1 means default color
          if (fg !== undefined && fg !== -1) bufferCell.fg = fg;
          if (bg !== undefined && bg !== -1) bufferCell.bg = bg;
          if (attributes !== 0) bufferCell.attributes = attributes;

          rowCells.push(bufferCell);
        }
      } else {
        // Empty line - fill with spaces
        for (let col = 0; col < terminal.cols; col++) {
          rowCells.push({ char: ' ', width: 1 });
        }
      }

      cells.push(rowCells);
    }

    return {
      cols: terminal.cols,
      rows: actualLines,
      viewportY: actualViewportY,
      cursorX,
      cursorY,
      cells,
    };
  }

  /**
   * Encode buffer snapshot to binary format
   */
  encodeSnapshot(snapshot: BufferSnapshot): Buffer {
    const { cols, rows, viewportY, cursorX, cursorY, cells } = snapshot;

    // Calculate buffer size (rough estimate)
    const estimatedSize = 32 + rows * cols * 4; // Increased header size
    const buffer = Buffer.allocUnsafe(estimatedSize);
    let offset = 0;

    // Write header (32 bytes)
    buffer.writeUInt16LE(0x5654, offset);
    offset += 2; // Magic "VT"
    buffer.writeUInt8(0x02, offset); // Version 2 with 32-bit values
    offset += 1; // Version
    buffer.writeUInt8(0x00, offset);
    offset += 1; // Flags
    buffer.writeUInt32LE(cols, offset);
    offset += 4; // Cols (32-bit)
    buffer.writeUInt32LE(rows, offset);
    offset += 4; // Rows (32-bit)
    buffer.writeInt32LE(viewportY, offset); // Signed for large buffers
    offset += 4; // ViewportY (32-bit signed)
    buffer.writeInt32LE(cursorX, offset); // Signed for consistency
    offset += 4; // CursorX (32-bit signed)
    buffer.writeInt32LE(cursorY, offset); // Signed for relative positions
    offset += 4; // CursorY (32-bit signed)
    buffer.writeUInt32LE(0, offset);
    offset += 4; // Reserved

    // Write cells with run-length encoding
    let lastCell: BufferCell | null = null;
    let runCount = 0;

    const flushRun = () => {
      if (lastCell && runCount > 0) {
        if (runCount > 1) {
          // Use RLE for repeated cells
          buffer.writeUInt8(0xff, offset++);
          buffer.writeUInt8(runCount, offset++);
        }

        // Write cell
        const charCode = lastCell.char.charCodeAt(0);
        const isExtended =
          charCode > 127 ||
          (lastCell.fg !== undefined && lastCell.fg > 255) ||
          (lastCell.bg !== undefined && lastCell.bg > 255);

        if (!isExtended) {
          // Basic cell (4 bytes)
          buffer.writeUInt8(charCode, offset++);
          buffer.writeUInt8(lastCell.attributes || 0, offset++);
          buffer.writeUInt8(lastCell.fg ?? 7, offset++); // Default white on black
          buffer.writeUInt8(lastCell.bg ?? 0, offset++);
        } else {
          // Extended cell
          const charBytes = Buffer.from(lastCell.char, 'utf8');
          const hasRgbFg = lastCell.fg !== undefined && lastCell.fg > 255;
          const hasRgbBg = lastCell.bg !== undefined && lastCell.bg > 255;

          // Header byte
          const header =
            ((charBytes.length - 1) << 6) | (hasRgbFg ? 0x20 : 0) | (hasRgbBg ? 0x10 : 0) | 0x80; // Extended flag

          buffer.writeUInt8(header, offset++);
          buffer.writeUInt8((lastCell.attributes || 0) | 0x80, offset++);

          // Character
          charBytes.copy(buffer, offset);
          offset += charBytes.length;

          // Colors
          if (hasRgbFg && lastCell.fg !== undefined) {
            buffer.writeUInt8((lastCell.fg >> 16) & 0xff, offset++);
            buffer.writeUInt8((lastCell.fg >> 8) & 0xff, offset++);
            buffer.writeUInt8(lastCell.fg & 0xff, offset++);
          } else {
            buffer.writeUInt8(lastCell.fg ?? 7, offset++);
          }

          if (hasRgbBg && lastCell.bg !== undefined) {
            buffer.writeUInt8((lastCell.bg >> 16) & 0xff, offset++);
            buffer.writeUInt8((lastCell.bg >> 8) & 0xff, offset++);
            buffer.writeUInt8(lastCell.bg & 0xff, offset++);
          } else {
            buffer.writeUInt8(lastCell.bg ?? 0, offset++);
          }
        }
      }
    };

    // Process cells
    for (const row of cells) {
      for (const cell of row) {
        if (
          lastCell &&
          cell.char === lastCell.char &&
          cell.fg === lastCell.fg &&
          cell.bg === lastCell.bg &&
          cell.attributes === lastCell.attributes &&
          runCount < 255
        ) {
          runCount++;
        } else {
          flushRun();
          lastCell = cell;
          runCount = 1;
        }
      }
    }

    // Flush final run
    flushRun();

    // Return trimmed buffer
    return buffer.subarray(0, offset);
  }

  /**
   * Close a terminal session
   */
  closeTerminal(sessionId: string): void {
    const sessionTerminal = this.terminals.get(sessionId);
    if (sessionTerminal) {
      if (sessionTerminal.watcher) {
        sessionTerminal.watcher.close();
      }
      sessionTerminal.terminal.dispose();
      this.terminals.delete(sessionId);
    }
  }

  /**
   * Clean up old terminals
   */
  cleanup(maxAge: number = 30 * 60 * 1000): void {
    const now = Date.now();
    const toRemove: string[] = [];

    for (const [sessionId, sessionTerminal] of this.terminals) {
      if (now - sessionTerminal.lastUpdate > maxAge) {
        toRemove.push(sessionId);
      }
    }

    for (const sessionId of toRemove) {
      console.log(`Cleaning up stale terminal for session ${sessionId}`);
      this.closeTerminal(sessionId);
    }
  }

  /**
   * Get all active terminals
   */
  getActiveTerminals(): string[] {
    return Array.from(this.terminals.keys());
  }
}
