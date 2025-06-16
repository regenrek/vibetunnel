/**
 * Custom FitAddon that scales font size to fit terminal columns to container width,
 * then calculates optimal rows for the container height.
 */

import type { Terminal, ITerminalAddon } from '@xterm/xterm';

interface ITerminalDimensions {
  rows: number;
  cols: number;
}

const MINIMUM_ROWS = 1;
const MIN_FONT_SIZE = 4;
const MAX_FONT_SIZE = 16;

export class ScaleFitAddon implements ITerminalAddon {
  private _terminal: Terminal | undefined;

  constructor() {
  }

  public activate(terminal: Terminal): void {
    this._terminal = terminal;
  }

  public dispose(): void {}

  public fit(): void {
      // For full terminals, resize both font and dimensions
      const dims = this.proposeDimensions();
      if (!dims || !this._terminal || isNaN(dims.cols) || isNaN(dims.rows)) {
        return;
      }

      // Only resize rows, keep cols the same (font scaling handles width)
      if (this._terminal.rows !== dims.rows) {
        this._terminal.resize(this._terminal.cols, dims.rows);
      }

      // Force responsive sizing by overriding XTerm's fixed dimensions
      this.forceResponsiveSizing();
  }

  public proposeDimensions(): ITerminalDimensions | undefined {
    if (!this._terminal?.element?.parentElement) {
      return undefined;
    }

    // Get the renderer container (parent of parent - the one with 10px padding)
    const terminalWrapper = this._terminal.element.parentElement;
    const rendererContainer = terminalWrapper.parentElement;

    if (!rendererContainer) return undefined;

    // Get container dimensions and exact padding
    const containerStyle = window.getComputedStyle(rendererContainer);
    const containerWidth = parseInt(containerStyle.getPropertyValue('width'));
    const containerHeight = parseInt(containerStyle.getPropertyValue('height'));
    const containerPadding = {
      top: parseInt(containerStyle.getPropertyValue('padding-top')),
      bottom: parseInt(containerStyle.getPropertyValue('padding-bottom')),
      left: parseInt(containerStyle.getPropertyValue('padding-left')),
      right: parseInt(containerStyle.getPropertyValue('padding-right'))
    };

    // Calculate exact available space using known padding
    const availableWidth = containerWidth - containerPadding.left - containerPadding.right;
    const availableHeight = containerHeight - containerPadding.top - containerPadding.bottom;

    // Current terminal dimensions
    const currentCols = this._terminal.cols;

    // Get exact character dimensions from XTerm's measurement system first
    const charDimensions = this.getXTermCharacterDimensions();

    if (charDimensions) {
      // Use actual measured dimensions for linear scaling calculation
      const { charWidth, lineHeight } = charDimensions;
      const currentFontSize = this._terminal.options.fontSize || 14;

      // Calculate current total rendered width for all columns
      const currentRenderedWidth = currentCols * charWidth;

      // Calculate scale factor needed to fit exactly in available width
      const scaleFactor = availableWidth / currentRenderedWidth;

      // Apply linear scaling to font size
      const newFontSize = currentFontSize * scaleFactor;
      const clampedFontSize = Math.min(MAX_FONT_SIZE, Math.max(MIN_FONT_SIZE, newFontSize));

      // Calculate actual font scaling that was applied (accounting for clamping)
      const actualFontScaling = clampedFontSize / currentFontSize;

      // Apply the actual font scaling to line height
      const newLineHeight = lineHeight * actualFontScaling;

      // Calculate how many rows fit with the scaled line height
      const optimalRows = Math.max(MINIMUM_ROWS, Math.floor(availableHeight / newLineHeight));

      // Apply the new font size
      requestAnimationFrame(() => this.applyFontSize(clampedFontSize));

      // Log all calculations for debugging
      console.log(`ScaleFitAddon: ${availableWidth}×${availableHeight}px available, ${currentCols}×${this._terminal.rows} terminal, charWidth=${charWidth.toFixed(2)}px, lineHeight=${lineHeight.toFixed(2)}px, currentRenderedWidth=${currentRenderedWidth.toFixed(2)}px, scaleFactor=${scaleFactor.toFixed(3)}, actualFontScaling=${actualFontScaling.toFixed(3)}, fontSize ${currentFontSize}px→${clampedFontSize.toFixed(2)}px, lineHeight ${lineHeight.toFixed(2)}px→${newLineHeight.toFixed(2)}px, rows ${this._terminal.rows}→${optimalRows}`);

      return {
        cols: currentCols, // ALWAYS keep exact column count
        rows: optimalRows  // Maximize rows that fit
      };
    } else {
      // Fallback: estimate font size and dimensions if measurements aren't available
      const charWidthRatio = 0.63;
      const calculatedFontSize = Math.floor((availableWidth / (currentCols * charWidthRatio)) * 10) / 10;
      const optimalFontSize = Math.min(MAX_FONT_SIZE, Math.max(MIN_FONT_SIZE, calculatedFontSize));

      // Apply the calculated font size
      requestAnimationFrame(() => this.applyFontSize(optimalFontSize));

      const lineHeight = optimalFontSize * (this._terminal.options.lineHeight || 1.2);
      const optimalRows = Math.max(MINIMUM_ROWS, Math.floor(availableHeight / lineHeight));

      return {
        cols: currentCols,
        rows: optimalRows
      };
    }
  }

