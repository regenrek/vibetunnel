import { describe, it, expect, beforeAll, afterAll, beforeEach } from 'vitest';
import request from 'supertest';
import { Server } from 'http';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { WebSocket } from 'ws';

// Set up test environment
process.env.NODE_ENV = 'test';
process.env.TTY_FWD_CONTROL_DIR = path.join(
  os.tmpdir(),
  'vibetunnel-server-test',
  Date.now().toString()
);

// Create test control directory
const testControlDir = process.env.TTY_FWD_CONTROL_DIR;
if (!fs.existsSync(testControlDir)) {
  fs.mkdirSync(testControlDir, { recursive: true });
}

describe('Server Integration Tests', () => {
  let server: Server;
  let app: any;
  let port: number;
  let baseUrl: string;

  beforeAll(async () => {
    // Import server after environment is set up
    const serverModule = await import('../../server');
    app = serverModule.app;
    server = serverModule.server;

    // Start server on random port
    await new Promise<void>((resolve) => {
      server = app.listen(0, () => {
        const address = server.address();
        port = (address as any).port;
        baseUrl = `http://localhost:${port}`;
        resolve();
      });
    });
  });

  afterAll(async () => {
    // Close server
    await new Promise<void>((resolve) => {
      server.close(() => resolve());
    });

    // Clean up test directory
    if (fs.existsSync(testControlDir)) {
      fs.rmSync(testControlDir, { recursive: true });
    }
  });

  describe('API Endpoints', () => {
    describe('GET /api/sessions', () => {
      it('should return sessions list', async () => {
        const response = await request(app).get('/api/sessions').expect(200);

        expect(Array.isArray(response.body)).toBe(true);
      });
    });

    describe('POST /api/sessions', () => {
      it('should validate command parameter', async () => {
        const response = await request(app)
          .post('/api/sessions')
          .send({
            command: 'not-an-array',
            workingDir: process.cwd(),
          })
          .expect(400);

        expect(response.body.error).toContain('Command array is required');
      });

      it('should validate working directory', async () => {
        const response = await request(app)
          .post('/api/sessions')
          .send({
            command: ['echo', 'test'],
          })
          .expect(400);

        expect(response.body.error).toContain('Working directory is required');
      });

      it('should create session with valid parameters', async () => {
        const response = await request(app)
          .post('/api/sessions')
          .send({
            command: ['echo', 'hello'],
            workingDir: process.cwd(),
            name: 'Test Echo',
          })
          .expect(200);

        expect(response.body).toHaveProperty('sessionId');
        expect(response.body.sessionId).toBeTruthy();
      });
    });

    describe('GET /api/fs/browse', () => {
      it('should list directory contents', async () => {
        const response = await request(app)
          .get('/api/fs/browse')
          .query({ path: process.cwd() })
          .expect(200);

        expect(response.body).toHaveProperty('entries');
        expect(Array.isArray(response.body.entries)).toBe(true);
        expect(response.body).toHaveProperty('currentPath');
      });

      it('should reject invalid paths', async () => {
        const response = await request(app)
          .get('/api/fs/browse')
          .query({ path: '/nonexistent/path' })
          .expect(404);

        expect(response.body.error).toContain('Directory not found');
      });
    });

    describe('POST /api/mkdir', () => {
      it('should validate directory name', async () => {
        const response = await request(app)
          .post('/api/mkdir')
          .send({
            path: process.cwd(),
            name: '../invalid',
          })
          .expect(400);

        expect(response.body.error).toContain('Invalid directory name');
      });

      it('should create directory with valid name', async () => {
        const testDirName = `test-dir-${Date.now()}`;
        const response = await request(app)
          .post('/api/mkdir')
          .send({
            path: process.cwd(),
            name: testDirName,
          })
          .expect(200);

        expect(response.body.success).toBe(true);
        expect(response.body.path).toContain(testDirName);

        // Clean up
        const createdPath = path.join(process.cwd(), testDirName);
        if (fs.existsSync(createdPath)) {
          fs.rmdirSync(createdPath);
        }
      });
    });

    describe('GET /api/test-cast', () => {
      it('should return test cast data', async () => {
        // Skip this test if stream-out file doesn't exist
        const testCastPath = path.join(__dirname, '../../../public/stream-out');
        if (!fs.existsSync(testCastPath)) {
          return;
        }

        const response = await request(app).get('/api/test-cast').expect(200);

        // The endpoint returns plain text, not JSON
        expect(response.type).toContain('text/plain');
      });
    });
  });

  describe('Static File Serving', () => {
    it('should serve index.html for root path', async () => {
      const response = await request(app).get('/').expect(200);

      expect(response.type).toContain('text/html');
    });

    it('should handle 404 for non-existent files', async () => {
      const response = await request(app).get('/non-existent-file.js').expect(404);

      expect(response.text).toContain('404');
    });
  });

  describe('WebSocket Connection', () => {
    it('should accept WebSocket connections', (done) => {
      const ws = new WebSocket(`ws://localhost:${port}?hotReload=true`);

      ws.on('open', () => {
        expect(ws.readyState).toBe(WebSocket.OPEN);
        ws.close();
      });

      ws.on('close', () => {
        done();
      });

      ws.on('error', (err) => {
        done(err);
      });
    });

    it('should reject non-hot-reload connections', (done) => {
      const ws = new WebSocket(`ws://localhost:${port}`);

      ws.on('close', (code, reason) => {
        expect(code).toBe(1008);
        expect(reason.toString()).toContain('Only hot reload connections supported');
        done();
      });

      ws.on('error', () => {
        // Expected to error
      });
    });
  });

  describe('Error Handling', () => {
    it('should handle JSON parsing errors', async () => {
      const response = await request(app)
        .post('/api/sessions')
        .set('Content-Type', 'application/json')
        .send('invalid json')
        .expect(400);

      expect(response.status).toBe(400);
    });

    it('should handle server errors gracefully', async () => {
      // Test with an endpoint that might fail
      const response = await request(app).delete('/api/sessions/non-existent-session').expect(404);

      expect(response.body).toHaveProperty('error');
    });
  });
});
