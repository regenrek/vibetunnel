/**
 * Integration Example - How to integrate PTY service with existing server
 *
 * This example shows how to replace tty-fwd calls with the new PTY service
 * while maintaining backward compatibility.
 */

import { PtyService, SessionEntryWithId, PtyError } from './index.js';

// Configuration - can be set via environment variables
const PTY_CONFIG = {
  implementation: (process.env.PTY_IMPLEMENTATION as any) || 'auto',
  controlPath: process.env.TTY_FWD_CONTROL_DIR || undefined,
  fallbackToTtyFwd: process.env.PTY_FALLBACK_TTY_FWD !== 'false',
  ttyFwdPath: process.env.TTY_FWD_PATH || undefined,
};

// Create global PTY service instance
export const ptyService = new PtyService(PTY_CONFIG);

console.log(`PTY Service initialized with ${ptyService.getCurrentImplementation()} implementation`);

// Example: Replace existing session creation code
export async function createSession(
  command: string[],
  sessionName?: string,
  workingDir?: string
): Promise<{ sessionId: string; sessionInfo: any }> {
  try {
    const result = await ptyService.createSession(command, {
      sessionName,
      workingDir,
      term: 'xterm-256color',
      cols: 80,
      rows: 24,
    });

    console.log(
      `Created session ${result.sessionId} using ${ptyService.getCurrentImplementation()}`
    );
    return result;
  } catch (error) {
    throw new PtyError(`Failed to create session: ${error}`);
  }
}

// Example: Replace existing session listing code
export function listSessions(): SessionEntryWithId[] {
  try {
    return ptyService.listSessions();
  } catch (error) {
    console.error('Failed to list sessions:', error);
    return [];
  }
}

// Example: Replace existing session input handling
export function sendSessionInput(sessionId: string, text?: string, key?: string): void {
  try {
    if (text !== undefined) {
      ptyService.sendInput(sessionId, { text });
    } else if (key !== undefined) {
      ptyService.sendInput(sessionId, { key: key as any });
    } else {
      throw new Error('Either text or key must be provided');
    }
  } catch (error) {
    throw new PtyError(`Failed to send input to session ${sessionId}: ${error}`);
  }
}

// Example: Replace existing session termination code
export function killSession(sessionId: string, signal: string | number = 'SIGTERM'): void {
  try {
    ptyService.killSession(sessionId, signal);
    console.log(`Killed session ${sessionId}`);
  } catch (error) {
    throw new PtyError(`Failed to kill session ${sessionId}: ${error}`);
  }
}

// Example: Replace existing session cleanup code
export function cleanupSession(sessionId: string): void {
  try {
    ptyService.cleanupSession(sessionId);
    console.log(`Cleaned up session ${sessionId}`);
  } catch (error) {
    throw new PtyError(`Failed to cleanup session ${sessionId}: ${error}`);
  }
}

// Example: Get session info (compatible with existing code)
export function getSession(sessionId: string): SessionEntryWithId | null {
  try {
    return ptyService.getSession(sessionId);
  } catch (error) {
    console.error(`Failed to get session ${sessionId}:`, error);
    return null;
  }
}

// Example: Health check function
export function getPtyServiceStatus() {
  return {
    implementation: ptyService.getCurrentImplementation(),
    usingNodePty: ptyService.isUsingNodePty(),
    usingTtyFwd: ptyService.isUsingTtyFwd(),
    activeSessionCount: ptyService.getActiveSessionCount(),
    controlPath: ptyService.getControlPath(),
    config: ptyService.getConfig(),
  };
}

