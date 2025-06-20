import { IBufferCell } from '@xterm/headless';

export interface BufferCell {
  char: string;
  width: number;
  fg?: number;
  bg?: number;
  attributes?: number;
}

// Attribute bit flags
const ATTR_BOLD = 0x01;
const ATTR_ITALIC = 0x02;
const ATTR_UNDERLINE = 0x04;
const ATTR_DIM = 0x08;
const ATTR_INVERSE = 0x10;
const ATTR_INVISIBLE = 0x20;
const ATTR_STRIKETHROUGH = 0x40;

export class TerminalRenderer {
  private static escapeHtml(text: string): string {
    return text
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  /**
   * Render a line from IBufferCell array (from xterm.js)
   */
  static renderLineFromBuffer(
    line: { getCell: (col: number, cell: IBufferCell) => void; length: number },
    cell: IBufferCell,
    cursorCol: number = -1
  ): string {
    let html = '';
    let currentChars = '';
    let currentClasses = '';
    let currentStyle = '';

    const flushGroup = () => {
      if (currentChars) {
        const escapedChars = this.escapeHtml(currentChars);
        html += `<span class="${currentClasses}"${currentStyle ? ` style="${currentStyle}"` : ''}>${escapedChars}</span>`;
        currentChars = '';
      }
    };

    // Process each cell in the line
    for (let col = 0; col < line.length; col++) {
      line.getCell(col, cell);
      if (!cell) continue;

      const char = cell.getChars() || ' ';
      const width = cell.getWidth();

      // Skip zero-width cells (part of wide characters)
      if (width === 0) continue;

      // Get styling
      const { classes, style } = this.getCellStyling(cell, col === cursorCol);

      // Check if styling changed
      if (classes !== currentClasses || style !== currentStyle) {
        flushGroup();
        currentClasses = classes;
        currentStyle = style;
      }

      currentChars += char;
    }

    // Flush remaining chars
    flushGroup();

    return html;
  }

  /**
   * Render a line from BufferCell array (from JSON/binary buffer)
   */
  static renderLineFromCells(cells: BufferCell[], cursorCol: number = -1): string {
    let html = '';
    let currentChars = '';
    let currentClasses = '';
    let currentStyle = '';

    const flushGroup = () => {
      if (currentChars) {
        const escapedChars = this.escapeHtml(currentChars);
        html += `<span class="${currentClasses}"${currentStyle ? ` style="${currentStyle}"` : ''}>${escapedChars}</span>`;
        currentChars = '';
      }
    };

    // Process each cell
    let col = 0;
    for (const cell of cells) {
      // Skip zero-width cells
      if (cell.width === 0) continue;

      // Get styling
      const { classes, style } = this.getCellStylingFromBuffer(cell, col === cursorCol);

      // Check if styling changed
      if (classes !== currentClasses || style !== currentStyle) {
        flushGroup();
        currentClasses = classes;
        currentStyle = style;
      }

      currentChars += cell.char;
      col += cell.width;
    }

    // Flush remaining chars
    flushGroup();

    // If the line is empty or has no visible content, add a non-breaking space
    // to ensure the line maintains its height
    if (!html) {
      html = '<span class="terminal-char">&nbsp;</span>';
    }

    return html;
  }

  private static getCellStyling(
    cell: IBufferCell,
    isCursor: boolean
  ): { classes: string; style: string } {
    let classes = 'terminal-char';
    let style = '';

    if (isCursor) {
      classes += ' cursor';
    }

    // Get foreground color
    const fg = cell.getFgColor();
    if (fg !== undefined) {
      if (typeof fg === 'number' && fg >= 0 && fg <= 255) {
        style += `color: var(--terminal-color-${fg});`;
      } else if (typeof fg === 'number' && fg > 255) {
        const r = (fg >> 16) & 0xff;
        const g = (fg >> 8) & 0xff;
        const b = fg & 0xff;
        style += `color: rgb(${r}, ${g}, ${b});`;
      }
    }

    // Get background color
    const bg = cell.getBgColor();
    if (bg !== undefined) {
      if (typeof bg === 'number' && bg >= 0 && bg <= 255) {
        style += `background-color: var(--terminal-color-${bg});`;
      } else if (typeof bg === 'number' && bg > 255) {
        const r = (bg >> 16) & 0xff;
        const g = (bg >> 8) & 0xff;
        const b = bg & 0xff;
        style += `background-color: rgb(${r}, ${g}, ${b});`;
      }
    }

    // Override background for cursor
    if (isCursor) {
      style += `background-color: #23d18b;`;
    }

    // Get text attributes
    if (cell.isBold()) classes += ' bold';
    if (cell.isItalic()) classes += ' italic';
    if (cell.isUnderline()) classes += ' underline';
    if (cell.isDim()) classes += ' dim';
    if (cell.isStrikethrough()) classes += ' strikethrough';

    // Handle inverse colors
    if (cell.isInverse()) {
      const tempFg = style.match(/color: ([^;]+);/)?.[1];
      const tempBg = style.match(/background-color: ([^;]+);/)?.[1];
      if (tempFg && tempBg) {
        style = style.replace(/color: [^;]+;/, `color: ${tempBg};`);
        style = style.replace(/background-color: [^;]+;/, `background-color: ${tempFg};`);
      } else if (tempFg) {
        style = style.replace(/color: [^;]+;/, 'color: #1e1e1e;');
        style += `background-color: ${tempFg};`;
      } else {
        style += 'color: #1e1e1e; background-color: #d4d4d4;';
      }
    }

    // Handle invisible text
    if (cell.isInvisible()) {
      style += 'opacity: 0;';
    }

    return { classes, style };
  }

  private static getCellStylingFromBuffer(
    cell: BufferCell,
    isCursor: boolean
  ): { classes: string; style: string } {
    let classes = 'terminal-char';
    let style = '';

    if (isCursor) {
      classes += ' cursor';
    }

    // Get foreground color
    if (cell.fg !== undefined) {
      if (cell.fg >= 0 && cell.fg <= 255) {
        style += `color: var(--terminal-color-${cell.fg});`;
      } else {
        const r = (cell.fg >> 16) & 0xff;
        const g = (cell.fg >> 8) & 0xff;
        const b = cell.fg & 0xff;
        style += `color: rgb(${r}, ${g}, ${b});`;
      }
    } else {
      // Default foreground color if not specified
      style += `color: #d4d4d4;`;
    }

    // Get background color
    if (cell.bg !== undefined) {
      if (cell.bg >= 0 && cell.bg <= 255) {
        style += `background-color: var(--terminal-color-${cell.bg});`;
      } else {
        const r = (cell.bg >> 16) & 0xff;
        const g = (cell.bg >> 8) & 0xff;
        const b = cell.bg & 0xff;
        style += `background-color: rgb(${r}, ${g}, ${b});`;
      }
    }

    // Override background for cursor
    if (isCursor) {
      style += `background-color: #23d18b;`;
    }

    // Get text attributes from bit flags
    const attrs = cell.attributes || 0;
    if (attrs & ATTR_BOLD) classes += ' bold';
    if (attrs & ATTR_ITALIC) classes += ' italic';
    if (attrs & ATTR_UNDERLINE) classes += ' underline';
    if (attrs & ATTR_DIM) classes += ' dim';
    if (attrs & ATTR_STRIKETHROUGH) classes += ' strikethrough';

    // Handle inverse colors
    if (attrs & ATTR_INVERSE) {
      const tempFg = style.match(/color: ([^;]+);/)?.[1];
      const tempBg = style.match(/background-color: ([^;]+);/)?.[1];
      if (tempFg && tempBg) {
        style = style.replace(/color: [^;]+;/, `color: ${tempBg};`);
        style = style.replace(/background-color: [^;]+;/, `background-color: ${tempFg};`);
      } else if (tempFg) {
        style = style.replace(/color: [^;]+;/, 'color: #1e1e1e;');
        style += `background-color: ${tempFg};`;
      } else {
        style += 'color: #1e1e1e; background-color: #d4d4d4;';
      }
    }

    // Handle invisible text
    if (attrs & ATTR_INVISIBLE) {
      style += 'opacity: 0;';
    }

    return { classes, style };
  }

  /**
   * Decode binary buffer format
   */
  static decodeBinaryBuffer(buffer: ArrayBuffer): {
    cols: number;
    rows: number;
    viewportY: number;
    cursorX: number;
    cursorY: number;
    cells: BufferCell[][];
  } {
    const view = new DataView(buffer);
    let offset = 0;

    // Read header
    const magic = view.getUint16(offset, true);
    offset += 2;
    if (magic !== 0x5654) {
      throw new Error('Invalid buffer format');
    }

    const version = view.getUint8(offset++);
    if (version !== 0x02) {
      throw new Error(`Unsupported buffer version: ${version}`);
    }

    const _flags = view.getUint8(offset++);
    const cols = view.getUint32(offset, true);
    offset += 4;
    const rows = view.getUint32(offset, true);
    offset += 4;
    const viewportY = view.getInt32(offset, true); // Signed
    offset += 4;
    const cursorX = view.getInt32(offset, true); // Signed
    offset += 4;
    const cursorY = view.getInt32(offset, true); // Signed
    offset += 4;
    offset += 4; // Skip reserved

    // Decode cells
    const cells: BufferCell[][] = [];
    const uint8 = new Uint8Array(buffer);

    for (let row = 0; row < rows; row++) {
      const rowCells: BufferCell[] = [];

      for (let col = 0; col < cols; ) {
        if (offset >= uint8.length) break;

        // Check for special markers
        const firstByte = uint8[offset];

        if (firstByte === 0xff) {
          // Run-length encoding
          offset++;
          const count = uint8[offset++];
          const cell = this.decodeCell(uint8, offset);
          offset = cell.offset;

          for (let i = 0; i < count; i++) {
            rowCells.push(cell.cell);
            col++;
          }
        } else if (firstByte === 0xfe) {
          // Empty line marker
          offset++;
          const count = uint8[offset++];
          for (let i = 0; i < count && row < rows; i++) {
            const emptyRow: BufferCell[] = [];
            for (let j = 0; j < cols; j++) {
              emptyRow.push({ char: ' ', width: 1 });
            }
            cells.push(emptyRow);
            row++;
          }
          row--; // Adjust for outer loop increment
          break;
        } else {
          // Regular cell
          const result = this.decodeCell(uint8, offset);
          offset = result.offset;
          rowCells.push(result.cell);
          col++;
        }
      }

      if (rowCells.length > 0) {
        cells.push(rowCells);
      }
    }

    return { cols, rows, viewportY, cursorX, cursorY, cells };
  }

  private static decodeCell(
    uint8: Uint8Array,
    offset: number
  ): { cell: BufferCell; offset: number } {
    const firstByte = uint8[offset];

    if (firstByte & 0x80) {
      // Extended cell
      const header = uint8[offset++];
      const attributes = uint8[offset++] & 0x7f; // Remove extended bit
      const charLen = ((header >> 6) & 0x03) + 1;
      const hasRgbFg = !!(header & 0x20);
      const hasRgbBg = !!(header & 0x10);

      // Read character
      const charBytes = uint8.slice(offset, offset + charLen);
      const char = new TextDecoder().decode(charBytes);
      offset += charLen;

      // Read colors
      let fg: number | undefined;
      let bg: number | undefined;

      if (hasRgbFg) {
        fg = (uint8[offset] << 16) | (uint8[offset + 1] << 8) | uint8[offset + 2];
        offset += 3;
      } else {
        fg = uint8[offset++];
      }

      if (hasRgbBg) {
        bg = (uint8[offset] << 16) | (uint8[offset + 1] << 8) | uint8[offset + 2];
        offset += 3;
      } else {
        bg = uint8[offset++];
      }

      return {
        cell: { char, width: 1, fg, bg, attributes },
        offset,
      };
    } else {
      // Basic cell
      const char = String.fromCharCode(uint8[offset++]);
      const attributes = uint8[offset++];
      const fg = uint8[offset++];
      const bg = uint8[offset++];

      return {
        cell: {
          char,
          width: 1,
          fg: fg === 7 ? undefined : fg,
          bg: bg === 0 ? undefined : bg,
          attributes: attributes === 0 ? undefined : attributes,
        },
        offset,
      };
    }
  }
}
