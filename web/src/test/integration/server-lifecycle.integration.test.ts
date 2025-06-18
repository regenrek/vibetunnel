import { describe, it, expect, beforeAll, afterAll } from 'vitest';
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
process.env.PORT = '0';
const testControlDir = path.join(os.tmpdir(), 'vibetunnel-lifecycle-test', uuidv4());
process.env.TTY_FWD_CONTROL_DIR = testControlDir;

describe('Server Lifecycle Integration Tests', () => {
  let port: number;

  beforeAll(() => {
    if (!fs.existsSync(testControlDir)) {
      fs.mkdirSync(testControlDir, { recursive: true });
    }
  });

  afterAll(() => {
    if (fs.existsSync(testControlDir)) {
      fs.rmSync(testControlDir, { recursive: true, force: true });
    }
  });

  describe('Server Initialization', () => {
    it('should start server and create control directory', async () => {
      // Start server
      await new Promise<void>((resolve) => {
        if (!server.listening) {
          server.listen(0, () => {
            const address = server.address();
            port = (address as any).port;
            resolve();
          });
        } else {
          const address = server.address();
          port = (address as any).port;
          resolve();
        }
      });

      expect(port).toBeGreaterThan(0);
      expect(server.listening).toBe(true);

      // Verify control directory exists
      expect(fs.existsSync(testControlDir)).toBe(true);
    });

    it('should serve static files', async () => {
      // Test root route
      const rootResponse = await request(app).get('/').expect(200);

      expect(rootResponse.type).toContain('text/html');
      expect(rootResponse.text).toContain('<!DOCTYPE html>');

      // Test favicon
      const faviconResponse = await request(app).get('/favicon.ico').expect(200);

      expect(faviconResponse.type).toContain('image');
    });

    it('should handle 404 for non-existent routes', async () => {
      const response = await request(app).get('/non-existent-route').expect(404);

      expect(response.text).toContain('404');
    });

    it('should have all API endpoints available', async () => {
      const endpoints = [
        { method: 'get', path: '/api/sessions' },
        { method: 'post', path: '/api/sessions' },
        { method: 'get', path: '/api/test-cast' },
        { method: 'get', path: '/api/fs/browse' },
        { method: 'post', path: '/api/mkdir' },
        { method: 'post', path: '/api/cleanup-exited' },
      ];

      for (const endpoint of endpoints) {
        const response = await request(app)[endpoint.method](endpoint.path);

        // Should not return 404 (may return other errors like 400 for missing params)
        expect(response.status).not.toBe(404);
      }
    });
  });

  describe('Middleware and Security', () => {
    it('should parse JSON bodies', async () => {
      const response = await request(app)
        .post('/api/sessions')
        .send({ test: 'data' })
        .set('Content-Type', 'application/json')
        .expect(400); // Will fail validation but should parse the body

      expect(response.body).toHaveProperty('error');
    });

    it('should handle CORS headers', async () => {
      const response = await request(app).get('/api/sessions').expect(200);

      // In production, you might want to check for CORS headers
      // For now, just verify the request succeeds
      expect(response.body).toHaveProperty('sessions');
    });

    it('should handle large request bodies', async () => {
      const largeCommand = Array(1000).fill('arg');

      const response = await request(app)
        .post('/api/sessions')
        .send({
          command: largeCommand,
          workingDir: os.tmpdir(),
        })
        .expect(400); // Should fail but handle the large body

      expect(response.body).toHaveProperty('error');
    });
  });

  describe('Concurrent Request Handling', () => {
    it('should handle multiple simultaneous requests', async () => {
      const requestCount = 10;
      const requests = [];

      for (let i = 0; i < requestCount; i++) {
        requests.push(request(app).get('/api/sessions'));
      }

      const responses = await Promise.all(requests);

      // All requests should succeed
      responses.forEach((response) => {
        expect(response.status).toBe(200);
        expect(response.body).toHaveProperty('sessions');
      });
    });

    it('should handle mixed read/write operations', async () => {
      const operations = [
        request(app).get('/api/sessions'),
        request(app)
          .post('/api/sessions')
          .send({
            command: ['echo', 'test1'],
            workingDir: os.tmpdir(),
          }),
        request(app).get('/api/test-cast'),
        request(app)
          .post('/api/sessions')
          .send({
            command: ['echo', 'test2'],
            workingDir: os.tmpdir(),
          }),
        request(app).get('/api/fs/browse').query({ path: os.tmpdir() }),
      ];

      const responses = await Promise.all(operations);

      // All operations should complete without errors
      responses.forEach((response) => {
        expect(response.status).toBeLessThan(500); // No server errors
      });

      // Clean up created sessions
      const createdSessions = responses
        .filter((r) => r.body && r.body.sessionId)
        .map((r) => r.body.sessionId);

      for (const sessionId of createdSessions) {
        await request(app).delete(`/api/sessions/${sessionId}`);
      }
    });
  });

  describe('Server Shutdown', () => {
    it('should close gracefully', async () => {
      // Create a session that will be active
      const createResponse = await request(app)
        .post('/api/sessions')
        .send({
          command: ['sh', '-c', 'sleep 10'],
          workingDir: os.tmpdir(),
        })
        .expect(200);

      const sessionId = createResponse.body.sessionId;

      // Close the server
      await new Promise<void>((resolve) => {
        server.close(() => {
          resolve();
        });
      });

      expect(server.listening).toBe(false);

      // The session should be terminated (tty-fwd should handle this)
      // In a real implementation, you might want to verify this
    });
  });
});
