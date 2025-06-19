/**
 * ProcessUtils - Cross-platform process management utilities
 *
 * Provides reliable process existence checking across Windows, macOS, and Linux.
 */

import { spawnSync } from 'child_process';

export class ProcessUtils {
  /**
   * Check if a process is currently running by PID
   * Uses platform-appropriate methods for reliable detection
   */
  static isProcessRunning(pid: number): boolean {
    if (!pid || pid <= 0) {
      return false;
    }

    try {
      if (process.platform === 'win32') {
        // Windows: Use tasklist command
        return ProcessUtils.isProcessRunningWindows(pid);
      } else {
        // Unix/Linux/macOS: Use kill with signal 0
        return ProcessUtils.isProcessRunningUnix(pid);
      }
    } catch (error) {
      console.warn(`Error checking if process ${pid} is running:`, error);
      return false;
    }
  }

  /**
   * Windows-specific process check using tasklist
   */
  private static isProcessRunningWindows(pid: number): boolean {
    try {
      const result = spawnSync('tasklist', ['/FI', `PID eq ${pid}`, '/NH', '/FO', 'CSV'], {
        encoding: 'utf8',
        windowsHide: true,
        timeout: 5000, // 5 second timeout
      });

      // Check if the command succeeded and PID appears in output
      if (result.status === 0 && result.stdout) {
        // tasklist outputs CSV format with PID in quotes
        return result.stdout.includes(`"${pid}"`);
      }

      return false;
    } catch (error) {
      console.warn(`Windows process check failed for PID ${pid}:`, error);
      return false;
    }
  }

  /**
   * Unix-like systems process check using kill signal 0
   */
  private static isProcessRunningUnix(pid: number): boolean {
    try {
      // Send signal 0 to check if process exists
      // This doesn't actually kill the process, just checks existence
      process.kill(pid, 0);
      return true;
    } catch (error) {
      // If we get ESRCH, the process doesn't exist
      // If we get EPERM, the process exists but we don't have permission
      const err = error as NodeJS.ErrnoException;
      if (err.code === 'EPERM') {
        // Process exists but we don't have permission to signal it
        return true;
      }
      // ESRCH or other errors mean process doesn't exist
      return false;
    }
  }

  /**
   * Get basic process information if available
   * Returns null if process is not running or info cannot be retrieved
   */
  static getProcessInfo(pid: number): { pid: number; exists: boolean } | null {
    if (!ProcessUtils.isProcessRunning(pid)) {
      return null;
    }

    return {
      pid,
      exists: true,
    };
  }

  /**
   * Kill a process with platform-appropriate method
   * Returns true if the kill signal was sent successfully
   */
  static killProcess(pid: number, signal: NodeJS.Signals | number = 'SIGTERM'): boolean {
    if (!pid || pid <= 0) {
      return false;
    }

    try {
      if (process.platform === 'win32') {
        // Windows: Use taskkill command for more reliable termination
        const result = spawnSync('taskkill', ['/PID', pid.toString(), '/F'], {
          windowsHide: true,
          timeout: 5000,
        });
        return result.status === 0;
      } else {
        // Unix-like: Use built-in process.kill
        process.kill(pid, signal);
        return true;
      }
    } catch (error) {
      console.warn(`Error killing process ${pid}:`, error);
      return false;
    }
  }

  /**
   * Wait for a process to exit with timeout
   * Returns true if process exited within timeout, false otherwise
   */
  static async waitForProcessExit(pid: number, timeoutMs: number = 5000): Promise<boolean> {
    const startTime = Date.now();
    const checkInterval = 100; // Check every 100ms

    while (Date.now() - startTime < timeoutMs) {
      if (!ProcessUtils.isProcessRunning(pid)) {
        return true;
      }
      await new Promise((resolve) => setTimeout(resolve, checkInterval));
    }

    return false;
  }
}
