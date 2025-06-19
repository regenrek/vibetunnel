/**
 * SessionManager - Handles session persistence and file system operations
 *
 * This class manages the session directory structure, metadata persistence,
 * and file operations to maintain compatibility with tty-fwd format.
 */

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { SessionInfo, SessionEntryWithId, PtyError } from './types.js';
import { ProcessUtils } from './ProcessUtils.js';

export class SessionManager {
  private controlPath: string;

  constructor(controlPath?: string) {
    this.controlPath = controlPath || path.join(os.homedir(), '.vibetunnel', 'control');
    this.ensureControlDirectory();
  }

  /**
   * Ensure the control directory exists
   */
  private ensureControlDirectory(): void {
    if (!fs.existsSync(this.controlPath)) {
      fs.mkdirSync(this.controlPath, { recursive: true });
    }
  }

  /**
   * Create a new session directory structure
   */
  createSessionDirectory(sessionId: string): {
    controlDir: string;
    streamOutPath: string;
    stdinPath: string;
    notificationPath: string;
    sessionJsonPath: string;
  } {
    const controlDir = path.join(this.controlPath, sessionId);

    // Create session directory
    if (!fs.existsSync(controlDir)) {
      fs.mkdirSync(controlDir, { recursive: true });
    }

    const streamOutPath = path.join(controlDir, 'stream-out');
    const stdinPath = path.join(controlDir, 'stdin');
    const notificationPath = path.join(controlDir, 'notification-stream');
    const sessionJsonPath = path.join(controlDir, 'session.json');

    // Create FIFO pipe for stdin (or regular file on systems without mkfifo)
    this.createStdinPipe(stdinPath);

    return {
      controlDir,
      streamOutPath,
      stdinPath,
      notificationPath,
      sessionJsonPath,
    };
  }

  /**
   * Create stdin pipe (FIFO if possible, regular file otherwise)
   */
  private createStdinPipe(stdinPath: string): void {
    try {
      // Try to create FIFO pipe (Unix-like systems)
      if (process.platform !== 'win32') {
        const { spawnSync } = require('child_process');
        const result = spawnSync('mkfifo', [stdinPath], { stdio: 'ignore' });
        if (result.status === 0) {
          return; // Successfully created FIFO
        }
      }

      // Fallback to regular file
      if (!fs.existsSync(stdinPath)) {
        fs.writeFileSync(stdinPath, '');
      }
    } catch (_error) {
      // If mkfifo fails, create regular file
      if (!fs.existsSync(stdinPath)) {
        fs.writeFileSync(stdinPath, '');
      }
    }
  }

  /**
   * Save session info to JSON file
   */
  saveSessionInfo(sessionJsonPath: string, sessionInfo: SessionInfo): void {
    try {
      const sessionInfoStr = JSON.stringify(sessionInfo, null, 2);

      // Write to temporary file first, then move to final location (atomic write)
      const tempPath = sessionJsonPath + '.tmp';
      fs.writeFileSync(tempPath, sessionInfoStr, 'utf8');
      fs.renameSync(tempPath, sessionJsonPath);
    } catch (error) {
      throw new PtyError(
        `Failed to save session info: ${error instanceof Error ? error.message : String(error)}`,
        'SAVE_SESSION_FAILED'
      );
    }
  }

  /**
   * Load session info from JSON file
   */
  loadSessionInfo(sessionJsonPath: string): SessionInfo | null {
    try {
      if (!fs.existsSync(sessionJsonPath)) {
        return null;
      }

      const content = fs.readFileSync(sessionJsonPath, 'utf8');
      return JSON.parse(content) as SessionInfo;
    } catch (error) {
      console.warn(`Failed to load session info from ${sessionJsonPath}:`, error);
      return null;
    }
  }

  /**
   * Update session status
   */
  updateSessionStatus(
    sessionJsonPath: string,
    status: string,
    pid?: number,
    exitCode?: number
  ): void {
    const sessionInfo = this.loadSessionInfo(sessionJsonPath);
    if (!sessionInfo) {
      throw new PtyError('Session info not found', 'SESSION_NOT_FOUND');
    }

    if (pid !== undefined) {
      sessionInfo.pid = pid;
    }
    sessionInfo.status = status as 'starting' | 'running' | 'exited';
    if (exitCode !== undefined) {
      sessionInfo.exit_code = exitCode;
    }

    this.saveSessionInfo(sessionJsonPath, sessionInfo);
  }

