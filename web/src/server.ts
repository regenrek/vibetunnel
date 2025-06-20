import express from 'express';
import { createServer } from 'http';
import { WebSocketServer, WebSocket } from 'ws';
import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import { PtyService, PtyError } from './pty/index.js';
import { TerminalManager } from './terminal-manager.js';
import { StreamWatcher } from './stream-watcher.js';
import { RemoteRegistry, RemoteServer } from './remote-registry.js';
import { HQClient } from './hq-client.js';
import { createSessionProxyMiddleware } from './hq-utils.js';

type BufferSnapshot = Awaited<ReturnType<TerminalManager['getBufferSnapshot']>>;

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ server });

// Add JSON body parser middleware
app.use(express.json());

const PORT = process.env.PORT || 4020;

// ANSI color codes
const RED = '\x1b[31m';
const YELLOW = '\x1b[33m';
const GREEN = '\x1b[32m';
const RESET = '\x1b[0m';

// Parse command line arguments
const args = process.argv.slice(2);
let basicAuthUsername: string | null = null;
let basicAuthPassword: string | null = null;
let isHQMode = false;
let hqUrl: string | null = null;
let hqUsername: string | null = null;
let hqPassword: string | null = null;
let remoteName: string | null = null;

// Check for command line arguments
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--username' && i + 1 < args.length) {
    basicAuthUsername = args[i + 1];
    i++; // Skip the username value in next iteration
  } else if (args[i] === '--password' && i + 1 < args.length) {
    basicAuthPassword = args[i + 1];
    i++; // Skip the password value in next iteration
  } else if (args[i] === '--hq') {
    isHQMode = true;
  } else if (args[i] === '--hq-url' && i + 1 < args.length) {
    hqUrl = args[i + 1];
    i++; // Skip the URL value in next iteration
  } else if (args[i] === '--hq-username' && i + 1 < args.length) {
    hqUsername = args[i + 1];
    i++; // Skip the username value in next iteration
  } else if (args[i] === '--hq-password' && i + 1 < args.length) {
    hqPassword = args[i + 1];
    i++; // Skip the password value in next iteration
  } else if (args[i] === '--name' && i + 1 < args.length) {
    remoteName = args[i + 1];
    i++; // Skip the name value in next iteration
  }
}

// Check environment variables for local auth
if (!basicAuthUsername && process.env.VIBETUNNEL_USERNAME) {
  basicAuthUsername = process.env.VIBETUNNEL_USERNAME;
}
if (!basicAuthPassword && process.env.VIBETUNNEL_PASSWORD) {
  basicAuthPassword = process.env.VIBETUNNEL_PASSWORD;
}

// Validate local auth configuration
if ((basicAuthUsername && !basicAuthPassword) || (!basicAuthUsername && basicAuthPassword)) {
  console.error(
    `${RED}ERROR: Both username and password must be provided for authentication${RESET}`
  );
  console.error(
    'Use --username and --password, or set both VIBETUNNEL_USERNAME and VIBETUNNEL_PASSWORD'
  );
  process.exit(1);
}

// Validate HQ registration configuration
if (hqUrl && (!hqUsername || !hqPassword)) {
  console.error(
    `${RED}ERROR: HQ username and password required when --hq-url is specified${RESET}`
  );
  console.error('Use --hq-username and --hq-password with --hq-url');
  process.exit(1);
}

// Validate remote name is provided when registering with HQ
if (hqUrl && !remoteName) {
  console.error(`${RED}ERROR: Remote name required when --hq-url is specified${RESET}`);
  console.error('Use --name to specify a unique name for this remote server');
  process.exit(1);
}

// Validate HQ URL
if (hqUrl) {
  try {
    const url = new URL(hqUrl);
    if (url.protocol !== 'https:') {
      console.error(`${RED}ERROR: --hq-url must use HTTPS protocol${RESET}`);
      process.exit(1);
    }
  } catch {
    console.error(`${RED}ERROR: Invalid --hq-url: ${hqUrl}${RESET}`);
    process.exit(1);
  }
}

if (basicAuthUsername && basicAuthPassword) {
  console.log(`${GREEN}Basic authentication enabled${RESET}`);
} else {
  console.log(`${RED}WARNING: No authentication configured!${RESET}`);
  console.log(
    `${YELLOW}Set VIBETUNNEL_USERNAME and VIBETUNNEL_PASSWORD or use --username and --password flags.${RESET}`
  );
}

// Control directory for session data
const CONTROL_DIR =
  process.env.VIBETUNNEL_CONTROL_DIR || path.join(os.homedir(), '.vibetunnel/control');

