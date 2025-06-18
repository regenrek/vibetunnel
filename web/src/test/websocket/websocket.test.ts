import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { WebSocket, WebSocketServer } from 'ws';
import { EventEmitter } from 'events';
import { spawn } from 'child_process';
import { waitForWebSocket } from '../test-utils';

// Mock modules
vi.mock('child_process', () => ({
  spawn: vi.fn(),
}));

vi.mock('fs', () => ({
  default: {
    existsSync: vi.fn(() => true),
    mkdirSync: vi.fn(),
    createReadStream: vi.fn(() => {
      const stream = new EventEmitter();
      setTimeout(() => {
        stream.emit('data', Buffer.from('test data\n'));
        stream.emit('end');
      }, 10);
      return stream;
    }),
  },
}));

describe('WebSocket Connection', () => {
  let mockSpawn: any;
  let mockChildProcess: any;
  let server: any;
  let wss: WebSocketServer;
  let serverUrl: string;

  beforeEach(async () => {
    vi.clearAllMocks();

    // Set up mock spawn
    mockSpawn = vi.mocked(spawn);

    // Create mock child process for stream command
    mockChildProcess = new EventEmitter();
    mockChildProcess.stdout = new EventEmitter();
    mockChildProcess.stderr = new EventEmitter();
    mockChildProcess.kill = vi.fn();

    // Mock tty-fwd execution
    const mockTtyFwdProcess = {
      stdout: {
        on: vi.fn((event, callback) => {
          if (event === 'data') {
            callback(Buffer.from('{}'));
          }
        }),
      },
      stderr: { on: vi.fn() },
      on: vi.fn((event, callback) => {
        if (event === 'close') callback(0);
      }),
      kill: vi.fn(),
    };

    mockSpawn.mockReturnValue(mockTtyFwdProcess);

    // Import and set up server
    const serverModule = await import('../../server');
    server = serverModule.server;
    wss = serverModule.wss;

    // Get dynamic port
    await new Promise<void>((resolve) => {
      server.listen(0, () => {
        const address = server.address();
        serverUrl = `ws://localhost:${address.port}`;
        resolve();
      });
    });
  });

  afterEach(async () => {
    // Close all WebSocket connections
    wss.clients.forEach((client) => {
      if (client.readyState === WebSocket.OPEN) {
        client.close();
      }
    });

    // Close server
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
    });

    vi.restoreAllMocks();
  });

  describe('WebSocket Connection Management', () => {
    it('should accept WebSocket connections', async () => {
      const ws = new WebSocket(serverUrl);

      await new Promise<void>((resolve, reject) => {
        ws.on('open', () => resolve());
        ws.on('error', reject);
      });

      expect(ws.readyState).toBe(WebSocket.OPEN);
      expect(wss.clients.size).toBe(1);

      ws.close();
    });

    it('should handle multiple WebSocket connections', async () => {
      const ws1 = new WebSocket(serverUrl);
      const ws2 = new WebSocket(serverUrl);

      await Promise.all([
        new Promise<void>((resolve) => ws1.on('open', resolve)),
        new Promise<void>((resolve) => ws2.on('open', resolve)),
      ]);

      expect(wss.clients.size).toBe(2);

      ws1.close();
      ws2.close();
    });

    it('should remove client on disconnect', async () => {
      const ws = new WebSocket(serverUrl);

      await new Promise<void>((resolve) => ws.on('open', resolve));
      expect(wss.clients.size).toBe(1);

      ws.close();
      await waitForWebSocket(50);

      expect(wss.clients.size).toBe(0);
    });
  });

  describe('Terminal Streaming', () => {
    it('should subscribe to terminal output stream', async () => {
      // Mock stream command to return process
      mockSpawn.mockImplementation((cmd, args) => {
        if (args.includes('stream')) {
          return mockChildProcess;
        }
        return {
          stdout: { on: vi.fn() },
          stderr: { on: vi.fn() },
          on: vi.fn((event, callback) => {
            if (event === 'close') callback(0);
          }),
          kill: vi.fn(),
        };
      });

      const ws = new WebSocket(serverUrl);
      const messages: any[] = [];

      ws.on('message', (data) => {
        messages.push(JSON.parse(data.toString()));
      });

      await new Promise<void>((resolve) => ws.on('open', resolve));

      // Subscribe to terminal
      ws.send(
        JSON.stringify({
          type: 'subscribe',
          sessionId: 'test-session-123',
        })
      );

      // Emit some data from the mock process
      await waitForWebSocket(50);
      mockChildProcess.stdout.emit('data', Buffer.from('Hello from terminal\n'));

      await waitForWebSocket(50);

      // Check that we received the terminal output
      const terminalMessages = messages.filter((m) => m.type === 'terminal-output');
      expect(terminalMessages.length).toBeGreaterThan(0);
      expect(terminalMessages[0]).toMatchObject({
        type: 'terminal-output',
        sessionId: 'test-session-123',
        data: expect.stringContaining('Hello from terminal'),
      });

      ws.close();
    });

    it('should handle unsubscribe from terminal', async () => {
      const ws = new WebSocket(serverUrl);

      await new Promise<void>((resolve) => ws.on('open', resolve));

      // Subscribe first
      ws.send(
        JSON.stringify({
          type: 'subscribe',
          sessionId: 'test-session-123',
        })
      );

      await waitForWebSocket(50);

      // Then unsubscribe
      ws.send(
        JSON.stringify({
          type: 'unsubscribe',
          sessionId: 'test-session-123',
        })
      );

      await waitForWebSocket(50);

      // Verify process was killed
      expect(mockChildProcess.kill).toHaveBeenCalled();

      ws.close();
    });

    it('should handle terminal resize events', async () => {
      const ws = new WebSocket(serverUrl);

      await new Promise<void>((resolve) => ws.on('open', resolve));

      // Send resize event
      ws.send(
        JSON.stringify({
          type: 'resize',
          sessionId: 'test-session-123',
          cols: 120,
          rows: 40,
        })
      );

      await waitForWebSocket(50);

      // Verify tty-fwd resize was called
      expect(mockSpawn).toHaveBeenCalledWith(
        expect.any(String),
        expect.arrayContaining(['resize', 'test-session-123', '120', '40'])
      );

      ws.close();
    });
  });

  describe('Error Handling', () => {
    it('should handle invalid message format', async () => {
      const ws = new WebSocket(serverUrl);
      const messages: any[] = [];

      ws.on('message', (data) => {
        messages.push(JSON.parse(data.toString()));
      });

      await new Promise<void>((resolve) => ws.on('open', resolve));

      // Send invalid JSON
      ws.send('invalid json{');

      await waitForWebSocket(50);

      // Should receive error message
      const errorMessages = messages.filter((m) => m.type === 'error');
      expect(errorMessages.length).toBe(1);
      expect(errorMessages[0].error).toContain('Invalid message format');

      ws.close();
    });

    it('should handle missing sessionId in subscribe', async () => {
      const ws = new WebSocket(serverUrl);
      const messages: any[] = [];

      ws.on('message', (data) => {
        messages.push(JSON.parse(data.toString()));
      });

      await new Promise<void>((resolve) => ws.on('open', resolve));

      // Send subscribe without sessionId
      ws.send(
        JSON.stringify({
          type: 'subscribe',
        })
      );

      await waitForWebSocket(50);

      // Should receive error message
      const errorMessages = messages.filter((m) => m.type === 'error');
      expect(errorMessages.length).toBe(1);
      expect(errorMessages[0].error).toContain('Session ID required');

      ws.close();
    });

    it('should handle stream process errors', async () => {
      // Mock stream command to fail
      mockSpawn.mockImplementation((cmd, args) => {
        if (args.includes('stream')) {
          const errorProcess = new EventEmitter();
          errorProcess.stdout = new EventEmitter();
          errorProcess.stderr = new EventEmitter();
          errorProcess.kill = vi.fn();

          // Emit error
          setTimeout(() => {
            errorProcess.emit('error', new Error('Stream failed'));
          }, 10);

          return errorProcess;
        }
        return mockChildProcess;
      });

      const ws = new WebSocket(serverUrl);
      const messages: any[] = [];

      ws.on('message', (data) => {
        messages.push(JSON.parse(data.toString()));
      });

      await new Promise<void>((resolve) => ws.on('open', resolve));

      // Subscribe to terminal
      ws.send(
        JSON.stringify({
          type: 'subscribe',
          sessionId: 'test-session-123',
        })
      );

      await waitForWebSocket(100);

      // Should receive error message
      const errorMessages = messages.filter((m) => m.type === 'error');
      expect(errorMessages.length).toBeGreaterThan(0);
      expect(errorMessages[0].error).toContain('Failed to start stream');

      ws.close();
    });
  });

  describe('Broadcast Functionality', () => {
    it('should broadcast session updates to all clients', async () => {
      const ws1 = new WebSocket(serverUrl);
      const ws2 = new WebSocket(serverUrl);

      const messages1: any[] = [];
      const messages2: any[] = [];

      ws1.on('message', (data) => messages1.push(JSON.parse(data.toString())));
      ws2.on('message', (data) => messages2.push(JSON.parse(data.toString())));

      await Promise.all([
        new Promise<void>((resolve) => ws1.on('open', resolve)),
        new Promise<void>((resolve) => ws2.on('open', resolve)),
      ]);

      // Trigger a session update by making an API request
      const fetch = (await import('node-fetch')).default;
      await fetch(`http://localhost:${server.address().port}/api/sessions`, {
        method: 'GET',
      });

      await waitForWebSocket(100);

      // Both clients should receive session update
      const updates1 = messages1.filter((m) => m.type === 'sessions-updated');
      const updates2 = messages2.filter((m) => m.type === 'sessions-updated');

      expect(updates1.length).toBeGreaterThan(0);
      expect(updates2.length).toBeGreaterThan(0);

      ws1.close();
      ws2.close();
    });
  });
});