  /**
   * List all sessions
   */
  listSessions(): SessionEntryWithId[] {
    try {
      if (!fs.existsSync(this.controlPath)) {
        return [];
      }

      const sessions: SessionEntryWithId[] = [];
      const entries = fs.readdirSync(this.controlPath, { withFileTypes: true });

      for (const entry of entries) {
        if (entry.isDirectory()) {
          const sessionId = entry.name;
          const sessionDir = path.join(this.controlPath, sessionId);
          const sessionJsonPath = path.join(sessionDir, 'session.json');

          const sessionInfo = this.loadSessionInfo(sessionJsonPath);
          if (sessionInfo) {
            // Determine waiting state for running processes
            let waiting = false;
            if (sessionInfo.status === 'running' && sessionInfo.pid) {
              const processStatus = this.getProcessStatus(sessionInfo.pid);
              waiting = processStatus.isWaiting;

              // Update status if process is no longer alive
              if (!processStatus.isAlive) {
                sessionInfo.status = 'exited';
                if (sessionInfo.exit_code === undefined) {
                  sessionInfo.exit_code = 1; // Default exit code for dead processes
                }
                this.saveSessionInfo(sessionJsonPath, sessionInfo);
              }
            }

            const sessionEntry: SessionEntryWithId = {
              session_id: sessionId,
              ...sessionInfo,
              'stream-out': path.join(sessionDir, 'stream-out'),
              stdin: path.join(sessionDir, 'stdin'),
              'notification-stream': path.join(sessionDir, 'notification-stream'),
              waiting,
            };

            sessions.push(sessionEntry);
          }
        }
      }

      // Sort by started_at timestamp (newest first)
      sessions.sort((a, b) => {
        const aTime = a.started_at ? new Date(a.started_at).getTime() : 0;
        const bTime = b.started_at ? new Date(b.started_at).getTime() : 0;
        return bTime - aTime;
      });

      return sessions;
    } catch (error) {
      throw new PtyError(
        `Failed to list sessions: ${error instanceof Error ? error.message : String(error)}`,
        'LIST_SESSIONS_FAILED'
      );
    }
  }

  /**
   * Get a specific session by ID
   */
  getSession(sessionId: string): SessionEntryWithId | null {
    const sessions = this.listSessions();
    return sessions.find((s) => s.session_id === sessionId) || null;
  }

  /**
   * Check if a session exists
   */
  sessionExists(sessionId: string): boolean {
    const sessionDir = path.join(this.controlPath, sessionId);
    const sessionJsonPath = path.join(sessionDir, 'session.json');
    return fs.existsSync(sessionJsonPath);
  }

  /**
   * Cleanup a specific session
   */
  cleanupSession(sessionId: string): void {
    try {
      const sessionDir = path.join(this.controlPath, sessionId);

      if (fs.existsSync(sessionDir)) {
        // Remove directory and all contents
        fs.rmSync(sessionDir, { recursive: true, force: true });
      }
    } catch (error) {
      throw new PtyError(
        `Failed to cleanup session ${sessionId}: ${error instanceof Error ? error.message : String(error)}`,
        'CLEANUP_FAILED',
        sessionId
      );
    }
  }

  /**
   * Cleanup all exited sessions
   */
  cleanupExitedSessions(): string[] {
    const cleanedSessions: string[] = [];

    try {
      const sessions = this.listSessions();

      for (const session of sessions) {
        if (session.status === 'exited') {
          this.cleanupSession(session.session_id);
          cleanedSessions.push(session.session_id);
        }
      }

      return cleanedSessions;
    } catch (error) {
      throw new PtyError(
        `Failed to cleanup exited sessions: ${error instanceof Error ? error.message : String(error)}`,
        'CLEANUP_EXITED_FAILED'
      );
    }
  }

