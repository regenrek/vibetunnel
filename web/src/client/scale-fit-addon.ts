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
  private _isPreview: boolean;

  constructor(isPreview: boolean = false) {
    this._isPreview = isPreview;
  }

  public activate(terminal: Terminal): void {
    this._terminal = terminal;
  }

  public dispose(): void {}

  public fit(): void {
    if (this._isPreview) {
      // For previews, only scale font size, don't change terminal dimensions
      this.scaleFontOnly();
    } else {
      // For full terminals, resize both font and dimensions
      const dims = this.proposeDimensions();
      if (!dims || !this._terminal || isNaN(dims.cols) || isNaN(dims.rows)) {
        return;
      }

      // Only resize rows, keep cols the same (font scaling handles width)
      if (this._terminal.rows !== dims.rows) {
        this._terminal.resize(this._terminal.cols, dims.rows);
      }
    }
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

    // Calculate optimal font size to fit current cols in available width
    // Character width is approximately 0.6 * fontSize for monospace fonts
    // For 80 cols exactly, we need to be more conservative to prevent wrapping
    const charWidthRatio = 0.63;
    // Calculate font size and round down for precision
    const calculatedFontSize = Math.floor((availableWidth / (currentCols * charWidthRatio)) * 10) / 10;
    const optimalFontSize = Math.min(MAX_FONT_SIZE, Math.max(MIN_FONT_SIZE, calculatedFontSize));

    // Apply the calculated font size (outside of proposeDimensions to avoid recursion)
    requestAnimationFrame(() => this.applyFontSize(optimalFontSize));

    // Get the actual line height from the rendered XTerm element
    const xtermElement = this._terminal.element;
    const currentStyle = window.getComputedStyle(xtermElement);
    const actualLineHeight = parseFloat(currentStyle.lineHeight);

    // XTerm typically uses a line height of around 1.0 for the character cell height
    // Use a more accurate fallback based on XTerm's actual behavior
    const lineHeight = (actualLineHeight && !isNaN(actualLineHeight)) ? 
      actualLineHeight : 
      (optimalFontSize * (this._terminal.options.lineHeight || 1.0));

    // Calculate how many rows fit with this line height
    const optimalRows = Math.max(MINIMUM_ROWS, Math.floor(availableHeight / lineHeight));

    return {
      cols: currentCols, // Keep existing cols
      rows: optimalRows  // Fit as many rows as possible
    };
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

    // Force a refresh to apply the new font size
    requestAnimationFrame(() => {
      if (this._terminal) {
        this._terminal.refresh(0, this._terminal.rows - 1);
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
}