// Initialize PTY service with node-pty implementation
const ptyService = new PtyService({
  implementation: 'node-pty',
  controlPath: CONTROL_DIR,
});

// Initialize Terminal Manager for server-side terminal state
const terminalManager = new TerminalManager(CONTROL_DIR);

// Initialize Stream Watcher for efficient file streaming
const streamWatcher = new StreamWatcher();

// Initialize HQ components
let remoteRegistry: RemoteRegistry | null = null;
let hqClient: HQClient | null = null;

if (isHQMode) {
  remoteRegistry = new RemoteRegistry();
  console.log(`${GREEN}Running in HQ mode${RESET}`);
}

if (hqUrl && hqUsername && hqPassword && remoteName) {
  hqClient = new HQClient(hqUrl, hqUsername, hqPassword, remoteName);
  console.log(`${GREEN}Will register with HQ at: ${hqUrl}${RESET}`);
  console.log(`${GREEN}Remote name: ${remoteName}${RESET}`);
}

// Ensure control directory exists
if (!fs.existsSync(CONTROL_DIR)) {
  fs.mkdirSync(CONTROL_DIR, { recursive: true });
  console.log(`Created control directory: ${CONTROL_DIR}`);
} else {
  console.log(`Using existing control directory: ${CONTROL_DIR}`);
}

console.log(`PTY Service: Using ${ptyService.getCurrentImplementation()} implementation`);
console.log(`Control directory: ${CONTROL_DIR}`);

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
app.use(express.urlencoded({ extended: true }));

// Authentication middleware - supports both Basic Auth and Bearer token (for remotes)
const authMiddleware = (
  req: express.Request,
  res: express.Response,
  next: express.NextFunction
) => {
  // Skip auth if not configured
  if (!(basicAuthUsername && basicAuthPassword) && !hqClient) {
    return next();
  }

  // Skip auth for WebSocket upgrade requests (handled separately)
  if (req.headers.upgrade === 'websocket') {
    return next();
  }

  const authHeader = req.headers.authorization;

  if (!authHeader) {
    res.setHeader('WWW-Authenticate', 'Basic realm="VibeTunnel"');
    return res.status(401).json({ error: 'Authentication required' });
  }

  // Check Bearer token first (if we're a remote that registered with HQ)
  if (authHeader.startsWith('Bearer ') && hqClient) {
    const token = authHeader.slice(7);
    if (token === hqClient.getToken()) {
      return next();
    }
  }

  // Check Basic Auth
  if (authHeader.startsWith('Basic ') && basicAuthUsername && basicAuthPassword) {
    const base64Credentials = authHeader.slice(6);
    const credentials = Buffer.from(base64Credentials, 'base64').toString('utf-8');
    const [username, password] = credentials.split(':');

    if (username === basicAuthUsername && password === basicAuthPassword) {
      return next();
    }
  }

  res.setHeader('WWW-Authenticate', 'Basic realm="VibeTunnel"');
  return res.status(401).json({ error: 'Invalid credentials' });
};

// Apply auth middleware if authentication is configured
if ((basicAuthUsername && basicAuthPassword) || hqClient) {
  app.use(authMiddleware);
}

// Create session proxy middleware
const sessionProxy = createSessionProxyMiddleware(isHQMode, remoteRegistry);

app.use(express.static(path.join(__dirname, '..', 'public')));

// Hot reload functionality for development
const hotReloadClients = new Set<WebSocket>();

// === HEALTH CHECK ===

// Simple health check endpoint
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// === HQ/REMOTE MANAGEMENT ===

// Register a remote server (HQ mode only)
app.post('/api/remotes/register', (req, res) => {
  if (!isHQMode || !remoteRegistry) {
    return res.status(403).json({ error: 'This endpoint is only available in HQ mode' });
  }

  const { id, name, url, token } = req.body;

  if (!id || !name || !url || !token) {
    return res.status(400).json({ error: 'Missing required fields: id, name, url, token' });
  }

  try {
    const remote = remoteRegistry.register({
      id,
      name,
      url,
      token,
    });

    res.json({ success: true, remote });
  } catch (error) {
    if (error instanceof Error && error.message.includes('already registered')) {
      return res.status(409).json({ error: error.message });
    }
    console.error('Failed to register remote:', error);
    res.status(500).json({ error: 'Failed to register remote' });
  }
});

// Unregister a remote server (HQ mode only)
app.delete('/api/remotes/:id', (req, res) => {
  if (!isHQMode || !remoteRegistry) {
    return res.status(403).json({ error: 'This endpoint is only available in HQ mode' });
  }

  const { id } = req.params;
  const success = remoteRegistry.unregister(id);

  if (success) {
    res.json({ success: true });
  } else {
    res.status(404).json({ error: 'Remote not found' });
  }
});

