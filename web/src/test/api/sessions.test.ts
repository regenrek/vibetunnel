import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import request from 'supertest';
import express from 'express';
import { spawn } from 'child_process';
import { createMockSession } from '../test-utils';

// Mock child_process
vi.mock('child_process', () => ({
  spawn: vi.fn(),
}));

// Mock fs module
vi.mock('fs', () => ({
  default: {
    existsSync: vi.fn(() => true),
    mkdirSync: vi.fn(),
    readdirSync: vi.fn(() => []),
    statSync: vi.fn(() => ({ isDirectory: () => true })),
  },
}));

// Mock os module
vi.mock('os', () => ({
  default: {
    homedir: () => '/home/test',
  },
}));

describe('Sessions API', () => {
  let app: express.Application;
  let mockSpawn: any;

  beforeEach(() => {
    // Clear all mocks
    vi.clearAllMocks();

    // Set up mock spawn
    mockSpawn = vi.mocked(spawn);

    // Create a fresh app instance for each test
    app = express();
    app.use(express.json());

    // Mock tty-fwd execution
    const mockTtyFwdProcess = {
      stdout: {
        on: vi.fn((event, callback) => {
          if (event === 'data') {
            // Default to empty JSON response
            callback(Buffer.from('{}'));
          }
        }),
      },
      stderr: {
        on: vi.fn(),
      },
      on: vi.fn((event, callback) => {
        if (event === 'close') {
          callback(0); // Success
        }
      }),
      kill: vi.fn(),
    };

    mockSpawn.mockReturnValue(mockTtyFwdProcess);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('GET /api/sessions', () => {
    it('should return empty array when no sessions exist', async () => {
      // Import server code after mocks are set up
      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app).get('/api/sessions').expect(200);

      expect(response.body).toEqual({ sessions: [] });
    });

    it('should return list of sessions', async () => {
      // Mock tty-fwd list response
      const mockSessions = {
        'session-1': {
          cmdline: ['bash'],
          cwd: '/home/test',
          exit_code: null,
          name: 'bash',
          pid: 1234,
          started_at: '2024-01-01T00:00:00Z',
          status: 'running',
          stdin: '/tmp/session-1.stdin',
          'stream-out': '/tmp/session-1.out',
          waiting: false,
        },
      };

      mockSpawn.mockImplementationOnce(() => ({
        stdout: {
          on: vi.fn((event, callback) => {
            if (event === 'data') {
              callback(Buffer.from(JSON.stringify(mockSessions)));
            }
          }),
        },
        stderr: { on: vi.fn() },
        on: vi.fn((event, callback) => {
          if (event === 'close') callback(0);
        }),
        kill: vi.fn(),
      }));

      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app).get('/api/sessions').expect(200);

      expect(response.body.sessions).toHaveLength(1);
      expect(response.body.sessions[0]).toMatchObject({
        id: 'session-1',
        command: 'bash',
        workingDir: '/home/test',
        status: 'running',
        pid: 1234,
      });
    });
  });

  describe('POST /api/sessions', () => {
    it('should create a new session', async () => {
      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app)
        .post('/api/sessions')
        .send({
          command: ['bash'],
          workingDir: '/home/test',
          name: 'Test Session',
        })
        .expect(201);

      expect(response.body).toHaveProperty('sessionId');
      expect(response.body.sessionId).toMatch(/^[a-f0-9-]+$/);

      // Verify tty-fwd was called with correct arguments
      expect(mockSpawn).toHaveBeenCalledWith(
        expect.any(String), // TTY_FWD_PATH
        expect.arrayContaining(['spawn'])
      );
    });

    it('should reject invalid command', async () => {
      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app)
        .post('/api/sessions')
        .send({
          command: 'not-an-array',
          workingDir: '/home/test',
        })
        .expect(400);

      expect(response.body.error).toBe('Invalid command');
    });

    it('should reject missing working directory', async () => {
      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app)
        .post('/api/sessions')
        .send({
          command: ['bash'],
        })
        .expect(400);

      expect(response.body.error).toBe('Invalid working directory');
    });
  });

  describe('DELETE /api/sessions/:sessionId', () => {
    it('should terminate a session', async () => {
      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app).delete('/api/sessions/test-session-123').expect(200);

      expect(response.body.message).toBe('Session terminated');

      // Verify tty-fwd was called with terminate command
      expect(mockSpawn).toHaveBeenCalledWith(
        expect.any(String),
        expect.arrayContaining(['terminate', 'test-session-123'])
      );
    });

    it('should handle non-existent session gracefully', async () => {
      // Mock tty-fwd to return error
      mockSpawn.mockImplementationOnce(() => ({
        stdout: { on: vi.fn() },
        stderr: { on: vi.fn() },
        on: vi.fn((event, callback) => {
          if (event === 'close') callback(1); // Error code
        }),
        kill: vi.fn(),
      }));

      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app).delete('/api/sessions/non-existent').expect(500);

      expect(response.body.error).toContain('Failed to terminate session');
    });
  });

  describe('POST /api/cleanup-exited', () => {
    it('should cleanup exited sessions', async () => {
      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app).post('/api/cleanup-exited').expect(200);

      expect(response.body.message).toBe('Cleanup initiated');

      // Verify tty-fwd was called with cleanup command
      expect(mockSpawn).toHaveBeenCalledWith(expect.any(String), expect.arrayContaining(['clean']));
    });
  });

  describe('GET /api/sessions/:sessionId/snapshot', () => {
    it('should return terminal snapshot', async () => {
      // Mock tty-fwd to return snapshot data
      const mockSnapshot = {
        lines: ['Line 1', 'Line 2', 'Line 3'],
        cursor: { x: 0, y: 2 },
        cols: 80,
        rows: 24,
      };

      mockSpawn.mockImplementationOnce(() => ({
        stdout: {
          on: vi.fn((event, callback) => {
            if (event === 'data') {
              callback(Buffer.from(JSON.stringify(mockSnapshot)));
            }
          }),
        },
        stderr: { on: vi.fn() },
        on: vi.fn((event, callback) => {
          if (event === 'close') callback(0);
        }),
        kill: vi.fn(),
      }));

      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app)
        .get('/api/sessions/test-session-123/snapshot')
        .expect(200);

      expect(response.body).toEqual(mockSnapshot);
    });
  });

  describe('POST /api/sessions/:sessionId/input', () => {
    it('should send input to session', async () => {
      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app)
        .post('/api/sessions/test-session-123/input')
        .send({ data: 'ls -la\n' })
        .expect(200);

      expect(response.body.message).toBe('Input sent');

      // Verify tty-fwd was called with write command
      expect(mockSpawn).toHaveBeenCalledWith(
        expect.any(String),
        expect.arrayContaining(['write', 'test-session-123', 'ls -la\n'])
      );
    });

    it('should reject missing input data', async () => {
      const serverModule = await import('../../server');
      const app = serverModule.app;

      const response = await request(app)
        .post('/api/sessions/test-session-123/input')
        .send({})
        .expect(400);

      expect(response.body.error).toBe('Invalid input data');
    });
  });
});