  private applyFontSize(fontSize: number): void {
    if (!this._terminal?.element) return;

    // Prevent infinite recursion by checking if font size changed significantly
    const currentFontSize = this._terminal.options.fontSize || 14;
    if (Math.abs(fontSize - currentFontSize) < 0.1) return;

    const terminalElement = this._terminal.element;

    // Update terminal's font size
    this._terminal.options.fontSize = fontSize;

    // Apply CSS font size to the element
    terminalElement.style.fontSize = `${fontSize}px`;

    // Force a refresh to apply the new font size and ensure responsive sizing
    requestAnimationFrame(() => {
      if (this._terminal) {
        this._terminal.refresh(0, this._terminal.rows - 1);
        // Force responsive sizing after refresh since XTerm might reset dimensions
        this.forceResponsiveSizing();
      }
    });
  }

  /**
   * Get the calculated font size that would fit the current columns in the container
   */
  private scaleFontOnly(): void {
    if (!this._terminal?.element?.parentElement) return;

    // Get container dimensions for font scaling
    const terminalWrapper = this._terminal.element.parentElement;
    const rendererContainer = terminalWrapper.parentElement;
    if (!rendererContainer) return;

    const containerStyle = window.getComputedStyle(rendererContainer);
    const containerWidth = parseInt(containerStyle.getPropertyValue('width'));
    const containerPadding = {
      left: parseInt(containerStyle.getPropertyValue('padding-left')),
      right: parseInt(containerStyle.getPropertyValue('padding-right'))
    };

    const availableWidth = containerWidth - containerPadding.left - containerPadding.right;
    const currentCols = this._terminal.cols;

    // Calculate font size to fit columns in available width
    const charWidthRatio = 0.63;
    // Calculate font size and round down for precision
    const calculatedFontSize = Math.floor((availableWidth / (currentCols * charWidthRatio)) * 10) / 10;
    const optimalFontSize = Math.min(MAX_FONT_SIZE, Math.max(MIN_FONT_SIZE, calculatedFontSize));

    // Apply the font size without changing terminal dimensions
    this.applyFontSize(optimalFontSize);

    // Also force responsive sizing for previews
    this.forceResponsiveSizing();
  }

  public getOptimalFontSize(): number {
    if (!this._terminal?.element?.parentElement) {
      return this._terminal?.options.fontSize || 14;
    }

    const parentElement = this._terminal.element.parentElement;
    const parentStyle = window.getComputedStyle(parentElement);
    const parentWidth = parseInt(parentStyle.getPropertyValue('width'));

    const elementStyle = window.getComputedStyle(this._terminal.element);
    const paddingHor = parseInt(elementStyle.getPropertyValue('padding-left')) +
                      parseInt(elementStyle.getPropertyValue('padding-right'));

    const availableWidth = parentWidth - paddingHor;
    const charWidthRatio = 0.63;
    const calculatedFontSize = availableWidth / (this._terminal.cols * charWidthRatio);

    return Math.min(MAX_FONT_SIZE, Math.max(MIN_FONT_SIZE, calculatedFontSize));
  }

  /**
   * Get exact character dimensions from XTerm's built-in measurement system
   */
  private getXTermCharacterDimensions(): { charWidth: number; lineHeight: number } | null {
    if (!this._terminal?.element) return null;

    // XTerm has a built-in character measurement system with multiple font styles
    const measureContainer = this._terminal.element.querySelector('.xterm-width-cache-measure-container');

    // Find the first measurement element (normal weight, usually 'm' characters)
    // This is what XTerm uses for baseline character width calculations
    const firstMeasureElement = measureContainer?.querySelector('.xterm-char-measure-element');

    if (firstMeasureElement) {
      const measureRect = firstMeasureElement.getBoundingClientRect();
      const measureText = firstMeasureElement.textContent || '';

      if (measureText.length > 0 && measureRect.width > 0) {
        // Calculate actual character width from the primary measurement element
        const actualCharWidth = measureRect.width / measureText.length;

        // Get line height from the first row in .xterm-rows
        const xtermRows = this._terminal.element.querySelector('.xterm-rows');
        const firstRow = xtermRows?.querySelector('div');
        let lineHeight = 21.5; // fallback

        if (firstRow) {
          const rowStyle = window.getComputedStyle(firstRow);
          const rowLineHeight = parseFloat(rowStyle.lineHeight);
          if (!isNaN(rowLineHeight) && rowLineHeight > 0) {
            lineHeight = rowLineHeight;
          }
        }

        return {
          charWidth: actualCharWidth,
          lineHeight: lineHeight
        };
      }
    }

    // Fallback: try to measure from the xterm-screen dimensions and terminal cols/rows
    const xtermScreen = this._terminal.element.querySelector('.xterm-screen') as HTMLElement;
    if (xtermScreen) {
      const screenRect = xtermScreen.getBoundingClientRect();
      const charWidth = screenRect.width / this._terminal.cols;
      const lineHeight = screenRect.height / this._terminal.rows;

      if (charWidth > 0 && lineHeight > 0) {
        return { charWidth, lineHeight };
      }
    }

    return null;
  }

  /**
   * Force XTerm elements to use responsive sizing instead of fixed dimensions
   */
  private forceResponsiveSizing(): void {
    if (!this._terminal?.element) return;

    // Find the xterm-screen element within the terminal
    const xtermScreen = this._terminal.element.querySelector('.xterm-screen') as HTMLElement;
    const xtermViewport = this._terminal.element.querySelector('.xterm-viewport') as HTMLElement;

    if (xtermScreen) {
      // Remove any fixed width/height styles and force responsive sizing
      xtermScreen.style.width = '100%';
      xtermScreen.style.height = '100%';
      xtermScreen.style.maxWidth = '100%';
      xtermScreen.style.maxHeight = '100%';
    }

    if (xtermViewport) {
      xtermViewport.style.width = '100%';
      xtermViewport.style.maxWidth = '100%';
    }
  }
}