// Example Express.js route handlers (drop-in replacements)
export const routeHandlers = {
  // POST /api/sessions
  async createSessionHandler(req: any, res: any) {
    try {
      const { command, workingDir } = req.body;

      if (!command || !Array.isArray(command)) {
        return res.status(400).json({ error: 'Invalid command' });
      }

      const result = await createSession(command, undefined, workingDir);
      res.json({ sessionId: result.sessionId });
    } catch (error) {
      console.error('Failed to create session:', error);
      res.status(500).json({ error: 'Failed to create session' });
    }
  },

  // GET /api/sessions
  listSessionsHandler(req: any, res: any) {
    try {
      const sessions = listSessions();
      res.json(sessions);
    } catch (error) {
      console.error('Failed to list sessions:', error);
      res.status(500).json({ error: 'Failed to list sessions' });
    }
  },

  // POST /api/sessions/:sessionId/input
  sendInputHandler(req: any, res: any) {
    try {
      const { sessionId } = req.params;
      const { text, key } = req.body;

      sendSessionInput(sessionId, text, key);
      res.json({ success: true });
    } catch (error) {
      console.error(`Failed to send input to session ${req.params.sessionId}:`, error);
      res.status(500).json({ error: 'Failed to send input' });
    }
  },

  // DELETE /api/sessions/:sessionId
  killSessionHandler(req: any, res: any) {
    try {
      const { sessionId } = req.params;
      killSession(sessionId);
      res.json({ success: true });
    } catch (error) {
      console.error(`Failed to kill session ${req.params.sessionId}:`, error);
      res.status(500).json({ error: 'Failed to kill session' });
    }
  },

  // DELETE /api/sessions/:sessionId/cleanup
  cleanupSessionHandler(req: any, res: any) {
    try {
      const { sessionId } = req.params;
      cleanupSession(sessionId);
      res.json({ success: true });
    } catch (error) {
      console.error(`Failed to cleanup session ${req.params.sessionId}:`, error);
      res.status(500).json({ error: 'Failed to cleanup session' });
    }
  },

  // GET /api/sessions/:sessionId
  getSessionHandler(req: any, res: any) {
    try {
      const { sessionId } = req.params;
      const session = getSession(sessionId);

      if (!session) {
        return res.status(404).json({ error: 'Session not found' });
      }

      res.json(session);
    } catch (error) {
      console.error(`Failed to get session ${req.params.sessionId}:`, error);
      res.status(500).json({ error: 'Failed to get session' });
    }
  },

  // GET /api/pty/status (new endpoint for monitoring)
  statusHandler(req: any, res: any) {
    try {
      const status = getPtyServiceStatus();
      res.json(status);
    } catch (error) {
      console.error('Failed to get PTY service status:', error);
      res.status(500).json({ error: 'Failed to get status' });
    }
  },
};

// Example migration notes for existing code:
/*

MIGRATION GUIDE:

1. Replace tty-fwd spawn calls:
   OLD: 
   ```typescript
   const proc = spawn(ttyFwdPath, ['--control-path', controlPath, '--', ...command]);
   ```
   NEW:
   ```typescript
   const result = await ptyService.createSession(command, options);
   ```

2. Replace tty-fwd list calls:
   OLD:
   ```typescript
   const result = spawn(ttyFwdPath, ['--control-path', controlPath, '--list-sessions']);
   ```
   NEW:
   ```typescript
   const sessions = ptyService.listSessions();
   ```

3. Replace tty-fwd input calls:
   OLD:
   ```typescript
   spawn(ttyFwdPath, ['--control-path', controlPath, '--session', sessionId, '--send-text', text]);
   ```
   NEW:
   ```typescript
   ptyService.sendInput(sessionId, { text });
   ```

4. File paths remain the same:
   - stream-out files are still in the same location
   - Session directory structure is identical
   - Asciinema format is fully compatible

5. Environment variable support:
   - PTY_IMPLEMENTATION: 'node-pty' | 'tty-fwd' | 'auto'
   - PTY_FALLBACK_TTY_FWD: 'true' | 'false' 
   - TTY_FWD_CONTROL_DIR: control directory path
   - TTY_FWD_PATH: path to tty-fwd binary

6. Error handling:
   - All functions throw PtyError for consistent error handling
   - Automatic fallback to tty-fwd if node-pty fails
   - Graceful degradation in test environments

*/
