// Terminal renderer for asciinema cast format using XTerm.js
// Professional-grade terminal emulation with full VT compatibility

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
  type: 'o' | 'i' | 'r'; // output, input, or resize
  data: string;
}

export class Renderer {
  private container: HTMLElement;
  private terminal: Terminal;
  private fitAddon: FitAddon;
  private webLinksAddon: WebLinksAddon;
  private isPreview: boolean;

  constructor(container: HTMLElement, width: number = 80, height: number = 20, scrollback: number = 1000000, fontSize: number = 14, isPreview: boolean = false) {
    this.container = container;
    this.isPreview = isPreview;

    // Create terminal with options similar to the custom renderer
    this.terminal = new Terminal({
      cols: width,
      rows: height,
      fontFamily: 'Monaco, "Lucida Console", monospace',
      fontSize: fontSize,
      lineHeight: 1.2,
      theme: {
        background: '#1e1e1e',
        foreground: '#d4d4d4',
        cursor: '#ffffff',
        cursorAccent: '#1e1e1e',
        selectionBackground: '#264f78',
        // VS Code Dark theme colors
        black: '#000000',
        red: '#f14c4c',
        green: '#23d18b',
        yellow: '#f5f543',
        blue: '#3b8eea',
        magenta: '#d670d6',
        cyan: '#29b8db',
        white: '#e5e5e5',
        // Bright colors
        brightBlack: '#666666',
        brightRed: '#f14c4c',
        brightGreen: '#23d18b',
        brightYellow: '#f5f543',
        brightBlue: '#3b8eea',
        brightMagenta: '#d670d6',
        brightCyan: '#29b8db',
        brightWhite: '#ffffff'
      },
      allowProposedApi: true,
      scrollback: scrollback, // Configurable scrollback buffer
      convertEol: true,
      altClickMovesCursor: false,
      rightClickSelectsWord: false,
      disableStdin: true, // We handle input separately
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
    this.container.style.backgroundColor = '#1e1e1e';
    this.container.style.overflow = 'hidden';

    // Create terminal wrapper
    const terminalWrapper = document.createElement('div');
    terminalWrapper.style.width = '100%';
    terminalWrapper.style.height = '100%';
    this.container.appendChild(terminalWrapper);

    // Open terminal in the wrapper
    this.terminal.open(terminalWrapper);

    // Just use FitAddon
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
          } else if (event.type === 'r') {
            this.processResize(event.data);
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

  processResize(data: string): void {
    // Parse resize data in format "WIDTHxHEIGHT" (e.g., "80x24")
    const match = data.match(/^(\d+)x(\d+)$/);
    if (match) {
      const width = parseInt(match[1], 10);
      const height = parseInt(match[2], 10);
      this.resize(width, height);
    }
  }

  processEvent(event: CastEvent): void {
    if (event.type === 'o') {
      this.processOutput(event.data);
    } else if (event.type === 'r') {
      this.processResize(event.data);
    }
  }

  resize(width: number, height: number): void {
    // Ignore session resize and just use FitAddon
    this.fitAddon.fit();
  }

  clear(): void {
    this.terminal.clear();
  }

  // Stream support - connect to SSE endpoint
  connectToStream(sessionId: string): EventSource {
    return this.connectToUrl(`/api/sessions/${sessionId}/stream`);
  }

  // Connect to any SSE URL
  connectToUrl(url: string): EventSource {
    const eventSource = new EventSource(url);

    // Don't clear terminal for live streams - just append new content

    eventSource.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);

        if (data.version && data.width && data.height) {
          // Header
          console.log('Received header:', data);
          this.resize(data.width, data.height);
        } else if (Array.isArray(data) && data.length >= 3) {
          // Event
          const castEvent: CastEvent = {
            timestamp: data[0],
            type: data[1],
            data: data[2]
          };
          console.log('Received event:', castEvent.type, 'data length:', castEvent.data.length);
          // Log first 100 chars of data to see escape sequences
          if (castEvent.data.length > 0) {
            console.log('Event data preview:', JSON.stringify(castEvent.data.substring(0, 100)));
          }
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

  private eventSource: EventSource | null = null;

  // Load content from URL - pass isStream to determine how to handle it
  async loadFromUrl(url: string, isStream: boolean): Promise<void> {
    // Clean up existing connection
    if (this.eventSource) {
      this.eventSource.close();
      this.eventSource = null;
    }

    if (isStream) {
      // It's a stream URL, connect via SSE (don't clear - append to existing content)
      this.eventSource = this.connectToUrl(url);
    } else {
      // It's a snapshot URL, clear first then load as cast file
      this.terminal.clear();
      await this.loadCastFile(url);
    }
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
    if (this.eventSource) {
      this.eventSource.close();
      this.eventSource = null;
    }
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

  // Disable all pointer events for previews so clicks pass through to parent
  setPointerEventsEnabled(enabled: boolean): void {
    const terminalElement = this.container.querySelector('.xterm') as HTMLElement;
    if (terminalElement) {
      terminalElement.style.pointerEvents = enabled ? 'auto' : 'none';
    }
  }
}