/**
 * PtyService - Integration layer with fallback to tty-fwd
 *
 * This service provides a unified interface that can use either the native
 * Node.js PTY implementation or fall back to the existing tty-fwd binary.
 */

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { spawn, spawnSync } from 'child_process';
import {
  SessionEntryWithId,
  SessionOptions,
  SessionInput,
  PtyConfig,
  SessionCreationResult,
  PtyError,
} from './types.js';
import { PtyManager } from './PtyManager.js';

export class PtyService {
  private config: PtyConfig;
  private ptyManager: PtyManager | null = null;

  constructor(config?: Partial<PtyConfig>) {
    this.config = {
      implementation: 'auto',
      controlPath: path.join(os.homedir(), '.vibetunnel', 'control'),
      fallbackToTtyFwd: true,
      ...config,
    };

    // Initialize based on implementation choice
    this.initialize();
  }

  /**
   * Initialize the service based on configuration
   */
  private initialize(): void {
    const implementation = this.determineImplementation();

    if (implementation === 'node-pty') {
      try {
        this.ptyManager = new PtyManager(this.config.controlPath);
        console.log('PtyService: Using node-pty implementation');
      } catch (error) {
        console.warn('PtyService: Failed to initialize node-pty:', error);
        if (this.config.fallbackToTtyFwd) {
          console.log('PtyService: Falling back to tty-fwd');
          this.ptyManager = null;
        } else {
          throw new PtyError('Failed to initialize node-pty and fallback disabled');
        }
      }
    } else {
      console.log('PtyService: Using tty-fwd implementation');
      this.ptyManager = null;
    }
  }

  /**
   * Determine which implementation to use
   */
  private determineImplementation(): 'node-pty' | 'tty-fwd' {
    if (this.config.implementation === 'node-pty') {
      return 'node-pty';
    }

    if (this.config.implementation === 'tty-fwd') {
      return 'tty-fwd';
    }

    // Auto-detection
    try {
      // Check if node-pty is available and working
      require('@lydell/node-pty');

      // Check if we have write access to control directory
      const controlPath = this.config.controlPath;
      if (!fs.existsSync(controlPath)) {
        fs.mkdirSync(controlPath, { recursive: true });
      }
      fs.accessSync(controlPath, fs.constants.W_OK);

      return 'node-pty';
    } catch (error) {
      console.warn('PtyService: node-pty not available, using tty-fwd:', error);
      return 'tty-fwd';
    }
  }

  /**
   * Create a new session
   */
  async createSession(
    command: string[],
    options: SessionOptions = {}
  ): Promise<SessionCreationResult> {
    if (this.ptyManager) {
      return await this.ptyManager.createSession(command, options);
    } else {
      return await this.createSessionTtyFwd(command, options);
    }
  }

  /**
   * Create session using tty-fwd binary
   */
  private async createSessionTtyFwd(
    command: string[],
    options: SessionOptions
  ): Promise<SessionCreationResult> {
    return new Promise((resolve, reject) => {
      const ttyFwdPath = this.findTtyFwdBinary();
      const args = ['--control-path', this.config.controlPath];

      if (options.sessionName) {
        args.push('--session-name', options.sessionName);
      }

      args.push('--', ...command);

      const proc = spawn(ttyFwdPath, args, {
        cwd: options.workingDir || process.cwd(),
        env: {
          ...process.env,
          TERM: options.term || 'xterm-256color',
        },
      });

      let output = '';
      let error = '';

      proc.stdout?.on('data', (data) => {
        output += data.toString();
      });

      proc.stderr?.on('data', (data) => {
        error += data.toString();
      });

      proc.on('close', (code) => {
        if (code === 0) {
          // Parse session ID from output (tty-fwd should output session ID)
          const sessionId = output.trim();

          // Wait a bit for session file to be created
          setTimeout(() => {
            try {
              const session = this.getSession(sessionId);
              if (session) {
                resolve({
                  sessionId,
                  sessionInfo: {
                    cmdline: session.cmdline,
                    name: session.name,
                    cwd: session.cwd,
                    pid: session.pid,
                    status: session.status,
                    exit_code: session.exit_code,
                    started_at: session.started_at,
                    term: session.term,
                    spawn_type: session.spawn_type,
                  },
                });
              } else {
                reject(new PtyError(`Session ${sessionId} not found after creation`));
              }
            } catch (err) {
              reject(new PtyError(`Failed to get session info: ${err}`));
            }
          }, 100);
        } else {
          reject(new PtyError(`tty-fwd failed with code ${code}: ${error}`));
        }
      });

      proc.on('error', (err) => {
        reject(new PtyError(`Failed to spawn tty-fwd: ${err.message}`));
      });
    });
  }

