// XTerm-based terminal renderer for asciinema cast format
// Provides the same interface as the custom renderer but uses xterm.js

import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { WebLinksAddon } from '@xterm/addon-web-links';

interface CastHeader {
  version: number;
  width: number;
  height: number;
  timestamp?: number;
  env?: Record<string, string>;
}

interface CastEvent {
  timestamp: number;
  type: 'o' | 'i'; // output or input
  data: string;
}

export class XTermRenderer {
  private container: HTMLElement;
  private terminal: Terminal;
  private fitAddon: FitAddon;
  private webLinksAddon: WebLinksAddon;

  constructor(container: HTMLElement, width: number = 80, height: number = 20) {
    this.container = container;
    
    // Create terminal with options similar to the custom renderer
    this.terminal = new Terminal({
      cols: width,
      rows: height,
      fontFamily: 'Monaco, "Lucida Console", monospace',
      fontSize: 14,
      lineHeight: 1.2,
      theme: {
        background: '#000000',
        foreground: '#ffffff',
        cursor: '#ffffff',
        cursorAccent: '#000000',
        selectionBackground: '#ffffff30',
        // Standard ANSI colors (matching the custom renderer)
        black: '#000000',
        red: '#cc241d',
        green: '#98971a',
        yellow: '#d79921',
        blue: '#458588',
        magenta: '#b16286',
        cyan: '#689d6a',
        white: '#a89984',
        // Bright ANSI colors
        brightBlack: '#928374',
        brightRed: '#fb4934',
        brightGreen: '#b8bb26',
        brightYellow: '#fabd2f',
        brightBlue: '#83a598',
        brightMagenta: '#d3869b',
        brightCyan: '#8ec07c',
        brightWhite: '#ebdbb2'
      },
      allowProposedApi: true,
      scrollback: 1000,
      convertEol: true,
      altClickMovesCursor: false,
      rightClickSelectsWord: false,
      disableStdin: true // We handle input separately
    });

    // Add addons
    this.fitAddon = new FitAddon();
    this.webLinksAddon = new WebLinksAddon();
    
    this.terminal.loadAddon(this.fitAddon);
    this.terminal.loadAddon(this.webLinksAddon);

    this.setupDOM();
  }

  private setupDOM(): void {
    // Clear container and add CSS
    this.container.innerHTML = '';
    this.container.style.padding = '10px';
    this.container.style.backgroundColor = '#000000';
    this.container.style.overflow = 'hidden';
    
    // Create terminal wrapper
    const terminalWrapper = document.createElement('div');
    terminalWrapper.style.width = '100%';
    terminalWrapper.style.height = '100%';
    this.container.appendChild(terminalWrapper);

    // Open terminal in the wrapper
    this.terminal.open(terminalWrapper);
    
    // Fit terminal to container
    this.fitAddon.fit();
    
    // Handle container resize
    const resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit();
    });
    resizeObserver.observe(this.container);
  }

  // Public API methods - maintain compatibility with custom renderer

  async loadCastFile(url: string): Promise<void> {
    const response = await fetch(url);
    const text = await response.text();
    this.parseCastFile(text);
  }

  parseCastFile(content: string): void {
    const lines = content.trim().split('\n');
    let header: CastHeader | null = null;
    
    // Clear terminal
    this.terminal.clear();
    
    for (const line of lines) {
      if (!line.trim()) continue;
      
      try {
        const parsed = JSON.parse(line);
        
        if (parsed.version && parsed.width && parsed.height) {
          // Header
          header = parsed;
          this.resize(parsed.width, parsed.height);
        } else if (Array.isArray(parsed) && parsed.length >= 3) {
          // Event: [timestamp, type, data]
          const event: CastEvent = {
            timestamp: parsed[0],
            type: parsed[1],
            data: parsed[2]
          };
          
          if (event.type === 'o') {
            this.processOutput(event.data);
          }
        }
      } catch (e) {
        console.warn('Failed to parse cast line:', line);
      }
    }
  }

  processOutput(data: string): void {
    // XTerm handles all ANSI escape sequences automatically
    this.terminal.write(data);
  }

  processEvent(event: CastEvent): void {
    if (event.type === 'o') {
      this.processOutput(event.data);
    }
  }

  resize(width: number, height: number): void {
    this.terminal.resize(width, height);
    // Fit addon will handle the visual resize
    setTimeout(() => {
      this.fitAddon.fit();
    }, 0);
  }

  clear(): void {
    this.terminal.clear();
  }

  // Stream support - connect to SSE endpoint
  connectToStream(sessionId: string): EventSource {
    const eventSource = new EventSource(`/api/sessions/${sessionId}/stream`);
    
    // Clear terminal when starting stream
    this.terminal.clear();
    
    eventSource.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);
        
        if (data.version && data.width && data.height) {
          // Header
          this.resize(data.width, data.height);
        } else if (Array.isArray(data) && data.length >= 3) {
          // Event
          const castEvent: CastEvent = {
            timestamp: data[0],
            type: data[1],
            data: data[2]
          };
          this.processEvent(castEvent);
        }
      } catch (e) {
        console.warn('Failed to parse stream event:', event.data);
      }
    };
    
    eventSource.onerror = (error) => {
      console.error('Stream error:', error);
    };
    
    return eventSource;
  }

  // Additional methods for terminal control
  
  focus(): void {
    this.terminal.focus();
  }

  blur(): void {
    this.terminal.blur();
  }

  getTerminal(): Terminal {
    return this.terminal;
  }

  dispose(): void {
    this.terminal.dispose();
  }

  // Method to fit terminal to container (useful for responsive layouts)
  fit(): void {
    this.fitAddon.fit();
  }

  // Get terminal dimensions
  getDimensions(): { cols: number; rows: number } {
    return {
      cols: this.terminal.cols,
      rows: this.terminal.rows
    };
  }

  // Write raw data to terminal (useful for testing)
  write(data: string): void {
    this.terminal.write(data);
  }

  // Enable/disable input (though we keep it disabled by default)
  setInputEnabled(enabled: boolean): void {
    // XTerm doesn't have a direct way to disable input, so we override onData
    if (enabled) {
      // Remove any existing handler first
      this.terminal.onData(() => {
        // Input is handled by the session component
      });
    } else {
      this.terminal.onData(() => {
        // Do nothing - input disabled
      });
    }
  }
}