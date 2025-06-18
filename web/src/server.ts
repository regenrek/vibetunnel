import express, { Response } from 'express';
import { createServer } from 'http';
import { WebSocketServer, WebSocket } from 'ws';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { spawn, ChildProcess } from 'child_process';

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ server });

const PORT = process.env.PORT || 3000;

// tty-fwd binary path - check multiple possible locations
const possibleTtyFwdPaths = [
  path.resolve(__dirname, '..', '..', 'tty-fwd', 'target', 'release', 'tty-fwd'),
  path.resolve(__dirname, '..', '..', '..', 'tty-fwd', 'target', 'release', 'tty-fwd'),
  'tty-fwd', // System PATH
];

let TTY_FWD_PATH = '';
for (const pathToCheck of possibleTtyFwdPaths) {
  if (fs.existsSync(pathToCheck)) {
    TTY_FWD_PATH = pathToCheck;
    break;
  }
}

if (!TTY_FWD_PATH) {
  console.error('tty-fwd binary not found. Please ensure it is built and available.');
  process.exit(1);
}

const TTY_FWD_CONTROL_DIR =
  process.env.TTY_FWD_CONTROL_DIR || path.join(os.homedir(), '.vibetunnel/control');

// Ensure control directory exists
if (!fs.existsSync(TTY_FWD_CONTROL_DIR)) {
  fs.mkdirSync(TTY_FWD_CONTROL_DIR, { recursive: true });
  console.log(`Created control directory: ${TTY_FWD_CONTROL_DIR}`);
} else {
  console.log(`Using existing control directory: ${TTY_FWD_CONTROL_DIR}`);
}

console.log(`Using tty-fwd at: ${TTY_FWD_PATH}`);
console.log(`Control directory: ${TTY_FWD_CONTROL_DIR}`);

// Types for tty-fwd responses
interface TtyFwdSession {
  cmdline: string[];
  cwd: string;
  exit_code: number | null;
  name: string;
  pid: number;
  started_at: string;
  status: 'running' | 'exited';
  stdin: string;
  'stream-out': string;
  waiting: boolean;
}

interface TtyFwdListResponse {
  [sessionId: string]: TtyFwdSession;
}

// Helper function to execute tty-fwd commands
async function executeTtyFwd(args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(TTY_FWD_PATH, args);
    let output = '';
    let isResolved = false;

    // Set a timeout to prevent hanging
    const timeout = setTimeout(() => {
      if (!isResolved) {
        isResolved = true;
        child.kill('SIGTERM');
        reject(new Error('tty-fwd command timed out after 5 seconds'));
      }
    }, 5000);

    child.stdout.on('data', (data) => {
      output += data.toString();
    });

    child.on('close', (code) => {
      if (!isResolved) {
        isResolved = true;
        clearTimeout(timeout);
        if (code === 0) {
          resolve(output);
        } else {
          reject(new Error(`tty-fwd failed with code ${code}`));
        }
      }
    });

    child.on('error', (error) => {
      if (!isResolved) {
        isResolved = true;
        clearTimeout(timeout);
        reject(error);
      }
    });
  });
}

// Helper function to resolve paths with ~ expansion
function resolvePath(inputPath: string, fallback?: string): string {
  if (!inputPath) {
    return fallback || process.cwd();
  }

  if (inputPath.startsWith('~')) {
    return path.join(os.homedir(), inputPath.slice(1));
  }

  return path.resolve(inputPath);
}

// Middleware
app.use(express.json());
app.use(express.static(path.join(__dirname, '..', 'public')));

// Hot reload functionality for development
const hotReloadClients = new Set<WebSocket>();

// === SESSION MANAGEMENT ===

