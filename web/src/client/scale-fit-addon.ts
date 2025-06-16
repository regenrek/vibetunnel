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

export class ScaleFitAddon implements ITerminalAddon {
  private _terminal: Terminal | undefined;

  public activate(terminal: Terminal): void {
    this._terminal = terminal;
  }

  public dispose(): void {}

  public fit(): void {
    const dims = this.proposeDimensions();
    if (!dims || !this._terminal || isNaN(dims.cols) || isNaN(dims.rows)) {
      return;
    }

    // Only resize rows, keep cols the same (font scaling handles width)
    if (this._terminal.rows !== dims.rows) {
      this._terminal.resize(this._terminal.cols, dims.rows);
    }
  }

  public proposeDimensions(): ITerminalDimensions | undefined {
    if (!this._terminal?.element?.parentElement) {
      return undefined;
    }

    // Get container dimensions
    const parentElement = this._terminal.element.parentElement;
    const parentStyle = window.getComputedStyle(parentElement);
    const parentWidth = parseInt(parentStyle.getPropertyValue('width'));
    const parentHeight = parseInt(parentStyle.getPropertyValue('height'));

    // Get terminal element padding
    const elementStyle = window.getComputedStyle(this._terminal.element);
    const padding = {
      top: parseInt(elementStyle.getPropertyValue('padding-top')),
      bottom: parseInt(elementStyle.getPropertyValue('padding-bottom')),
      left: parseInt(elementStyle.getPropertyValue('padding-left')),
      right: parseInt(elementStyle.getPropertyValue('padding-right'))
    };

    // Calculate available space
    const availableWidth = parentWidth - padding.left - padding.right - 20; // Extra margin
    const availableHeight = parentHeight - padding.top - padding.bottom - 20;

    // Current terminal dimensions
    const currentCols = this._terminal.cols;
    
    // Calculate optimal font size to fit current cols in available width
    // Character width is approximately 0.6 * fontSize for monospace fonts
    const charWidthRatio = 0.6;
    const optimalFontSize = Math.max(6, availableWidth / (currentCols * charWidthRatio));
    
    // Apply the calculated font size (outside of proposeDimensions to avoid recursion)
    setTimeout(() => this.applyFontSize(optimalFontSize), 0);
    
    // Calculate line height (typically 1.2 * fontSize)
    const lineHeight = optimalFontSize * 1.2;
    
    // Calculate how many rows fit with this font size
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
    const charWidthRatio = 0.6;
    
    return availableWidth / (this._terminal.cols * charWidthRatio);
  }
}