// List all remote servers (HQ mode only)
app.get('/api/remotes', (req, res) => {
  if (!isHQMode || !remoteRegistry) {
    return res.status(403).json({ error: 'This endpoint is only available in HQ mode' });
  }

  const remotes = remoteRegistry.getRemotes();
  res.json(remotes);
});

// === SESSION MANAGEMENT ===

// List all sessions
app.get('/api/sessions', async (req, res) => {
  try {
    // Get local sessions
    const localSessions = ptyService.listSessions();

    const localSessionData = localSessions.map((sessionInfo) => {
      // Get actual last modified time from stream-out file
      let lastModified = sessionInfo.started_at || new Date().toISOString();
      try {
        if (fs.existsSync(sessionInfo['stream-out'])) {
          const stats = fs.statSync(sessionInfo['stream-out']);
          lastModified = stats.mtime.toISOString();
        }
      } catch (_e) {
        // Use started_at as fallback
      }

      return {
        id: sessionInfo.session_id,
        command: Array.isArray(sessionInfo.cmdline)
          ? sessionInfo.cmdline.join(' ')
          : sessionInfo.cmdline || '',
        workingDir: sessionInfo.cwd,
        name: sessionInfo.name,
        status: sessionInfo.status,
        exitCode: sessionInfo.exit_code,
        startedAt: sessionInfo.started_at,
        lastModified: lastModified,
        pid: sessionInfo.pid,
        waiting: sessionInfo.waiting,
        remoteName: 'Local', // Local sessions belong to "Local"
      };
    });

    let allSessions = localSessionData;

    // If in HQ mode, fetch sessions from all remotes
    if (isHQMode && remoteRegistry) {
      const allRemotes = remoteRegistry.getRemotes();

      // Fetch sessions from each remote in parallel
      const remoteSessionPromises = allRemotes.map(async (remote) => {
        try {
          const response = await fetch(`${remote.url}/api/sessions`, {
            headers: {
              Authorization: `Bearer ${remote.token}`,
            },
            signal: AbortSignal.timeout(5000), // 5 second timeout
          });

          if (response.ok) {
            const remoteSessions = await response.json();

            // Track session IDs for this remote
            const sessionIds = remoteSessions.map((s: any) => s.id);
            remoteRegistry.updateRemoteSessions(remote.id, sessionIds);

            // Add remote info to each session
            return remoteSessions.map((session: any) => ({
              ...session,
              remoteName: remote.name,
            }));
          }
        } catch (error) {
          console.error(`Failed to fetch sessions from remote ${remote.name}:`, error);
        }
        return [];
      });

      const remoteSessionArrays = await Promise.all(remoteSessionPromises);
      const remoteSessions = remoteSessionArrays.flat();

      allSessions = [...localSessionData, ...remoteSessions];
    }

    // Sort by lastModified, most recent first
    allSessions.sort(
      (a, b) => new Date(b.lastModified).getTime() - new Date(a.lastModified).getTime()
    );

    res.json(allSessions);
  } catch (error) {
    console.error('Failed to list sessions:', error);
    res.status(500).json({ error: 'Failed to list sessions' });
  }
});