// List all sessions
app.get('/api/sessions', async (req, res) => {
  try {
    const output = await executeTtyFwd(['--control-path', TTY_FWD_CONTROL_DIR, '--list-sessions']);
    const sessions: TtyFwdListResponse = JSON.parse(output || '{}');

    const sessionData = Object.entries(sessions).map(([sessionId, sessionInfo]) => {
      // Get actual last modified time from stream-out file
      let lastModified = sessionInfo.started_at;
      try {
        if (fs.existsSync(sessionInfo['stream-out'])) {
          const stats = fs.statSync(sessionInfo['stream-out']);
          lastModified = stats.mtime.toISOString();
        }
      } catch (_e) {
        // Use started_at as fallback
      }

      return {
        id: sessionId,
        command: sessionInfo.cmdline.join(' '),
        workingDir: sessionInfo.cwd,
        name: sessionInfo.name,
        status: sessionInfo.status,
        exitCode: sessionInfo.exit_code,
        startedAt: sessionInfo.started_at,
        lastModified: lastModified,
        pid: sessionInfo.pid,
        waiting: sessionInfo.waiting,
      };
    });

    // Sort by lastModified, most recent first
    sessionData.sort(
      (a, b) => new Date(b.lastModified).getTime() - new Date(a.lastModified).getTime()
    );
    res.json(sessionData);
  } catch (_error) {
    console.error('Failed to list sessions:', _error);
    res.status(500).json({ error: 'Failed to list sessions' });
  }
});