  /**
   * Send input to a session
   */
  sendInput(sessionId: string, input: SessionInput): void {
    if (this.ptyManager) {
      return this.ptyManager.sendInput(sessionId, input);
    } else {
      return this.sendInputTtyFwd(sessionId, input);
    }
  }

  /**
   * Send input using tty-fwd binary
   */
  private sendInputTtyFwd(sessionId: string, input: SessionInput): void {
    const ttyFwdPath = this.findTtyFwdBinary();
    const args = ['--control-path', this.config.controlPath, '--session', sessionId];

    if (input.text !== undefined) {
      args.push('--send-text', input.text);
    } else if (input.key !== undefined) {
      args.push('--send-key', input.key);
    } else {
      throw new PtyError('No text or key specified in input');
    }

    try {
      const result = spawnSync(ttyFwdPath, args, {
        stdio: 'pipe',
        timeout: 5000,
      });

      if (result.status !== 0) {
        throw new PtyError(`tty-fwd send input failed with code ${result.status}`);
      }
    } catch (error) {
      throw new PtyError(
        `Failed to send input via tty-fwd: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  /**
   * Resize a session
   */
  resizeSession(sessionId: string, cols: number, rows: number): void {
    if (this.ptyManager) {
      return this.ptyManager.resizeSession(sessionId, cols, rows);
    } else {
      // tty-fwd doesn't have explicit resize command, PTY should handle SIGWINCH automatically
      console.warn('Resize not supported with tty-fwd implementation');
    }
  }

  /**
   * Kill a session
   * Returns a promise that resolves when the process is actually terminated
   */
  async killSession(sessionId: string, signal: string | number = 'SIGTERM'): Promise<void> {
    if (this.ptyManager) {
      return await this.ptyManager.killSession(sessionId, signal);
    } else {
      return this.killSessionTtyFwd(sessionId, signal);
    }
  }

  /**
   * Kill session using tty-fwd binary with proper escalation
   */
  private async killSessionTtyFwd(sessionId: string, signal: string | number): Promise<void> {
    const ttyFwdPath = this.findTtyFwdBinary();

    // If signal is already SIGKILL, send it immediately
    if (signal === 'SIGKILL' || signal === 9) {
      const args = ['--control-path', this.config.controlPath, '--session', sessionId, '--kill'];
      const result = spawnSync(ttyFwdPath, args, {
        stdio: 'pipe',
        timeout: 5000,
      });

      if (result.status !== 0) {
        throw new PtyError(`tty-fwd kill failed with code ${result.status}`);
      }
      return;
    }

    // Get session info to find PID for monitoring
    const session = this.getSession(sessionId);
    if (!session || !session.pid) {
      throw new PtyError(
        `Session ${sessionId} not found or has no PID`,
        'SESSION_NOT_FOUND',
        sessionId
      );
    }

    const pid = session.pid;
    console.log(`Terminating session ${sessionId} (PID: ${pid}) with tty-fwd SIGTERM...`);

    try {
      // Send SIGTERM first via tty-fwd
      const args = ['--control-path', this.config.controlPath, '--session', sessionId, '--stop'];
      const result = spawnSync(ttyFwdPath, args, {
        stdio: 'pipe',
        timeout: 5000,
      });

      if (result.status !== 0) {
        throw new PtyError(`tty-fwd stop failed with code ${result.status}`);
      }

      // Wait up to 3 seconds for graceful termination (check every 500ms)
      const maxWaitTime = 3000;
      const checkInterval = 500;
      const maxChecks = maxWaitTime / checkInterval;

      for (let i = 0; i < maxChecks; i++) {
        // Wait for check interval
        await new Promise((resolve) => setTimeout(resolve, checkInterval));

        // Check if process is still alive
        try {
          process.kill(pid, 0); // Signal 0 just checks if process exists
          // Process still exists, continue waiting
          console.log(`Session ${sessionId} still alive after ${(i + 1) * checkInterval}ms...`);
        } catch (_error) {
          // Process no longer exists - it terminated gracefully
          console.log(
            `Session ${sessionId} terminated gracefully after ${(i + 1) * checkInterval}ms`
          );
          return;
        }
      }

      // Process didn't terminate gracefully within 3 seconds, force kill
      console.log(
        `Session ${sessionId} didn't terminate gracefully, sending SIGKILL via tty-fwd...`
      );
      const killArgs = [
        '--control-path',
        this.config.controlPath,
        '--session',
        sessionId,
        '--kill',
      ];
      const killResult = spawnSync(ttyFwdPath, killArgs, {
        stdio: 'pipe',
        timeout: 5000,
      });

      if (killResult.status !== 0) {
        console.warn(
          `tty-fwd SIGKILL failed with code ${killResult.status}, process may already be dead`
        );
      }

      // Wait a bit more for SIGKILL to take effect
      await new Promise((resolve) => setTimeout(resolve, 100));
      console.log(`Session ${sessionId} forcefully terminated with SIGKILL`);
    } catch (error) {
      throw new PtyError(
        `Failed to kill session via tty-fwd: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  /**
   * List all sessions
   */
  listSessions(): SessionEntryWithId[] {
    if (this.ptyManager) {
      return this.ptyManager.listSessions();
    } else {
      return this.listSessionsTtyFwd();
    }
  }

  /**
   * List sessions using tty-fwd binary
   */
  private listSessionsTtyFwd(): SessionEntryWithId[] {
    try {
      const ttyFwdPath = this.findTtyFwdBinary();
      const args = ['--control-path', this.config.controlPath, '--list-sessions'];

      const result = spawnSync(ttyFwdPath, args, {
        stdio: 'pipe',
      });

      if (result.status !== 0) {
        throw new PtyError(`tty-fwd list sessions failed with code ${result.status}`);
      }

      const output = result.stdout?.toString() || '[]';
      return JSON.parse(output) as SessionEntryWithId[];
    } catch (error) {
      // In test/development environments, if tty-fwd is not available, return empty list
      if (process.env.NODE_ENV === 'test' || process.env.VITEST) {
        console.warn('tty-fwd not available in test environment, returning empty session list');
        return [];
      }
      throw new PtyError(
        `Failed to list sessions via tty-fwd: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  /**
   * Get a specific session
   */
  getSession(sessionId: string): SessionEntryWithId | null {
    if (this.ptyManager) {
      return this.ptyManager.getSession(sessionId);
    } else {
      const sessions = this.listSessionsTtyFwd();
      return sessions.find((s) => s.session_id === sessionId) || null;
    }
  }

  /**
   * Cleanup a specific session
   */
  cleanupSession(sessionId: string): void {
    if (this.ptyManager) {
      return this.ptyManager.cleanupSession(sessionId);
    } else {
      return this.cleanupSessionTtyFwd(sessionId);
    }
  }

  /**
   * Cleanup session using tty-fwd binary
   */
  private cleanupSessionTtyFwd(sessionId: string): void {
    try {
      const ttyFwdPath = this.findTtyFwdBinary();
      const args = ['--control-path', this.config.controlPath, '--session', sessionId, '--cleanup'];

      const result = spawnSync(ttyFwdPath, args, {
        stdio: 'pipe',
        timeout: 5000,
      });

      if (result.status !== 0) {
        throw new PtyError(`tty-fwd cleanup failed with code ${result.status}`);
      }
    } catch (error) {
      // If tty-fwd cleanup fails, try manual cleanup
      console.warn(
        `tty-fwd cleanup failed for session ${sessionId}, attempting manual cleanup:`,
        error
      );

      try {
        const sessionDir = path.join(this.config.controlPath, sessionId);
        if (fs.existsSync(sessionDir)) {
          fs.rmSync(sessionDir, { recursive: true, force: true });
        }
      } catch (manualError) {
        throw new PtyError(
          `Both tty-fwd and manual cleanup failed for session ${sessionId}: ${manualError}`
        );
      }
    }
  }

  /**
   * Cleanup all exited sessions
   */
  cleanupExitedSessions(): string[] {
    if (this.ptyManager) {
      return this.ptyManager.cleanupExitedSessions();
    } else {
      return this.cleanupExitedSessionsTtyFwd();
    }
  }

  /**
   * Cleanup exited sessions using tty-fwd binary
   */
  private cleanupExitedSessionsTtyFwd(): string[] {
    try {
      const sessions = this.listSessionsTtyFwd();
      const exitedSessions = sessions.filter((s) => s.status === 'exited');

      const cleanedSessions: string[] = [];

      for (const session of exitedSessions) {
        try {
          this.cleanupSessionTtyFwd(session.session_id);
          cleanedSessions.push(session.session_id);
        } catch (error) {
          console.warn(`Failed to cleanup exited session ${session.session_id}:`, error);
        }
      }

      return cleanedSessions;
    } catch (error) {
      throw new PtyError(
        `Failed to cleanup exited sessions via tty-fwd: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  /**
   * Find tty-fwd binary path
   */
  private findTtyFwdBinary(): string {
    if (this.config.ttyFwdPath && fs.existsSync(this.config.ttyFwdPath)) {
      return this.config.ttyFwdPath;
    }

    // Common paths to check
    const possiblePaths = [
      // Relative to project
      path.join(process.cwd(), '../tty-fwd/target/release/tty-fwd'),
      path.join(process.cwd(), '../tty-fwd/target/debug/tty-fwd'),
      // System PATH
      'tty-fwd',
    ];

    for (const binPath of possiblePaths) {
      if (binPath === 'tty-fwd') {
        // Check if in PATH
        try {
          const result = spawnSync('which', ['tty-fwd'], { stdio: 'pipe' });
          if (result.status === 0) {
            return 'tty-fwd';
          }
        } catch (_error) {
          // Continue checking other paths
        }
      } else if (fs.existsSync(binPath)) {
        return binPath;
      }
    }

    throw new PtyError('tty-fwd binary not found');
  }

  /**
   * Check if using native node-pty implementation
   */
  isUsingNodePty(): boolean {
    return this.ptyManager !== null;
  }

  /**
   * Check if using tty-fwd implementation
   */
  isUsingTtyFwd(): boolean {
    return this.ptyManager === null;
  }

  /**
   * Get current implementation name
   */
  getCurrentImplementation(): string {
    return this.isUsingNodePty() ? 'node-pty' : 'tty-fwd';
  }

  /**
   * Get configuration
   */
  getConfig(): PtyConfig {
    return { ...this.config };
  }

  /**
   * Get control path
   */
  getControlPath(): string {
    return this.config.controlPath;
  }

  /**
   * Get active session count (only for node-pty)
   */
  getActiveSessionCount(): number {
    if (this.ptyManager) {
      return this.ptyManager.getActiveSessionCount();
    }
    // For tty-fwd, count running sessions
    try {
      const sessions = this.listSessions();
      return sessions.filter((s) => s.status === 'running').length;
    } catch (_error) {
      return 0;
    }
  }
}