// Create new session
app.post('/api/sessions', async (req, res) => {
  try {
    const { command, workingDir, name, remoteId } = req.body;

    if (!command || !Array.isArray(command) || command.length === 0) {
      return res.status(400).json({ error: 'Command array is required and cannot be empty' });
    }

    // If remoteId is specified and we're in HQ mode, forward to remote
    if (remoteId && remoteId !== 'local' && isHQMode && remoteRegistry) {
      const remote = remoteRegistry.getRemote(remoteId);
      if (!remote) {
        return res.status(404).json({ error: 'Remote server not found' });
      }

      try {
        const response = await fetch(`${remote.url}/api/sessions`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${remote.token}`, // Use remote's token
          },
          body: JSON.stringify({ command, workingDir, name }),
          signal: AbortSignal.timeout(10000), // 10 second timeout
        });

        if (!response.ok) {
          const error = await response.json().catch(() => ({ error: 'Unknown error' }));
          return res.status(response.status).json(error);
        }

        const result = await response.json();
        res.json(result); // Return sessionId as-is, no namespacing
        return;
      } catch (error) {
        console.error(`Failed to create session on remote ${remote.name}:`, error);
        return res.status(503).json({ error: 'Failed to create session on remote server' });
      }
    }

    // Create local session
    const sessionName = name || `session_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    const cwd = resolvePath(workingDir, process.cwd());

    console.log(`Creating session with PTY service: ${command.join(' ')} in ${cwd}`);

    const result = await ptyService.createSession(command, {
      sessionName,
      workingDir: cwd,
      term: 'xterm-256color',
      cols: 80,
      rows: 24,
    });

    console.log(`Session created with ID: ${result.sessionId}`);
    res.json({ sessionId: result.sessionId });
  } catch (error) {
    console.error('Error creating session:', error);
    if (error instanceof PtyError) {
      res.status(500).json({ error: 'Failed to create session', details: error.message });
    } else {
      res.status(500).json({ error: 'Failed to create session' });
    }
  }
});

// Kill session (just kill the process)
app.delete('/api/sessions/:sessionId', sessionProxy, async (req, res) => {
  const sessionId = req.params.sessionId;

  try {
    const session = ptyService.getSession(sessionId);

    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    await ptyService.killSession(sessionId, 'SIGTERM');
    console.log(`Session ${sessionId} killed`);

    res.json({ success: true, message: 'Session killed' });
  } catch (error) {
    console.error('Error killing session:', error);
    if (error instanceof PtyError) {
      res.status(500).json({ error: 'Failed to kill session', details: error.message });
    } else {
      res.status(500).json({ error: 'Failed to kill session' });
    }
  }
});

// Cleanup session files
app.delete('/api/sessions/:sessionId/cleanup', sessionProxy, async (req, res) => {
  const sessionId = req.params.sessionId;

  try {
    ptyService.cleanupSession(sessionId);
    console.log(`Session ${sessionId} cleaned up`);

    res.json({ success: true, message: 'Session cleaned up' });
  } catch (error) {
    console.error('Error cleaning up session:', error);
    if (error instanceof PtyError) {
      res.status(500).json({ error: 'Failed to cleanup session', details: error.message });
    } else {
      res.status(500).json({ error: 'Failed to cleanup session' });
    }
  }
});

// Cleanup all exited sessions (local and remote)
app.post('/api/cleanup-exited', async (req, res) => {
  try {
    // Clean up local sessions
    const localCleanedSessions = ptyService.cleanupExitedSessions();
    console.log(`Cleaned up ${localCleanedSessions.length} local exited sessions`);

    let totalCleaned = localCleanedSessions.length;
    const remoteResults: Array<{ remoteName: string; cleaned: number; error?: string }> = [];

    // If in HQ mode, clean up sessions on all remotes
    if (isHQMode && remoteRegistry) {
      const allRemotes = remoteRegistry.getRemotes();

      // Clean up on each remote in parallel
      const remoteCleanupPromises = allRemotes.map(async (remote) => {
        try {
          const response = await fetch(`${remote.url}/api/cleanup-exited`, {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              Authorization: `Bearer ${remote.token}`,
            },
            signal: AbortSignal.timeout(10000), // 10 second timeout
          });

          if (response.ok) {
            const result = await response.json();
            const cleanedCount = result.cleanedSessions?.length || 0;
            totalCleaned += cleanedCount;
            remoteResults.push({ remoteName: remote.name, cleaned: cleanedCount });
          } else {
            throw new Error(`HTTP ${response.status}`);
          }
        } catch (error) {
          console.error(`Failed to cleanup sessions on remote ${remote.name}:`, error);
          remoteResults.push({
            remoteName: remote.name,
            cleaned: 0,
            error: error instanceof Error ? error.message : 'Unknown error',
          });
        }
      });

      await Promise.all(remoteCleanupPromises);
    }

    res.json({
      success: true,
      message: `${totalCleaned} exited sessions cleaned up across all servers`,
      localCleaned: localCleanedSessions.length,
      remoteResults,
    });
  } catch (error) {
    console.error('Error cleaning up exited sessions:', error);
    if (error instanceof PtyError) {
      res.status(500).json({ error: 'Failed to cleanup exited sessions', details: error.message });
    } else {
      res.status(500).json({ error: 'Failed to cleanup exited sessions' });
    }
  }
});

// === TERMINAL I/O ===

// Live streaming cast file for XTerm renderer
app.get('/api/sessions/:sessionId/stream', sessionProxy, async (req, res) => {
  const sessionId = req.params.sessionId;
  const streamOutPath = path.join(CONTROL_DIR, sessionId, 'stream-out');

  if (!fs.existsSync(streamOutPath)) {
    return res.status(404).json({ error: 'Session not found' });
  }

  console.log(
    `[STREAM] New SSE client connected to session ${sessionId} from ${req.get('User-Agent')?.substring(0, 50) || 'unknown'}`
  );

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Cache-Control',
  });

  // Add client to stream watcher
  streamWatcher.addClient(sessionId, streamOutPath, res);

  // Cleanup when client disconnects
  const cleanup = () => {
    streamWatcher.removeClient(sessionId, res);
  };

  req.on('close', cleanup);
  req.on('aborted', cleanup);
  req.on('error', cleanup);
  res.on('close', cleanup);
  res.on('finish', cleanup);
});