// Create new session
app.post('/api/sessions', async (req, res) => {
  try {
    const { command, workingDir, name } = req.body;

    if (!command || !Array.isArray(command) || command.length === 0) {
      return res.status(400).json({ error: 'Command array is required and cannot be empty' });
    }

    const sessionName = name || `session_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    const cwd = resolvePath(workingDir, process.cwd());

    const args = [
      '--control-path',
      TTY_FWD_CONTROL_DIR,
      '--session-name',
      sessionName,
      '--',
    ].concat(command);

    console.log(`Creating session: ${TTY_FWD_PATH} ${args.join(' ')}`);

    const child = spawn(TTY_FWD_PATH, args, {
      cwd: cwd,
      detached: false,
      stdio: 'pipe',
    });

    // Capture session ID from stdout
    let sessionId = '';
    child.stdout.on('data', (data) => {
      const output = data.toString().trim();
      if (output && !sessionId) {
        // First line of output should be the session ID
        sessionId = output;
        console.log(`Session created with ID: ${sessionId}`);
      }
    });

    child.stderr.on('data', (data) => {
      // Only log stderr if it contains actual errors
      const output = data.toString();
      if (output.includes('error') || output.includes('Error')) {
        console.error(`Session ${sessionName} stderr:`, output);
      }
    });

    child.on('close', async (code) => {
      console.log(`Session ${sessionId || sessionName} exited with code: ${code}`);

      // Send exit event to all clients watching this session
      const streamInfo = activeStreams.get(sessionId);
      if (streamInfo) {
        console.log(`Sending exit event to stream ${sessionId}`);
        const exitEvent = JSON.stringify(['exit', code, sessionId]);
        const eventData = `data: ${exitEvent}\n\n`;

        streamInfo.clients.forEach((client) => {
          try {
            client.write(eventData);
          } catch (_error) {
            console.error('Error sending exit event to client:', _error);
          }
        });
      }
    });

    // Wait for session ID from tty-fwd or timeout after 3 seconds
    const waitForSessionId = new Promise<string>((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error('Failed to get session ID from tty-fwd within 3 seconds'));
      }, 3000);

      const checkSessionId = () => {
        if (sessionId) {
          clearTimeout(timeout);
          resolve(sessionId);
        } else {
          setTimeout(checkSessionId, 100);
        }
      };
      checkSessionId();
    });

    const finalSessionId = await waitForSessionId;
    res.json({ sessionId: finalSessionId });
  } catch (_error) {
    console.error('Error creating session:', _error);
    res.status(500).json({ error: 'Failed to create session' });
  }
});

// Kill session (just kill the process)
app.delete('/api/sessions/:sessionId', async (req, res) => {
  const sessionId = req.params.sessionId;

  try {
    const output = await executeTtyFwd(['--control-path', TTY_FWD_CONTROL_DIR, '--list-sessions']);
    const sessions: TtyFwdListResponse = JSON.parse(output || '{}');
    const session = sessions[sessionId];

    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    if (session.pid) {
      try {
        process.kill(session.pid, 'SIGTERM');
        setTimeout(() => {
          try {
            process.kill(session.pid, 0); // Check if still alive
            process.kill(session.pid, 'SIGKILL'); // Force kill
          } catch (_e) {
            // Process already dead
          }
        }, 1000);
      } catch (_error) {
        // Process already dead
      }
    }

    res.json({ success: true, message: 'Session killed' });
  } catch (_error) {
    console.error('Error killing session:', _error);
    res.status(500).json({ error: 'Failed to kill session' });
  }
});

// Cleanup session files
app.delete('/api/sessions/:sessionId/cleanup', async (req, res) => {
  const sessionId = req.params.sessionId;

  try {
    await executeTtyFwd([
      '--control-path',
      TTY_FWD_CONTROL_DIR,
      '--session',
      sessionId,
      '--cleanup',
    ]);

    res.json({ success: true, message: 'Session cleaned up' });
  } catch (_error) {
    // If tty-fwd cleanup fails, force remove directory
    console.log('tty-fwd cleanup failed, force removing directory');
    const sessionDir = path.join(TTY_FWD_CONTROL_DIR, sessionId);
    try {
      if (fs.existsSync(sessionDir)) {
        fs.rmSync(sessionDir, { recursive: true, force: true });
      }
      res.json({ success: true, message: 'Session force cleaned up' });
    } catch (fsError) {
      console.error('Error force removing session directory:', fsError);
      res.status(500).json({ error: 'Failed to cleanup session' });
    }
  }
});

// Cleanup all exited sessions
app.post('/api/cleanup-exited', async (req, res) => {
  try {
    await executeTtyFwd(['--control-path', TTY_FWD_CONTROL_DIR, '--cleanup']);

    res.json({ success: true, message: 'All exited sessions cleaned up' });
  } catch (_error) {
    console.error('Error cleaning up exited sessions:', _error);
    res.status(500).json({ error: 'Failed to cleanup exited sessions' });
  }
});

// === TERMINAL I/O ===

// Track active streams per session to avoid multiple tail processes
const activeStreams = new Map<
  string,
  {
    clients: Set<Response>;
    tailProcess: ChildProcess;
    lastPosition: number;
  }
>();

// Live streaming cast file for XTerm renderer
app.get('/api/sessions/:sessionId/stream', async (req, res) => {
  const sessionId = req.params.sessionId;
  const streamOutPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'stream-out');

  if (!fs.existsSync(streamOutPath)) {
    return res.status(404).json({ error: 'Session not found' });
  }

  console.log(
    `New SSE client connected to session ${sessionId} from ${req.get('User-Agent')?.substring(0, 50) || 'unknown'}`
  );

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Cache-Control',
  });

  const startTime = Date.now() / 1000;
  let headerSent = false;

  // Send existing content first
  try {
    const content = fs.readFileSync(streamOutPath, 'utf8');
    const lines = content.trim().split('\n');

    for (const line of lines) {
      if (line.trim()) {
        try {
          const parsed = JSON.parse(line);
          if (parsed.version && parsed.width && parsed.height) {
            console.log(`Terminal size for session ${sessionId}: ${parsed.width}x${parsed.height}`);
            res.write(`data: ${line}\n\n`);
            headerSent = true;
          } else if (Array.isArray(parsed) && parsed.length >= 3) {
            const instantEvent = [0, parsed[1], parsed[2]];
            res.write(`data: ${JSON.stringify(instantEvent)}\n\n`);
          }
        } catch (_e) {
          // Skip invalid lines
        }
      }
    }
  } catch (_error) {
    console.error('Error reading existing content:', _error);
  }

  // Send default header if none found
  if (!headerSent) {
    const defaultHeader = {
      version: 2,
      width: 80,
      height: 24,
      timestamp: Math.floor(startTime),
      env: { TERM: 'xterm-256color' },
    };
    res.write(`data: ${JSON.stringify(defaultHeader)}\n\n`);
  }

  // Get or create shared stream for this session
  let streamInfo = activeStreams.get(sessionId);

  if (!streamInfo) {
    console.log(`Creating new shared tail process for session ${sessionId}`);

    // Create new tail process for this session
    const tailProcess = spawn('tail', ['-f', streamOutPath]);
    let buffer = '';

    streamInfo = {
      clients: new Set(),
      tailProcess,
      lastPosition: 0,
    };

    activeStreams.set(sessionId, streamInfo);

    // Handle tail output - broadcast to all clients
    tailProcess.stdout.on('data', (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        if (line.trim()) {
          let eventData;
          try {
            const parsed = JSON.parse(line);
            if (parsed.version && parsed.width && parsed.height) {
              continue; // Skip duplicate headers
            }
            if (Array.isArray(parsed) && parsed.length >= 3) {
              const currentTime = Date.now() / 1000;
              const realTimeEvent = [currentTime - startTime, parsed[1], parsed[2]];
              eventData = `data: ${JSON.stringify(realTimeEvent)}\n\n`;
            }
          } catch (_e) {
            // Handle non-JSON as raw output
            const currentTime = Date.now() / 1000;
            const castEvent = [currentTime - startTime, 'o', line];
            eventData = `data: ${JSON.stringify(castEvent)}\n\n`;
          }

          if (eventData && streamInfo) {
            // Broadcast to all connected clients
            streamInfo.clients.forEach((client) => {
              try {
                client.write(eventData);
              } catch (_error) {
                console.error('Error writing to client:', _error);
                if (streamInfo) {
                  streamInfo.clients.delete(client);
                  console.log(
                    `Removed failed client from session ${sessionId}, remaining clients: ${streamInfo.clients.size}`
                  );
                }
              }
            });
          }
        }
      }
    });

    tailProcess.on('error', (error) => {
      console.error(`Shared tail process error for session ${sessionId}:`, error);
      // Cleanup all clients
      const currentStreamInfo = activeStreams.get(sessionId);
      if (currentStreamInfo) {
        currentStreamInfo.clients.forEach((client) => {
          try {
            client.end();
          } catch (_e) {}
        });
      }
      activeStreams.delete(sessionId);
    });

    tailProcess.on('exit', (code) => {
      console.log(`Shared tail process exited for session ${sessionId} with code ${code}`);
      // Cleanup all clients
      const currentStreamInfo = activeStreams.get(sessionId);
      if (currentStreamInfo) {
        currentStreamInfo.clients.forEach((client) => {
          try {
            client.end();
          } catch (_e) {}
        });
      }
      activeStreams.delete(sessionId);
    });
  }

  // Add this client to the shared stream
  streamInfo.clients.add(res);
  console.log(`Added client to session ${sessionId}, total clients: ${streamInfo.clients.size}`);

  // Cleanup when client disconnects
  const cleanup = () => {
    if (streamInfo && streamInfo.clients.has(res)) {
      streamInfo.clients.delete(res);
      console.log(
        `Removed client from session ${sessionId}, remaining clients: ${streamInfo.clients.size}`
      );

      // If no more clients, cleanup the tail process
      if (streamInfo.clients.size === 0) {
        console.log(`No more clients for session ${sessionId}, cleaning up tail process`);
        try {
          streamInfo.tailProcess.kill('SIGTERM');
        } catch (_e) {}
        activeStreams.delete(sessionId);
      }
    }
  };

  req.on('close', cleanup);
  req.on('aborted', cleanup);
  req.on('error', cleanup);
  res.on('close', cleanup);
  res.on('finish', cleanup);
});

// Get session snapshot (optimized cast with only content after last clear)
app.get('/api/sessions/:sessionId/snapshot', (req, res) => {
  const sessionId = req.params.sessionId;
  const streamOutPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'stream-out');

  if (!fs.existsSync(streamOutPath)) {
    return res.status(404).json({ error: 'Session not found' });
  }

  try {
    const content = fs.readFileSync(streamOutPath, 'utf8');
    const lines = content.trim().split('\n');

    let header = null;
    const allEvents = [];

    // Parse all lines first
    for (const line of lines) {
      if (line.trim()) {
        try {
          const parsed = JSON.parse(line);

          // Header line
          if (parsed.version && parsed.width && parsed.height) {
            header = parsed;
          }
          // Event line [timestamp, type, data]
          else if (Array.isArray(parsed) && parsed.length >= 3) {
            allEvents.push(parsed);
          }
        } catch (_e) {
          // Skip invalid lines
        }
      }
    }

    // Find the last clear command (usually "\x1b[2J\x1b[3J\x1b[H" or similar)
    let lastClearIndex = -1;
    let lastResizeBeforeClear = null;

    for (let i = allEvents.length - 1; i >= 0; i--) {
      const event = allEvents[i];
      if (event[1] === 'o' && event[2]) {
        // Look for clear screen escape sequences
        const data = event[2];
        if (
          data.includes('\x1b[2J') || // Clear entire screen
          data.includes('\x1b[H\x1b[2J') || // Home cursor + clear screen
          data.includes('\x1b[3J') || // Clear scrollback
          data.includes('\x1bc') // Full reset
        ) {
          lastClearIndex = i;
          break;
        }
      }
    }

    // Find the last resize event before the clear (if any)
    if (lastClearIndex > 0) {
      for (let i = lastClearIndex - 1; i >= 0; i--) {
        const event = allEvents[i];
        if (event[1] === 'r') {
          lastResizeBeforeClear = event;
          break;
        }
      }
    }

    // Build optimized event list
    const optimizedEvents = [];

    // Include last resize before clear if found
    if (lastResizeBeforeClear) {
      optimizedEvents.push([0, lastResizeBeforeClear[1], lastResizeBeforeClear[2]]);
    }

    // Include events after the last clear (or all events if no clear found)
    const startIndex = lastClearIndex >= 0 ? lastClearIndex : 0;
    for (let i = startIndex; i < allEvents.length; i++) {
      const event = allEvents[i];
      optimizedEvents.push([0, event[1], event[2]]);
    }

    // Build the complete cast
    const cast = [];

    // Add header if found, otherwise use default
    if (header) {
      cast.push(JSON.stringify(header));
    } else {
      cast.push(
        JSON.stringify({
          version: 2,
          width: 80,
          height: 24,
          timestamp: Math.floor(Date.now() / 1000),
          env: { TERM: 'xterm-256color' },
        })
      );
    }

    // Add optimized events
    optimizedEvents.forEach((event) => {
      cast.push(JSON.stringify(event));
    });

    const originalSize = allEvents.length;
    const optimizedSize = optimizedEvents.length;
    const reduction =
      originalSize > 0 ? (((originalSize - optimizedSize) / originalSize) * 100).toFixed(1) : '0';

    console.log(
      `Snapshot for ${sessionId}: ${originalSize} events → ${optimizedSize} events (${reduction}% reduction)`
    );

    res.setHeader('Content-Type', 'text/plain');
    res.send(cast.join('\n'));
  } catch (_error) {
    console.error('Error reading session snapshot:', _error);
    res.status(500).json({ error: 'Failed to read session snapshot' });
  }
});

// Send input to session
app.post('/api/sessions/:sessionId/input', async (req, res) => {
  const sessionId = req.params.sessionId;
  const { text } = req.body;

  if (text === undefined || text === null) {
    return res.status(400).json({ error: 'Text is required' });
  }

  console.log(`Sending input to session ${sessionId}:`, JSON.stringify(text));

  try {
    // Validate session exists and is running
    const output = await executeTtyFwd(['--control-path', TTY_FWD_CONTROL_DIR, '--list-sessions']);
    const sessions: TtyFwdListResponse = JSON.parse(output || '{}');

    if (!sessions[sessionId]) {
      console.error(`Session ${sessionId} not found in active sessions`);
      return res.status(404).json({ error: 'Session not found' });
    }

    const session = sessions[sessionId];
    if (session.status !== 'running') {
      console.error(`Session ${sessionId} is not running (status: ${session.status})`);
      return res.status(400).json({ error: 'Session is not running' });
    }

    // Check if the process is actually still alive
    if (session.pid) {
      try {
        process.kill(session.pid, 0); // Signal 0 just checks if process exists
      } catch (_error) {
        console.error(`Session ${sessionId} process ${session.pid} is dead, cleaning up`);
        // Try to cleanup the stale session
        try {
          await executeTtyFwd([
            '--control-path',
            TTY_FWD_CONTROL_DIR,
            '--session',
            sessionId,
            '--cleanup',
          ]);
        } catch (cleanupError) {
          console.error('Failed to cleanup stale session:', cleanupError);
        }
        return res.status(410).json({ error: 'Session process has died' });
      }
    }

    // Check if this is a special key that should use --send-key
    const specialKeys = [
      'arrow_up',
      'arrow_down',
      'arrow_left',
      'arrow_right',
      'escape',
      'enter',
      'ctrl_enter',
      'shift_enter',
    ];
    const isSpecialKey = specialKeys.includes(text);

    // const startTime = Date.now();

    if (isSpecialKey) {
      await executeTtyFwd([
        '--control-path',
        TTY_FWD_CONTROL_DIR,
        '--session',
        sessionId,
        '--send-key',
        text,
      ]);
      // Key sent successfully (removed verbose logging)
    } else {
      await executeTtyFwd([
        '--control-path',
        TTY_FWD_CONTROL_DIR,
        '--session',
        sessionId,
        '--send-text',
        text,
      ]);
      // Text sent successfully (removed verbose logging)
    }

    res.json({ success: true });
  } catch (_error) {
    console.error('Error sending input via tty-fwd:', _error);
    const errorMessage = _error instanceof Error ? _error.message : 'Unknown error';
    res.status(500).json({ error: 'Failed to send input', details: errorMessage });
  }
});

// === CAST FILE SERVING ===

// Serve test cast file
app.get('/api/test-cast', (req, res) => {
  const testCastPath = path.join(__dirname, '..', 'public', 'stream-out');

  try {
    if (fs.existsSync(testCastPath)) {
      res.setHeader('Content-Type', 'text/plain');
      const content = fs.readFileSync(testCastPath, 'utf8');
      res.send(content);
    } else {
      res.status(404).json({ error: 'Test cast file not found' });
    }
  } catch (_error) {
    console.error('Error serving test cast file:', _error);
    res.status(500).json({ error: 'Failed to serve test cast file' });
  }
});

// === FILE SYSTEM ===

// Directory listing for file browser
app.get('/api/fs/browse', (req, res) => {
  const dirPath = (req.query.path as string) || '~';

  try {
    const expandedPath = resolvePath(dirPath, '~');

    if (!fs.existsSync(expandedPath)) {
      return res.status(404).json({ error: 'Directory not found' });
    }

    const stats = fs.statSync(expandedPath);
    if (!stats.isDirectory()) {
      return res.status(400).json({ error: 'Path is not a directory' });
    }

    const files = fs.readdirSync(expandedPath).map((name) => {
      const filePath = path.join(expandedPath, name);
      const fileStats = fs.statSync(filePath);

      return {
        name,
        created: fileStats.birthtime.toISOString(),
        lastModified: fileStats.mtime.toISOString(),
        size: fileStats.size,
        isDir: fileStats.isDirectory(),
      };
    });

    res.json({
      absolutePath: expandedPath,
      files: files.sort((a, b) => {
        // Directories first, then files
        if (a.isDir && !b.isDir) return -1;
        if (!a.isDir && b.isDir) return 1;
        return a.name.localeCompare(b.name);
      }),
    });
  } catch (_error) {
    console.error('Error listing directory:', _error);
    res.status(500).json({ error: 'Failed to list directory' });
  }
});

// Create directory
app.post('/api/mkdir', (req, res) => {
  try {
    const { path: dirPath, name } = req.body;

    if (!dirPath || !name) {
      return res.status(400).json({ error: 'Missing path or name parameter' });
    }

    // Validate directory name (no path separators, no hidden files starting with .)
    if (name.includes('/') || name.includes('\\') || name.startsWith('.')) {
      return res.status(400).json({ error: 'Invalid directory name' });
    }

    // Expand tilde in path
    const expandedPath = dirPath.startsWith('~')
      ? path.join(os.homedir(), dirPath.slice(1))
      : path.resolve(dirPath);

    // Security check: ensure we're not trying to access outside allowed areas
    const allowedBasePaths = [os.homedir(), process.cwd()];
    const isAllowed = allowedBasePaths.some((basePath) =>
      expandedPath.startsWith(path.resolve(basePath))
    );

    if (!isAllowed) {
      return res.status(403).json({ error: 'Access denied' });
    }

    // Check if parent directory exists
    if (!fs.existsSync(expandedPath)) {
      return res.status(404).json({ error: 'Parent directory not found' });
    }

    const stats = fs.statSync(expandedPath);
    if (!stats.isDirectory()) {
      return res.status(400).json({ error: 'Parent path is not a directory' });
    }

    const newDirPath = path.join(expandedPath, name);

    // Check if directory already exists
    if (fs.existsSync(newDirPath)) {
      return res.status(409).json({ error: 'Directory already exists' });
    }

    // Create the directory
    fs.mkdirSync(newDirPath, { recursive: false });

    res.json({
      success: true,
      path: newDirPath,
      message: `Directory '${name}' created successfully`,
    });
  } catch (_error) {
    console.error('Error creating directory:', _error);
    res.status(500).json({ error: 'Failed to create directory' });
  }
});

// === WEBSOCKETS ===

// WebSocket for hot reload
wss.on('connection', (ws, req) => {
  const url = new URL(req.url ?? '', `http://${req.headers.host}`);
  const isHotReload = url.searchParams.get('hotReload') === 'true';

  if (isHotReload) {
    hotReloadClients.add(ws);
    ws.on('close', () => {
      hotReloadClients.delete(ws);
    });
    return;
  }

  ws.close(1008, 'Only hot reload connections supported');
});

// Hot reload file watching in development
if (process.env.NODE_ENV !== 'production') {
  const chokidar = require('chokidar');
  const watcher = chokidar.watch(['public/**/*', 'src/**/*'], {
    ignored: /node_modules/,
    persistent: true,
  });

  watcher.on('change', (path: string) => {
    console.log(`File changed: ${path}`);
    hotReloadClients.forEach((ws: WebSocket) => {
      if (ws.readyState === ws.OPEN) {
        ws.send(JSON.stringify({ type: 'reload' }));
      }
    });
  });
}

// Only start server if not in test environment
if (process.env.NODE_ENV !== 'test') {
  server.listen(PORT, () => {
    console.log(`VibeTunnel New Server running on http://localhost:${PORT}`);
    console.log(`Using tty-fwd: ${TTY_FWD_PATH}`);
  });
}

// Export for testing
export { app, server, wss };
