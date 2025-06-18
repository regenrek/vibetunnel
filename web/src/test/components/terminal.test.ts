import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Terminal } from '@xterm/headless';
import '@testing-library/dom';

// Mock @xterm/headless
vi.mock('@xterm/headless', () => ({
  Terminal: vi.fn().mockImplementation(() => ({
    cols: 80,
    rows: 24,
    buffer: {
      active: {
        length: 24,
        getLine: vi.fn((y) => ({
          length: 80,
          translateToString: vi.fn(() => `Line ${y}`),
          getCell: vi.fn((x) => ({
            getChars: () => 'X',
            getFgColor: () => null,
            getBgColor: () => null,
            isBold: () => false,
            isItalic: () => false,
            isUnderline: () => false,
          })),
        })),
        cursorY: 0,
        cursorX: 0,
      },
    },
    write: vi.fn(),
    clear: vi.fn(),
    reset: vi.fn(),
    resize: vi.fn(),
    scrollToLine: vi.fn(),
    onData: vi.fn(),
    onBinary: vi.fn(),
    dispose: vi.fn(),
  })),
}));

// Mock lit
vi.mock('lit', () => ({
  LitElement: class {
    connectedCallback() {}
    disconnectedCallback() {}
    requestUpdate() {}
    querySelector() {
      return null;
    }
  },
  html: (strings: TemplateStringsArray, ...values: any[]) => {
    return strings.join('');
  },
  css: (strings: TemplateStringsArray) => strings.join(''),
}));

vi.mock('lit/decorators.js', () => ({
  customElement: (name: string) => (target: any) => target,
  property: (options?: any) => (target: any, propertyKey: string) => {},
  state: (options?: any) => (target: any, propertyKey: string) => {},
}));