// Get session snapshot (optimized cast with only content after last clear)
app.get('/api/sessions/:sessionId/snapshot', sessionProxy, (req, res) => {
  const sessionId = req.params.sessionId;
  const streamOutPath = path.join(CONTROL_DIR, sessionId, 'stream-out');

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

// Get session buffer stats
app.get('/api/sessions/:sessionId/buffer/stats', sessionProxy, async (req, res) => {
  const sessionId = req.params.sessionId;

  try {
    // Validate session exists
    const session = ptyService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    // Check if stream file exists
    const streamOutPath = path.join(CONTROL_DIR, sessionId, 'stream-out');
    if (!fs.existsSync(streamOutPath)) {
      return res.status(404).json({ error: 'Session stream not found' });
    }

    // Get terminal stats
    const stats = await terminalManager.getBufferStats(sessionId);

    // Add last modified time from stream file
    const fileStats = fs.statSync(streamOutPath);
    const statsWithLastModified = {
      ...stats,
      lastModified: fileStats.mtime.toISOString(),
    };

    res.json(statsWithLastModified);
  } catch (error) {
    console.error('Error getting session buffer stats:', error);
    res.status(500).json({ error: 'Failed to get session buffer stats' });
  }
});

// Get session buffer in binary or JSON format
app.get('/api/sessions/:sessionId/buffer', sessionProxy, async (req, res) => {
  const sessionId = req.params.sessionId;
  const format = (req.query.format as string) || 'binary';

  try {
    // Validate session exists
    const session = ptyService.getSession(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }

    // Check if stream file exists
    const streamOutPath = path.join(CONTROL_DIR, sessionId, 'stream-out');
    if (!fs.existsSync(streamOutPath)) {
      return res.status(404).json({ error: 'Session stream not found' });
    }

    // Get full buffer snapshot
    const snapshot = await terminalManager.getBufferSnapshot(sessionId);

    if (format === 'json') {
      // Send JSON response
      res.json(snapshot);
    } else {
      // Encode to binary format
      const binaryData = terminalManager.encodeSnapshot(snapshot);

      // Send binary response
      res.setHeader('Content-Type', 'application/octet-stream');
      res.setHeader('Content-Length', binaryData.length.toString());
      res.send(binaryData);
    }
  } catch (error) {
    console.error('Error getting session buffer:', error);
    res.status(500).json({ error: 'Failed to get session buffer' });
  }
});

// Send input to session
app.post('/api/sessions/:sessionId/input', sessionProxy, async (req, res) => {
  const sessionId = req.params.sessionId;
  const { text } = req.body;

  if (text === undefined || text === null) {
    return res.status(400).json({ error: 'Text is required' });
  }

  try {
    // Validate session exists
    const session = ptyService.getSession(sessionId);
    if (!session) {
      console.error(`Session ${sessionId} not found in active sessions`);
      return res.status(404).json({ error: 'Session not found' });
    }

    if (session.status !== 'running') {
      console.error(`Session ${sessionId} is not running (status: ${session.status})`);
      return res.status(400).json({ error: 'Session is not running' });
    }

    // Check if this is a special key
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

    if (isSpecialKey) {
      ptyService.sendInput(sessionId, {
        key: text as
          | 'arrow_up'
          | 'arrow_down'
          | 'arrow_left'
          | 'arrow_right'
          | 'escape'
          | 'enter'
          | 'ctrl_enter'
          | 'shift_enter',
      });
    } else {
      ptyService.sendInput(sessionId, { text });
    }

    res.json({ success: true });
  } catch (error) {
    console.error('Error sending input via PTY service:', error);
    if (error instanceof PtyError) {
      res.status(500).json({ error: 'Failed to send input', details: error.message });
    } else {
      res.status(500).json({ error: 'Failed to send input' });
    }
  }
});

// Resize session terminal
app.post('/api/sessions/:sessionId/resize', sessionProxy, async (req, res) => {
  const sessionId = req.params.sessionId;
  const { cols, rows } = req.body;

  if (typeof cols !== 'number' || typeof rows !== 'number') {
    return res.status(400).json({ error: 'Cols and rows must be numbers' });
  }

  if (cols < 1 || rows < 1 || cols > 1000 || rows > 1000) {
    return res.status(400).json({ error: 'Cols and rows must be between 1 and 1000' });
  }

  console.log(`Resizing session ${sessionId} to ${cols}x${rows}`);

  try {
    // Validate session exists
    const session = ptyService.getSession(sessionId);
    if (!session) {
      console.error(`Session ${sessionId} not found for resize`);
      return res.status(404).json({ error: 'Session not found' });
    }

    if (session.status !== 'running') {
      console.error(`Session ${sessionId} is not running (status: ${session.status})`);
      return res.status(400).json({ error: 'Session is not running' });
    }

    // Resize the session
    ptyService.resizeSession(sessionId, cols, rows);
    console.log(`Successfully resized session ${sessionId} to ${cols}x${rows}`);

    res.json({ success: true, cols, rows });
  } catch (error) {
    console.error('Error resizing session via PTY service:', error);
    if (error instanceof PtyError) {
      res.status(500).json({ error: 'Failed to resize session', details: error.message });
    } else {
      res.status(500).json({ error: 'Failed to resize session' });
    }
  }
});

// PTY service status endpoint
app.get('/api/pty/status', (req, res) => {
  try {
    const status = {
      implementation: ptyService.getCurrentImplementation(),
      usingNodePty: ptyService.isUsingNodePty(),
      usingTtyFwd: ptyService.isUsingTtyFwd(),
      activeSessionCount: ptyService.getActiveSessionCount(),
      controlPath: ptyService.getControlPath(),
      config: ptyService.getConfig(),
    };
    res.json(status);
  } catch (error) {
    console.error('Error getting PTY service status:', error);
    res.status(500).json({ error: 'Failed to get PTY service status' });
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
    const allowedBasePaths = [os.homedir(), process.cwd(), os.tmpdir()];
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

// Buffer magic byte
const BUFFER_MAGIC_BYTE = 0xbf;

// Handle buffer WebSocket connections
function handleBufferWebSocket(ws: WebSocket) {
  const subscriptions = new Map<string, () => void>();
  const remoteConnections = new Map<string, WebSocket>(); // remoteId -> WebSocket connection
  const remoteSubscriptions = new Map<string, Set<string>>(); // remoteId -> Set of sessionIds
  let pingInterval: NodeJS.Timeout | null = null;
  let lastPong = Date.now();

  console.log('[BUFFER WS] New client connected');

  // Start ping/pong heartbeat
  pingInterval = setInterval(() => {
    if (Date.now() - lastPong > 30000) {
      // No pong received for 30 seconds, close connection
      console.log('[BUFFER WS] Client timed out, closing connection');
      ws.close();
      return;
    }

    ws.send(JSON.stringify({ type: 'ping' }));
  }, 10000); // Ping every 10 seconds

  // Helper function to establish remote WebSocket connection
  const connectToRemote = async (remote: RemoteServer): Promise<WebSocket> => {
    // Check if we already have a connection
    const existingConnection = remoteConnections.get(remote.id);
    if (existingConnection && existingConnection.readyState === WebSocket.OPEN) {
      return existingConnection;
    }

    // Create new connection
    const remoteWsUrl = `${remote.url.replace(/^https:/, 'wss:').replace(/^http:/, 'ws:')}/buffers`;
    const headers = {
      Authorization: `Bearer ${remote.token}`,
    };

    console.log(`[BUFFER WS] Connecting to remote ${remote.name} at ${remoteWsUrl}`);

    const remoteWs = new WebSocket(remoteWsUrl, { headers });
    remoteConnections.set(remote.id, remoteWs);

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error('Remote connection timeout'));
        remoteWs.close();
      }, 10000);

      remoteWs.on('open', () => {
        clearTimeout(timeout);
        console.log(`[BUFFER WS] Connected to remote ${remote.name}`);

        // Initialize subscription tracking for this remote
        if (!remoteSubscriptions.has(remote.id)) {
          remoteSubscriptions.set(remote.id, new Set());
        }

        resolve(remoteWs);
      });

      remoteWs.on('error', (error) => {
        clearTimeout(timeout);
        console.error(`[BUFFER WS] Remote ${remote.name} connection error:`, error);
        reject(error);
      });

      remoteWs.on('close', () => {
        console.log(`[BUFFER WS] Remote ${remote.name} connection closed`);
        remoteConnections.delete(remote.id);

        // Attempt to reconnect if we still have subscriptions
        const subs = remoteSubscriptions.get(remote.id);
        if (subs && subs.size > 0) {
          setTimeout(() => {
            console.log(`[BUFFER WS] Attempting to reconnect to remote ${remote.name}`);
            connectToRemote(remote).catch(console.error);
          }, 5000);
        }
      });

      // Forward messages from remote to client
      remoteWs.on('message', (data) => {
        if (ws.readyState === WebSocket.OPEN) {
          // Check if it's a binary buffer message or JSON
          if (Buffer.isBuffer(data) && data.length > 0 && data[0] === BUFFER_MAGIC_BYTE) {
            // Forward binary buffer as-is
            ws.send(data);
          } else {
            // Handle JSON messages (like ping)
            try {
              const message = JSON.parse(data.toString());
              if (message.type === 'ping') {
                remoteWs.send(JSON.stringify({ type: 'pong' }));
              }
            } catch (_e) {
              // Not JSON, ignore
            }
          }
        }
      });
    });
  };

  // Handle incoming messages
  ws.on('message', async (data) => {
    try {
      const message = JSON.parse(data.toString());

      switch (message.type) {
        case 'subscribe': {
          const { sessionId } = message;
          if (!sessionId) {
            ws.send(JSON.stringify({ type: 'error', message: 'sessionId required' }));
            return;
          }

          // Check if already subscribed
          if (subscriptions.has(sessionId)) {
            console.log(`[BUFFER WS] Already subscribed to ${sessionId}`);
            return;
          }

          console.log(`[BUFFER WS] Subscribing to session ${sessionId}`);

          // Check if this is a remote session
          if (isHQMode && remoteRegistry) {
            const remote = remoteRegistry.getRemoteBySessionId(sessionId);
            if (remote) {
              console.log(`[BUFFER WS] Session ${sessionId} belongs to remote ${remote.name}`);

              try {
                // Connect to remote if not already connected
                const remoteWs = await connectToRemote(remote);

                // Subscribe to the session on the remote
                remoteWs.send(JSON.stringify({ type: 'subscribe', sessionId }));

                // Track this subscription
                const remoteSubs = remoteSubscriptions.get(remote.id) || new Set();
                remoteSubs.add(sessionId);
                remoteSubscriptions.set(remote.id, remoteSubs);

                // Create unsubscribe function
                const unsubscribe = () => {
                  const subs = remoteSubscriptions.get(remote.id);
                  if (subs) {
                    subs.delete(sessionId);
                    if (subs.size === 0) {
                      // No more subscriptions for this remote, close connection
                      const conn = remoteConnections.get(remote.id);
                      if (conn) {
                        conn.close();
                        remoteConnections.delete(remote.id);
                      }
                      remoteSubscriptions.delete(remote.id);
                    } else if (remoteWs.readyState === WebSocket.OPEN) {
                      // Unsubscribe from this specific session
                      remoteWs.send(JSON.stringify({ type: 'unsubscribe', sessionId }));
                    }
                  }
                };

                subscriptions.set(sessionId, unsubscribe);
                return;
              } catch (error) {
                console.error(
                  `[BUFFER WS] Failed to connect to remote for session ${sessionId}:`,
                  error
                );
                ws.send(
                  JSON.stringify({ type: 'error', message: 'Failed to connect to remote server' })
                );
                return;
              }
            }
          }

          // Local session - use terminalManager
          try {
            // Subscribe to buffer changes
            const unsubscribe = await terminalManager.subscribeToBufferChanges(
              sessionId,
              (sessionId: string, snapshot: BufferSnapshot) => {
                // Send binary buffer update
                sendBinaryBuffer(ws, sessionId, snapshot);
              }
            );

            subscriptions.set(sessionId, unsubscribe);

            // Send initial buffer state
            const initialSnapshot = await terminalManager.getBufferSnapshot(sessionId);
            sendBinaryBuffer(ws, sessionId, initialSnapshot);
          } catch (error) {
            console.error(`[BUFFER WS] Error subscribing to ${sessionId}:`, error);
            ws.send(JSON.stringify({ type: 'error', message: 'Failed to subscribe to session' }));
          }
          break;
        }

        case 'unsubscribe': {
          const { sessionId } = message;
          if (!sessionId) {
            ws.send(JSON.stringify({ type: 'error', message: 'sessionId required' }));
            return;
          }

          const unsubscribe = subscriptions.get(sessionId);
          if (unsubscribe) {
            console.log(`[BUFFER WS] Unsubscribing from session ${sessionId}`);
            unsubscribe();
            subscriptions.delete(sessionId);
          }
          break;
        }

        case 'pong': {
          lastPong = Date.now();
          break;
        }

        default:
          ws.send(JSON.stringify({ type: 'error', message: 'Unknown message type' }));
      }
    } catch (error) {
      console.error('[BUFFER WS] Error handling message:', error);
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid message format' }));
    }
  });

  // Clean up on disconnect
  ws.on('close', () => {
    console.log('[BUFFER WS] Client disconnected');

    // Unsubscribe from all sessions
    subscriptions.forEach((unsubscribe) => unsubscribe());
    subscriptions.clear();

    // Close all remote connections
    remoteConnections.forEach((remoteWs) => remoteWs.close());
    remoteConnections.clear();
    remoteSubscriptions.clear();

    // Clear ping interval
    if (pingInterval) {
      clearInterval(pingInterval);
    }
  });

  ws.on('error', (error) => {
    console.error('[BUFFER WS] WebSocket error:', error);
  });
}

