import { describe, it, expect, beforeAll, afterAll, beforeEach, afterEach } from 'vitest';
import request from 'supertest';
import { Server } from 'http';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { v4 as uuidv4 } from 'uuid';
// @ts-expect-error - TypeScript module imports in tests
import { app, server } from '../../server';

// Set up test environment
process.env.NODE_ENV = 'test';
process.env.PORT = '0'; // Random port
const testControlDir = path.join(os.tmpdir(), 'vibetunnel-test', uuidv4());
process.env.TTY_FWD_CONTROL_DIR = testControlDir;

// Ensure test directory exists
beforeAll(() => {
  if (!fs.existsSync(testControlDir)) {
    fs.mkdirSync(testControlDir, { recursive: true });
  }
});

afterAll(() => {
  // Clean up test directory
  if (fs.existsSync(testControlDir)) {
    fs.rmSync(testControlDir, { recursive: true, force: true });
  }
});

describe('API Integration Tests', () => {
  let port: number;
  let baseUrl: string;
  let activeSessionIds: string[] = [];

  beforeAll(async () => {
    // Get the port the server is listening on
    await new Promise<void>((resolve) => {
      if (!server.listening) {
        server.listen(0, () => {
          const address = server.address();
          port = (address as any).port;
          baseUrl = `http://localhost:${port}`;
          resolve();
        });
      } else {
        const address = server.address();
        port = (address as any).port;
        baseUrl = `http://localhost:${port}`;
        resolve();
      }
    });
  });

  afterAll(async () => {
    // Clean up any remaining sessions
    for (const sessionId of activeSessionIds) {
      try {
        await request(app).delete(`/api/sessions/${sessionId}`);
      } catch (e) {
        // Ignore errors during cleanup
      }
    }

    // Close server
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
    });
  });

  afterEach(async () => {
    // Clean up sessions created in tests
    const cleanupPromises = activeSessionIds.map((sessionId) =>
      request(app)
        .delete(`/api/sessions/${sessionId}`)
        .catch(() => {})
    );
    await Promise.all(cleanupPromises);
    activeSessionIds = [];
  });

  describe('Session Lifecycle', () => {
    it('should create, list, and terminate a session', async () => {
      // Create a session
      const createResponse = await request(app)
        .post('/api/sessions')
        .send({
          command: ['sh', '-c', 'echo "test" && sleep 0.1'],
          workingDir: os.tmpdir(),
          name: 'Integration Test Session',
        })
        .expect(200);

      expect(createResponse.body).toHaveProperty('sessionId');
      const sessionId = createResponse.body.sessionId;
      activeSessionIds.push(sessionId);
      expect(sessionId).toMatch(/^[a-f0-9-]+$/);

      // List sessions and verify our session exists
      const listResponse = await request(app).get('/api/sessions').expect(200);

      expect(listResponse.body).toHaveProperty('sessions');
      expect(Array.isArray(listResponse.body.sessions)).toBe(true);

      const ourSession = listResponse.body.sessions.find((s: any) => s.id === sessionId);
      expect(ourSession).toBeDefined();
      expect(ourSession.command).toBe('sh -c echo "test" && sleep 0.1');
      expect(ourSession.name).toBe('Integration Test Session');
      expect(ourSession.workingDir).toBe(os.tmpdir());
      expect(ourSession.status).toBe('running');

      // Get session snapshot
      const snapshotResponse = await request(app)
        .get(`/api/sessions/${sessionId}/snapshot`)
        .expect(200);

      expect(snapshotResponse.body).toHaveProperty('lines');
      expect(snapshotResponse.body).toHaveProperty('cursor');
      expect(Array.isArray(snapshotResponse.body.lines)).toBe(true);

      // Send input to session
      const inputResponse = await request(app)
        .post(`/api/sessions/${sessionId}/input`)
        .send({ data: 'exit\n' })
        .expect(200);

      expect(inputResponse.body.message).toBe('Input sent');

      // Wait a bit for the session to process
      await new Promise((resolve) => setTimeout(resolve, 200));

      // Terminate the session
      const terminateResponse = await request(app).delete(`/api/sessions/${sessionId}`).expect(200);

      expect(terminateResponse.body.message).toBe('Session terminated');

      // Remove from active sessions
      activeSessionIds = activeSessionIds.filter((id) => id !== sessionId);
    });

    it('should handle multiple concurrent sessions', async () => {
      const sessionCount = 3;
      const createPromises = [];

      // Create multiple sessions
      for (let i = 0; i < sessionCount; i++) {
        const promise = request(app)
          .post('/api/sessions')
          .send({
            command: ['sh', '-c', `echo "Session ${i}" && sleep 0.1`],
            workingDir: os.tmpdir(),
            name: `Test Session ${i}`,
          });
        createPromises.push(promise);
      }

      const createResponses = await Promise.all(createPromises);
      const sessionIds = createResponses.map((res) => res.body.sessionId);
      activeSessionIds.push(...sessionIds);

      // Verify all sessions were created
      expect(sessionIds).toHaveLength(sessionCount);
      sessionIds.forEach((id) => expect(id).toMatch(/^[a-f0-9-]+$/));

      // List all sessions
      const listResponse = await request(app).get('/api/sessions').expect(200);

      const activeSessions = listResponse.body.sessions.filter((s: any) =>
        sessionIds.includes(s.id)
      );
      expect(activeSessions).toHaveLength(sessionCount);

      // Clean up all sessions
      const deletePromises = sessionIds.map((id) => request(app).delete(`/api/sessions/${id}`));
      await Promise.all(deletePromises);
      activeSessionIds = [];
    });

    it('should handle session exit and cleanup', async () => {
      // Create a session that exits quickly
      const createResponse = await request(app)
        .post('/api/sessions')
        .send({
          command: ['sh', '-c', 'echo "Quick exit" && exit 0'],
          workingDir: os.tmpdir(),
          name: 'Quick Exit Session',
        })
        .expect(200);

      const sessionId = createResponse.body.sessionId;
      activeSessionIds.push(sessionId);

      // Wait for session to exit
      await new Promise((resolve) => setTimeout(resolve, 500));

      // Check session status
      const listResponse = await request(app).get('/api/sessions').expect(200);

      const session = listResponse.body.sessions.find((s: any) => s.id === sessionId);
      if (session) {
        expect(session.status).toBe('exited');
        expect(session.exitCode).toBe(0);
      }

      // Cleanup exited sessions
      const cleanupResponse = await request(app).post('/api/cleanup-exited').expect(200);

      expect(cleanupResponse.body.message).toBe('All exited sessions cleaned up');

      // Verify session was cleaned up
      const listAfterCleanup = await request(app).get('/api/sessions').expect(200);

      const sessionAfterCleanup = listAfterCleanup.body.sessions.find(
        (s: any) => s.id === sessionId
      );
      expect(sessionAfterCleanup).toBeUndefined();

      activeSessionIds = activeSessionIds.filter((id) => id !== sessionId);
    });
  });

  describe('Input/Output Operations', () => {
    it('should handle terminal resize', async () => {
      // Create a session
      const createResponse = await request(app)
        .post('/api/sessions')
        .send({
          command: ['sh'],
          workingDir: os.tmpdir(),
          name: 'Resize Test',
        })
        .expect(200);

      const sessionId = createResponse.body.sessionId;
      activeSessionIds.push(sessionId);

      // Resize the terminal
      const resizeResponse = await request(app)
        .post(`/api/sessions/${sessionId}/resize`)
        .send({ cols: 120, rows: 40 })
        .expect(200);

      expect(resizeResponse.body.message).toBe('Terminal resized');

      // Clean up
      await request(app).delete(`/api/sessions/${sessionId}`);
      activeSessionIds = activeSessionIds.filter((id) => id !== sessionId);
    });

    it('should stream session output', async () => {
      // Create a session that produces output
      const createResponse = await request(app)
        .post('/api/sessions')
        .send({
          command: ['sh', '-c', 'for i in 1 2 3; do echo "Line $i"; sleep 0.1; done'],
          workingDir: os.tmpdir(),
          name: 'Stream Test',
        })
        .expect(200);

      const sessionId = createResponse.body.sessionId;
      activeSessionIds.push(sessionId);

      // Get the stream endpoint
      const streamResponse = await request(app)
        .get(`/api/sessions/${sessionId}/stream`)
        .expect(200);

      expect(streamResponse.headers['content-type']).toContain('text/event-stream');

      // Clean up
      await request(app).delete(`/api/sessions/${sessionId}`);
      activeSessionIds = activeSessionIds.filter((id) => id !== sessionId);
    });
  });

  describe('File System Operations', () => {
    it('should browse directories', async () => {
      const testDir = os.tmpdir();

      const response = await request(app)
        .get('/api/fs/browse')
        .query({ path: testDir })
        .expect(200);

      expect(response.body).toHaveProperty('currentPath');
      expect(response.body).toHaveProperty('parentPath');
      expect(response.body).toHaveProperty('entries');
      expect(Array.isArray(response.body.entries)).toBe(true);
      expect(response.body.currentPath).toBe(testDir);
    });

    it('should create directories', async () => {
      const parentDir = os.tmpdir();
      const testDirName = `vibetunnel-test-${Date.now()}`;

      const response = await request(app)
        .post('/api/mkdir')
        .send({
          path: parentDir,
          name: testDirName,
        })
        .expect(200);

      expect(response.body.success).toBe(true);
      expect(response.body.path).toContain(testDirName);

      // Verify directory was created
      const createdPath = path.join(parentDir, testDirName);
      expect(fs.existsSync(createdPath)).toBe(true);

      // Clean up
      fs.rmdirSync(createdPath);
    });

    it('should handle directory creation errors', async () => {
      // Try to create directory with invalid name
      const response = await request(app)
        .post('/api/mkdir')
        .send({
          path: os.tmpdir(),
          name: '../../../etc/invalid',
        })
        .expect(400);

      expect(response.body.error).toContain('Invalid directory name');
    });

    it('should prevent directory traversal', async () => {
      const response = await request(app)
        .get('/api/fs/browse')
        .query({ path: '../../../etc/passwd' })
        .expect(400);

      expect(response.body.error).toContain('Invalid path');
    });
  });

  describe('Error Handling', () => {
    it('should handle invalid session IDs', async () => {
      const invalidId = 'invalid-session-id';

      const responses = await Promise.all([
        request(app).get(`/api/sessions/${invalidId}/snapshot`).expect(404),
        request(app).post(`/api/sessions/${invalidId}/input`).send({ data: 'test' }).expect(404),
        request(app).delete(`/api/sessions/${invalidId}`).expect(404),
      ]);

      responses.forEach((res) => {
        expect(res.body).toHaveProperty('error');
      });
    });

    it('should validate session creation parameters', async () => {
      // Missing command
      const missingCommand = await request(app)
        .post('/api/sessions')
        .send({ workingDir: os.tmpdir() })
        .expect(400);
      expect(missingCommand.body.error).toContain('Command array is required');

      // Invalid command type
      const invalidCommand = await request(app)
        .post('/api/sessions')
        .send({ command: 'not-an-array', workingDir: os.tmpdir() })
        .expect(400);
      expect(invalidCommand.body.error).toContain('Command array is required');

      // Missing working directory
      const missingDir = await request(app)
        .post('/api/sessions')
        .send({ command: ['ls'] })
        .expect(400);
      expect(missingDir.body.error).toContain('Working directory is required');

      // Non-existent working directory
      const invalidDir = await request(app)
        .post('/api/sessions')
        .send({ command: ['ls'], workingDir: '/non/existent/path' })
        .expect(400);
      expect(invalidDir.body.error).toContain('Working directory does not exist');
    });

    it('should handle command execution failures', async () => {
      const response = await request(app)
        .post('/api/sessions')
        .send({
          command: ['/non/existent/command'],
          workingDir: os.tmpdir(),
        })
        .expect(200); // Session creation succeeds, but command will fail

      const sessionId = response.body.sessionId;
      activeSessionIds.push(sessionId);

      // Wait for command to fail
      await new Promise((resolve) => setTimeout(resolve, 500));

      // Check session status
      const listResponse = await request(app).get('/api/sessions').expect(200);

      const session = listResponse.body.sessions.find((s: any) => s.id === sessionId);
      if (session && session.status === 'exited') {
        expect(session.exitCode).not.toBe(0);
      }
    });
  });

  describe('Cast File Generation', () => {
    it('should generate test cast file', async () => {
      const response = await request(app).get('/api/test-cast').expect(200);

      expect(response.body).toHaveProperty('version');
      expect(response.body).toHaveProperty('width');
      expect(response.body).toHaveProperty('height');
      expect(response.body).toHaveProperty('timestamp');
      expect(response.body).toHaveProperty('events');
      expect(response.body.version).toBe(2);
      expect(Array.isArray(response.body.events)).toBe(true);
      expect(response.body.events.length).toBeGreaterThan(0);
    });
  });
});