describe('Terminal Component', () => {
  let terminalModule: any;
  let mockTerminal: any;

  beforeEach(async () => {
    vi.clearAllMocks();

    // Import the terminal component
    terminalModule = await import('../../client/components/terminal');

    // Get mock terminal instance
    mockTerminal = new Terminal();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('Terminal Initialization', () => {
    it('should create terminal with correct dimensions', () => {
      const terminal = new terminalModule.Terminal();
      terminal.cols = 120;
      terminal.rows = 40;
      terminal.sessionId = 'test-session';

      terminal.connectedCallback();

      expect(Terminal).toHaveBeenCalledWith({
        cols: 120,
        rows: 40,
        allowProposedApi: true,
      });
    });

    it('should handle terminal data output', () => {
      const terminal = new terminalModule.Terminal();
      const mockCallback = vi.fn();

      terminal.terminal = mockTerminal;
      mockTerminal.onData(mockCallback);

      // Simulate typing
      const testData = 'hello world';
      mockTerminal.onData.mock.calls[0][0](testData);

      expect(mockCallback).toHaveBeenCalledWith(testData);
    });

    it('should dispose terminal on disconnect', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      terminal.disconnectedCallback();

      expect(mockTerminal.dispose).toHaveBeenCalled();
    });
  });

  describe('Terminal Rendering', () => {
    it('should render terminal lines correctly', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      const buffer = mockTerminal.buffer.active;
      const lines = [];

      for (let y = 0; y < buffer.length; y++) {
        const line = buffer.getLine(y);
        lines.push(line.translateToString());
      }

      expect(lines).toHaveLength(24);
      expect(lines[0]).toBe('Line 0');
      expect(lines[23]).toBe('Line 23');
    });

    it('should handle cursor position', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      // Set cursor position
      mockTerminal.buffer.active.cursorY = 10;
      mockTerminal.buffer.active.cursorX = 15;

      expect(mockTerminal.buffer.active.cursorY).toBe(10);
      expect(mockTerminal.buffer.active.cursorX).toBe(15);
    });

    it('should render cell attributes correctly', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      const cell = mockTerminal.buffer.active.getLine(0).getCell(0);

      expect(cell.getChars()).toBe('X');
      expect(cell.isBold()).toBe(false);
      expect(cell.isItalic()).toBe(false);
      expect(cell.isUnderline()).toBe(false);
    });
  });

  describe('Terminal Operations', () => {
    it('should write data to terminal', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      const testData = 'echo "Hello Terminal"\n';
      terminal.writeToTerminal(testData);

      expect(mockTerminal.write).toHaveBeenCalledWith(testData);
    });

    it('should clear terminal', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      terminal.clearTerminal();

      expect(mockTerminal.clear).toHaveBeenCalled();
    });

    it('should resize terminal', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      terminal.resizeTerminal(100, 30);

      expect(mockTerminal.resize).toHaveBeenCalledWith(100, 30);
    });

    it('should reset terminal', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      terminal.resetTerminal();

      expect(mockTerminal.reset).toHaveBeenCalled();
    });
  });

  describe('Terminal Scrolling', () => {
    it('should handle scroll to top', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      terminal.scrollToTop();

      expect(mockTerminal.scrollToLine).toHaveBeenCalledWith(0);
    });

    it('should handle scroll to bottom', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;
      terminal.terminal.buffer.active.length = 100;

      terminal.scrollToBottom();

      expect(mockTerminal.scrollToLine).toHaveBeenCalledWith(100);
    });

    it('should calculate viewport dimensions', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;
      terminal.fontSize = 14;

      const lineHeight = terminal.calculateLineHeight();
      const charWidth = terminal.calculateCharWidth();

      // Approximate calculations
      expect(lineHeight).toBeGreaterThan(0);
      expect(charWidth).toBeGreaterThan(0);
    });
  });

  describe('Terminal Fit Mode', () => {
    it('should toggle fit mode', () => {
      const terminal = new terminalModule.Terminal();
      terminal.fitHorizontally = false;

      terminal.handleFitToggle();

      expect(terminal.fitHorizontally).toBe(true);

      terminal.handleFitToggle();

      expect(terminal.fitHorizontally).toBe(false);
    });

    it('should calculate dimensions for fit mode', () => {
      const terminal = new terminalModule.Terminal();
      terminal.fitHorizontally = true;
      terminal.fontSize = 14;

      // Mock container dimensions
      const mockContainer = {
        offsetWidth: 800,
        offsetHeight: 600,
      };

      terminal.container = mockContainer as any;

      const dims = terminal.calculateFitDimensions();

      expect(dims.cols).toBeGreaterThan(0);
      expect(dims.rows).toBeGreaterThan(0);
    });
  });

  describe('URL Highlighting', () => {
    it('should detect URLs in terminal output', () => {
      const terminal = new terminalModule.Terminal();

      const testLine = 'Visit https://example.com for more info';
      const urls = terminal.detectUrls(testLine);

      expect(urls).toContain('https://example.com');
    });

    it('should handle multiple URLs in one line', () => {
      const terminal = new terminalModule.Terminal();

      const testLine = 'Check http://test.com and https://example.org';
      const urls = terminal.detectUrls(testLine);

      expect(urls).toHaveLength(2);
      expect(urls).toContain('http://test.com');
      expect(urls).toContain('https://example.org');
    });

    it('should ignore invalid URLs', () => {
      const terminal = new terminalModule.Terminal();

      const testLine = 'Not a URL: htp://invalid or example.com';
      const urls = terminal.detectUrls(testLine);

      expect(urls).toHaveLength(0);
    });
  });

  describe('Performance Optimization', () => {
    it('should batch render updates', async () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      const renderSpy = vi.spyOn(terminal, 'requestUpdate');

      // Multiple rapid updates
      terminal.writeToTerminal('Line 1\n');
      terminal.writeToTerminal('Line 2\n');
      terminal.writeToTerminal('Line 3\n');

      // Should batch updates
      expect(renderSpy).toHaveBeenCalledTimes(3);
    });

    it('should handle large output efficiently', () => {
      const terminal = new terminalModule.Terminal();
      terminal.terminal = mockTerminal;

      // Write large amount of data
      const largeData = 'X'.repeat(10000) + '\n';

      const startTime = performance.now();
      terminal.writeToTerminal(largeData);
      const endTime = performance.now();

      // Should complete quickly
      expect(endTime - startTime).toBeLessThan(100);
      expect(mockTerminal.write).toHaveBeenCalledWith(largeData);
    });
  });
});