// Send binary buffer to WebSocket client
function sendBinaryBuffer(ws: WebSocket, sessionId: string, snapshot: BufferSnapshot) {
  try {
    // Encode buffer
    const bufferData = terminalManager.encodeSnapshot(snapshot);

    // Create binary message: [magic byte][4 bytes: session ID length][session ID][buffer data]
    const sessionIdBuffer = Buffer.from(sessionId, 'utf8');
    const message = Buffer.allocUnsafe(1 + 4 + sessionIdBuffer.length + bufferData.length);

    let offset = 0;

    // Magic byte
    message.writeUInt8(BUFFER_MAGIC_BYTE, offset);
    offset += 1;

    // Session ID length (4 bytes, little-endian)
    message.writeUInt32LE(sessionIdBuffer.length, offset);
    offset += 4;

    // Session ID
    sessionIdBuffer.copy(message, offset);
    offset += sessionIdBuffer.length;

    // Buffer data
    bufferData.copy(message, offset);

    // Send binary message
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(message);
    }
  } catch (error) {
    console.error(`[BUFFER WS] Error sending buffer for ${sessionId}:`, error);
  }
}

// WebSocket connections
wss.on('connection', (ws, req) => {
  // Check authentication for WebSocket connections
  if ((basicAuthUsername && basicAuthPassword) || hqClient) {
    const authHeader = req.headers.authorization;

    if (!authHeader) {
      ws.close(1008, 'Authentication required');
      return;
    }

    let authenticated = false;

    // Check Bearer token first (if we're a remote that registered with HQ)
    if (authHeader.startsWith('Bearer ') && hqClient) {
      const token = authHeader.slice(7);
      if (token === hqClient.getToken()) {
        authenticated = true;
      }
    }

    // Check Basic Auth
    if (
      !authenticated &&
      authHeader.startsWith('Basic ') &&
      basicAuthUsername &&
      basicAuthPassword
    ) {
      const base64Credentials = authHeader.slice(6);
      const credentials = Buffer.from(base64Credentials, 'base64').toString('utf-8');
      const [username, password] = credentials.split(':');

      if (username === basicAuthUsername && password === basicAuthPassword) {
        authenticated = true;
      }
    }

    if (!authenticated) {
      ws.close(1008, 'Invalid credentials');
      return;
    }
  }

  const url = new URL(req.url ?? '', `http://${req.headers.host}`);
  const isHotReload = url.searchParams.get('hotReload') === 'true';

  if (isHotReload) {
    hotReloadClients.add(ws);
    ws.on('close', () => {
      hotReloadClients.delete(ws);
    });
    return;
  }

  // Check if this is a buffer subscription connection
  if (url.pathname === '/buffers') {
    handleBufferWebSocket(ws);
    return;
  }

  ws.close(1008, 'Unknown WebSocket endpoint');
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
    console.log(`VibeTunnel Server running on http://localhost:${PORT}`);
    if (basicAuthUsername && basicAuthPassword) {
      console.log(`${GREEN}Basic authentication: ENABLED${RESET}`);
      console.log(`Username: ${basicAuthUsername}`);
      console.log(`Password: ${basicAuthPassword}`);
    } else {
      console.log(`${RED}⚠️  WARNING: Server running without authentication!${RESET}`);
      console.log(
        `${YELLOW}Anyone can access this server. Use --username and --password or set VIBETUNNEL_USERNAME and VIBETUNNEL_PASSWORD.${RESET}`
      );
    }

    if (hqClient) {
      console.log(`${GREEN}Remote mode: Will accept Bearer token for HQ access${RESET}`);
      console.log(`Token: ${hqClient.getToken()}`);
    }

    // Register with HQ if configured
    if (hqClient) {
      hqClient.register().catch((err) => {
        console.error('Failed to register with HQ:', err);
      });
    }
  });

  // Cleanup old terminals every 5 minutes
  setInterval(
    () => {
      terminalManager.cleanup(30 * 60 * 1000); // 30 minutes
    },
    5 * 60 * 1000
  );

  // Graceful shutdown
  process.on('SIGINT', async () => {
    console.log('\nShutting down...');

    if (hqClient) {
      await hqClient.destroy();
    }

    if (remoteRegistry) {
      remoteRegistry.destroy();
    }

    server.close(() => {
      process.exit(0);
    });
  });
}

// Export for testing
export { app, server, wss };