  /**
   * Get session paths for a given session ID
   */
  getSessionPaths(sessionId: string): {
    controlDir: string;
    streamOutPath: string;
    stdinPath: string;
    notificationPath: string;
    sessionJsonPath: string;
  } | null {
    const sessionDir = path.join(this.controlPath, sessionId);

    if (!fs.existsSync(sessionDir)) {
      return null;
    }

    return {
      controlDir: sessionDir,
      streamOutPath: path.join(sessionDir, 'stream-out'),
      stdinPath: path.join(sessionDir, 'stdin'),
      notificationPath: path.join(sessionDir, 'notification-stream'),
      sessionJsonPath: path.join(sessionDir, 'session.json'),
    };
  }

  /**
   * Write to stdin pipe/file
   */
  writeToStdin(sessionId: string, data: string): void {
    const paths = this.getSessionPaths(sessionId);
    if (!paths) {
      throw new PtyError(`Session ${sessionId} not found`, 'SESSION_NOT_FOUND', sessionId);
    }

    try {
      // For FIFO pipes, we need to open in append mode
      // For regular files, we also use append mode to avoid conflicts
      fs.appendFileSync(paths.stdinPath, data);
    } catch (error) {
      throw new PtyError(
        `Failed to write to stdin for session ${sessionId}: ${error instanceof Error ? error.message : String(error)}`,
        'STDIN_WRITE_FAILED',
        sessionId
      );
    }
  }

  /**
   * Check if a process is still running
   * Uses cross-platform process detection for reliability
   */
  isProcessRunning(pid: number): boolean {
    return ProcessUtils.isProcessRunning(pid);
  }

  /**
   * Get detailed process status like tty-fwd does
   */
  getProcessStatus(pid: number): { isAlive: boolean; isWaiting: boolean } {
    try {
      // First check if process exists using cross-platform method
      if (!ProcessUtils.isProcessRunning(pid)) {
        return { isAlive: false, isWaiting: false };
      }

      // Use ps command to get process state like tty-fwd does (Unix only)
      if (process.platform === 'win32') {
        // On Windows, we can't easily get process state, so assume running
        return { isAlive: true, isWaiting: false };
      }

      const { spawnSync } = require('child_process');
      const result = spawnSync('ps', ['-p', pid.toString(), '-o', 'stat='], {
        encoding: 'utf8',
        stdio: 'pipe',
      });

      if (result.status === 0 && result.stdout) {
        const stat = result.stdout.trim();

        // Check if it's a zombie process (status starts with 'Z')
        const isZombie = stat.startsWith('Z');
        const isAlive = !isZombie;

        // Determine if waiting vs running based on process state
        // Common Unix process states:
        // R = Running or runnable (on run queue)
        // S = Interruptible sleep (waiting for an event)
        // D = Uninterruptible sleep (usually IO)
        // T = Stopped (on a signal or being traced)
        // Z = Zombie (terminated but not reaped)

        // For terminal sessions, only consider these as truly "waiting":
        // D = Uninterruptible sleep (usually blocked on I/O)
        // T = Stopped/traced (paused by signal)
        // Note: 'S' state is normal for interactive shells waiting for input
        const isWaiting = stat.includes('D') || stat.includes('T');

        return { isAlive, isWaiting };
      }

      // If ps command failed, process probably doesn't exist
      return { isAlive: false, isWaiting: false };
    } catch (_error) {
      // Process doesn't exist or no permission
      return { isAlive: false, isWaiting: false };
    }
  }

  /**
   * Update sessions that have zombie processes
   */
  updateZombieSessions(): string[] {
    const updatedSessions: string[] = [];

    try {
      const sessions = this.listSessions();

      for (const session of sessions) {
        if (session.status === 'running' && session.pid) {
          if (!this.isProcessRunning(session.pid)) {
            // Process is dead, update status
            const paths = this.getSessionPaths(session.session_id);
            if (paths) {
              this.updateSessionStatus(paths.sessionJsonPath, 'exited', undefined, 1);
              updatedSessions.push(session.session_id);
            }
          }
        }
      }

      return updatedSessions;
    } catch (error) {
      console.warn('Failed to update zombie sessions:', error);
      return [];
    }
  }

  /**
   * Get control path
   */
  getControlPath(): string {
    return this.controlPath;
  }
}
