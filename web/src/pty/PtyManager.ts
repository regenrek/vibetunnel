/**
 * PtyManager - Core PTY management using node-pty
 *
 * This class handles PTY creation, process management, and I/O operations
 * using the node-pty library while maintaining compatibility with tty-fwd.
 */

import * as pty from '@homebridge/node-pty-prebuilt-multiarch';
import { v4 as uuidv4 } from 'uuid';
import * as path from 'path';
import * as fs from 'fs';
import { onExit } from 'signal-exit';
import {
  SessionInfo,
  SessionOptions,
  PtySession,
  SessionCreationResult,
  SessionInput,
  SpecialKey,
  PtyError,
} from './types.js';
import { AsciinemaWriter } from './AsciinemaWriter.js';
import { SessionManager } from './SessionManager.js';
import { ProcessUtils } from './ProcessUtils.js';

export class PtyManager {
  private sessions = new Map<string, PtySession>();
  private sessionManager: SessionManager;
  private defaultTerm = 'xterm-256color';
  private cleanupRegistered = false;

  constructor(controlPath?: string) {
    this.sessionManager = new SessionManager(controlPath);
    this.registerCleanupHandlers();
  }

  /**
   * Register cleanup handlers for graceful shutdown
   */
  private registerCleanupHandlers(): void {
    if (this.cleanupRegistered) return;

    try {
      onExit(() => {
        console.log('PTY Manager shutting down, cleaning up sessions...');
        this.cleanup();
      });
    } catch (error) {
      console.warn('Failed to register signal-exit handler:', error);
      // Fallback to basic process event handlers
      process.on('SIGINT', () => {
        console.log('PTY Manager shutting down (SIGINT), cleaning up sessions...');
        this.cleanup();
        process.exit(0);
      });

      process.on('SIGTERM', () => {
        console.log('PTY Manager shutting down (SIGTERM), cleaning up sessions...');
        this.cleanup();
        process.exit(0);
      });
    }

    this.cleanupRegistered = true;
  }

  /**
   * Create a new PTY session
   */
  async createSession(
    command: string[],
    options: SessionOptions = {}
  ): Promise<SessionCreationResult> {
    const sessionId = options.sessionId || uuidv4();
    const sessionName = options.sessionName || path.basename(command[0]);
    const workingDir = options.workingDir || process.cwd();
    const term = options.term || this.defaultTerm;
    const cols = options.cols || 80;
    const rows = options.rows || 24;

    try {
      // Create session directory structure
      const paths = this.sessionManager.createSessionDirectory(sessionId);

      // Create initial session info
      const sessionInfo: SessionInfo = {
        cmdline: command,
        name: sessionName,
        cwd: workingDir,
        status: 'starting',
        started_at: new Date().toISOString(),
        term,
        spawn_type: 'pty',
      };

      // Save initial session info
      this.sessionManager.saveSessionInfo(paths.sessionJsonPath, sessionInfo);

      // Create asciinema writer
      const asciinemaWriter = AsciinemaWriter.create(
        paths.streamOutPath,
        cols,
        rows,
        command.join(' '),
        sessionName,
        this.createEnvVars(term)
      );

      // Create PTY process
      const ptyProcess = pty.spawn(command[0], command.slice(1), {
        name: term,
        cols,
        rows,
        cwd: workingDir,
        env: {
          ...process.env,
          TERM: term,
        },
      });

      // Create session object
      const session: PtySession = {
        id: sessionId,
        sessionInfo,
        ptyProcess,
        asciinemaWriter,
        controlDir: paths.controlDir,
        streamOutPath: paths.streamOutPath,
        stdinPath: paths.stdinPath,
        notificationPath: paths.notificationPath,
        sessionJsonPath: paths.sessionJsonPath,
        startTime: new Date(),
      };

      this.sessions.set(sessionId, session);

      // Update session info with PID and running status
      sessionInfo.pid = ptyProcess.pid;
      sessionInfo.status = 'running';
      this.sessionManager.saveSessionInfo(paths.sessionJsonPath, sessionInfo);

      // Setup PTY event handlers
      this.setupPtyHandlers(session);

      return {
        sessionId,
        sessionInfo,
      };
    } catch (error) {
      // Cleanup on failure
      try {
        this.sessionManager.cleanupSession(sessionId);
      } catch (cleanupError) {
        console.warn(
          `Failed to cleanup session ${sessionId} after creation failure:`,
          cleanupError
        );
      }

      throw new PtyError(
        `Failed to create session: ${error instanceof Error ? error.message : String(error)}`,
        'SESSION_CREATE_FAILED'
      );
    }
  }

