/**
 * Basic tests for PtyService
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { PtyService } from '../PtyService.js';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

describe('PtyService', () => {
  let tempDir: string;
  let ptyService: PtyService;

  beforeEach(() => {
    // Create temporary directory for testing
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ptyservice-test-'));

    ptyService = new PtyService({
      controlPath: tempDir,
      implementation: 'auto',
      fallbackToTtyFwd: true,
    });
  });

  afterEach(() => {
    // Cleanup temporary directory
    if (fs.existsSync(tempDir)) {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });

  it('should initialize successfully', () => {
    expect(ptyService).toBeDefined();
    expect(ptyService.getControlPath()).toBe(tempDir);
  });

  it('should detect implementation', () => {
    const implementation = ptyService.getCurrentImplementation();
    expect(implementation).toMatch(/^(node-pty|tty-fwd)$/);
  });

  it('should list sessions (empty initially)', () => {
    const sessions = ptyService.listSessions();
    expect(Array.isArray(sessions)).toBe(true);
    expect(sessions.length).toBe(0);
  });

  it('should get active session count', () => {
    const count = ptyService.getActiveSessionCount();
    expect(typeof count).toBe('number');
    expect(count).toBeGreaterThanOrEqual(0);
  });

  it('should return configuration', () => {
    const config = ptyService.getConfig();
    expect(config.controlPath).toBe(tempDir);
    expect(config.fallbackToTtyFwd).toBe(true);
  });

  // Only run session creation test if node-pty is available
  it.skipIf(!process.env.CI)('should create and manage a session', async () => {
    if (!ptyService.isUsingNodePty()) {
      // Skip if using tty-fwd (requires actual binary)
      return;
    }

    // Create a simple echo session
    const result = await ptyService.createSession(['echo', 'hello'], {
      sessionName: 'test-session',
    });

    expect(result.sessionId).toBeDefined();
    expect(result.sessionInfo.name).toBe('test-session');
    expect(result.sessionInfo.cmdline).toEqual(['echo', 'hello']);

    // List sessions should now include our session
    const sessions = ptyService.listSessions();
    expect(sessions.length).toBe(1);
    expect(sessions[0].session_id).toBe(result.sessionId);

    // Get specific session
    const session = ptyService.getSession(result.sessionId);
    expect(session).toBeDefined();
    expect(session?.session_id).toBe(result.sessionId);

    // Wait a bit for echo to complete
    await new Promise((resolve) => setTimeout(resolve, 100));

    // Cleanup
    ptyService.cleanupSession(result.sessionId);

    // Should be cleaned up
    const sessionsAfterCleanup = ptyService.listSessions();
    expect(sessionsAfterCleanup.length).toBe(0);
  });
});