  /**
   * Setup event handlers for a PTY process
   */
  private setupPtyHandlers(session: PtySession): void {
    const { ptyProcess, asciinemaWriter, sessionJsonPath } = session;

    // Handle PTY data output
    ptyProcess.onData((data: string) => {
      try {
        // Write to asciinema file
        asciinemaWriter?.writeOutput(Buffer.from(data, 'utf8'));
      } catch (error) {
        console.error(`Error writing PTY data for session ${session.id}:`, error);
      }
    });

    // Handle PTY exit
    ptyProcess.onExit(({ exitCode, signal }: { exitCode: number; signal?: number }) => {
      try {
        console.log(`Session ${session.id} exited with code ${exitCode}, signal ${signal}`);

        // Write exit event to asciinema
        if (asciinemaWriter?.isOpen()) {
          asciinemaWriter.writeRawJson(['exit', exitCode || 0, session.id]);
          asciinemaWriter.close().catch(console.error);
        }

        // Update session status
        this.sessionManager.updateSessionStatus(
          sessionJsonPath,
          'exited',
          undefined,
          exitCode || (signal ? 128 + (typeof signal === 'number' ? signal : 1) : 1)
        );

        // Remove from active sessions
        this.sessions.delete(session.id);
      } catch (_error) {
        console.error(`Error handling exit for session ${session.id}:`, _error);
      }
    });

    // Handle resize events
    ptyProcess.onResize?.(({ cols, rows }: { cols: number; rows: number }) => {
      try {
        asciinemaWriter?.writeResize(cols, rows);
      } catch (error) {
        console.error(`Error writing resize event for session ${session.id}:`, error);
      }
    });

    // Monitor stdin file for input
    this.monitorStdinFile(session);
  }

  /**
   * Monitor stdin file for input data
   */
  private monitorStdinFile(session: PtySession): void {
    // Use fs.watchFile for basic file monitoring
    // This is a simple implementation - could be enhanced with chokidar for better performance
    let lastSize = 0;

    const checkStdin = () => {
      try {
        if (!fs.existsSync(session.stdinPath)) return;

        const stats = fs.statSync(session.stdinPath);
        if (stats.size > lastSize) {
          // Read new data
          const fd = fs.openSync(session.stdinPath, 'r');
          const buffer = Buffer.alloc(stats.size - lastSize);
          const bytesRead = fs.readSync(fd, buffer, 0, buffer.length, lastSize);
          fs.closeSync(fd);

          if (bytesRead > 0) {
            const data = buffer.subarray(0, bytesRead).toString('utf8');
            session.ptyProcess?.write(data);
            session.asciinemaWriter?.writeInput(data);
          }

          lastSize = stats.size;
        }
      } catch (_error) {
        // File might not exist or be readable, ignore
      }
    };

    // Check every 100ms for stdin input
    const interval = setInterval(checkStdin, 100);

    // Clean up interval when session ends
    session.ptyProcess?.onExit(() => {
      clearInterval(interval);
    });
  }

  /**
   * Send text input to a session
   */
  sendInput(sessionId: string, input: SessionInput): void {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new PtyError(`Session ${sessionId} not found`, 'SESSION_NOT_FOUND', sessionId);
    }

    if (!session.ptyProcess) {
      throw new PtyError(`Session ${sessionId} has no active PTY`, 'NO_ACTIVE_PTY', sessionId);
    }

    try {
      let dataToSend = '';

      if (input.text !== undefined) {
        dataToSend = input.text;
      } else if (input.key !== undefined) {
        dataToSend = this.convertSpecialKey(input.key);
      } else {
        throw new PtyError('No text or key specified in input', 'INVALID_INPUT');
      }

      // Send to PTY
      session.ptyProcess.write(dataToSend);

      // Record input in asciinema
      session.asciinemaWriter?.writeInput(dataToSend);
    } catch (error) {
      throw new PtyError(
        `Failed to send input to session ${sessionId}: ${error instanceof Error ? error.message : String(error)}`,
        'SEND_INPUT_FAILED',
        sessionId
      );
    }
  }

  /**
   * Convert special key names to escape sequences
   */
  private convertSpecialKey(key: SpecialKey): string {
    const keyMap: Record<SpecialKey, string> = {
      arrow_up: '\x1b[A',
      arrow_down: '\x1b[B',
      arrow_right: '\x1b[C',
      arrow_left: '\x1b[D',
      escape: '\x1b',
      enter: '\r',
      ctrl_enter: '\n',
      shift_enter: '\r\n',
    };

    const sequence = keyMap[key];
    if (!sequence) {
      throw new PtyError(`Unknown special key: ${key}`, 'UNKNOWN_KEY');
    }

    return sequence;
  }

  /**
   * Resize a session terminal
   */
  resizeSession(sessionId: string, cols: number, rows: number): void {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new PtyError(`Session ${sessionId} not found`, 'SESSION_NOT_FOUND', sessionId);
    }

    if (!session.ptyProcess) {
      throw new PtyError(`Session ${sessionId} has no active PTY`, 'NO_ACTIVE_PTY', sessionId);
    }

    try {
      session.ptyProcess.resize(cols, rows);
      session.asciinemaWriter?.writeResize(cols, rows);
    } catch (error) {
      throw new PtyError(
        `Failed to resize session ${sessionId}: ${error instanceof Error ? error.message : String(error)}`,
        'RESIZE_FAILED',
        sessionId
      );
    }
  }

  /**
   * Kill a session with proper SIGTERM -> SIGKILL escalation
   * Returns a promise that resolves when the process is actually terminated
   */
  async killSession(sessionId: string, signal: string | number = 'SIGTERM'): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new PtyError(`Session ${sessionId} not found`, 'SESSION_NOT_FOUND', sessionId);
    }

    try {
      if (session.ptyProcess) {
        // If signal is already SIGKILL, send it immediately and wait briefly
        if (signal === 'SIGKILL' || signal === 9) {
          session.ptyProcess.kill('SIGKILL');
          this.sessions.delete(sessionId);
          // Wait a bit for SIGKILL to take effect
          await new Promise((resolve) => setTimeout(resolve, 100));
          return;
        }

        // Start with SIGTERM and escalate if needed
        await this.killSessionWithEscalation(sessionId, session);
      } else {
        // No PTY process, just remove from sessions
        this.sessions.delete(sessionId);
      }
    } catch (error) {
      throw new PtyError(
        `Failed to kill session ${sessionId}: ${error instanceof Error ? error.message : String(error)}`,
        'KILL_FAILED',
        sessionId
      );
    }
  }

  /**
   * Kill session with SIGTERM -> SIGKILL escalation (3 seconds, check every 500ms)
   */
  private async killSessionWithEscalation(sessionId: string, session: PtySession): Promise<void> {
    if (!session.ptyProcess) {
      this.sessions.delete(sessionId);
      return;
    }

    const pid = session.ptyProcess.pid;
    console.log(`Terminating session ${sessionId} (PID: ${pid}) with SIGTERM...`);

    try {
      // Send SIGTERM first
      session.ptyProcess.kill('SIGTERM');

      // Wait up to 3 seconds for graceful termination (check every 500ms)
      const maxWaitTime = 3000;
      const checkInterval = 500;
      const maxChecks = maxWaitTime / checkInterval;

      for (let i = 0; i < maxChecks; i++) {
        // Wait for check interval
        await new Promise((resolve) => setTimeout(resolve, checkInterval));

        // Check if process is still alive
        if (!ProcessUtils.isProcessRunning(pid)) {
          // Process no longer exists - it terminated gracefully
          console.log(
            `Session ${sessionId} terminated gracefully after ${(i + 1) * checkInterval}ms`
          );
          this.sessions.delete(sessionId);
          return;
        }

        // Process still exists, continue waiting
        console.log(`Session ${sessionId} still alive after ${(i + 1) * checkInterval}ms...`);
      }

      // Process didn't terminate gracefully within 3 seconds, force kill
      console.log(`Session ${sessionId} didn't terminate gracefully, sending SIGKILL...`);
      try {
        session.ptyProcess.kill('SIGKILL');
        // Wait a bit more for SIGKILL to take effect
        await new Promise((resolve) => setTimeout(resolve, 100));
      } catch (_killError) {
        // Process might have died between our check and SIGKILL
        console.log(`SIGKILL failed for session ${sessionId}, process likely already dead`);
      }

      // Remove from sessions regardless
      this.sessions.delete(sessionId);
      console.log(`Session ${sessionId} forcefully terminated with SIGKILL`);
    } catch (error) {
      // Remove from sessions even if kill failed
      this.sessions.delete(sessionId);
      throw new PtyError(
        `Failed to terminate session ${sessionId}: ${error instanceof Error ? error.message : String(error)}`,
        'KILL_FAILED',
        sessionId
      );
    }
  }

  /**
   * List all sessions (both active and persisted)
   */
  listSessions() {
    // Update zombie sessions first
    this.sessionManager.updateZombieSessions();

    // Return all sessions from storage
    return this.sessionManager.listSessions();
  }

  /**
   * Get a specific session
   */
  getSession(sessionId: string) {
    return this.sessionManager.getSession(sessionId);
  }

  /**
   * Cleanup a specific session
   */
  cleanupSession(sessionId: string): void {
    // Kill active session if exists (fire-and-forget for cleanup)
    if (this.sessions.has(sessionId)) {
      this.killSession(sessionId).catch((error) => {
        console.error(`Error killing session ${sessionId} during cleanup:`, error);
      });
    }

    // Remove from storage
    this.sessionManager.cleanupSession(sessionId);
  }

  /**
   * Cleanup all exited sessions
   */
  cleanupExitedSessions(): string[] {
    return this.sessionManager.cleanupExitedSessions();
  }

  /**
   * Create environment variables for sessions
   */
  private createEnvVars(term: string): Record<string, string> {
    const envVars: Record<string, string> = {
      TERM: term,
    };

    // Include other important terminal-related environment variables if they exist
    const importantVars = ['SHELL', 'LANG', 'LC_ALL', 'PATH', 'USER', 'HOME'];
    for (const varName of importantVars) {
      const value = process.env[varName];
      if (value) {
        envVars[varName] = value;
      }
    }

    return envVars;
  }

  /**
   * Get active session count
   */
  getActiveSessionCount(): number {
    return this.sessions.size;
  }

  /**
   * Check if a session is active (has running PTY)
   */
  isSessionActive(sessionId: string): boolean {
    return this.sessions.has(sessionId);
  }

  /**
   * Cleanup all active sessions
   */
  private cleanup(): void {
    console.log(`Cleaning up ${this.sessions.size} active sessions...`);

    for (const [sessionId, session] of Array.from(this.sessions.entries())) {
      try {
        if (session.ptyProcess) {
          session.ptyProcess.kill();
        }
        if (session.asciinemaWriter?.isOpen()) {
          session.asciinemaWriter.close().catch(console.error);
        }
      } catch (error) {
        console.error(`Error cleaning up session ${sessionId}:`, error);
      }
    }

    this.sessions.clear();
  }

  /**
   * Get session manager instance
   */
  getSessionManager(): SessionManager {
    return this.sessionManager;
  }
}
