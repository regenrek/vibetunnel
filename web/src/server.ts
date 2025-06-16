import express from 'express';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { spawn } from 'child_process';

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ server });

const PORT = process.env.PORT || 3000;

// tty-fwd binary path - check multiple possible locations
const possibleTtyFwdPaths = [
    path.resolve(__dirname, '..', '..', 'tty-fwd', 'target', 'release', 'tty-fwd'),
    path.resolve(__dirname, '..', '..', '..', 'tty-fwd', 'target', 'release', 'tty-fwd'),
    'tty-fwd' // System PATH
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

const TTY_FWD_CONTROL_DIR = process.env.TTY_FWD_CONTROL_DIR || path.join(os.homedir(), '.vibetunnel');

// Ensure control directory exists
if (!fs.existsSync(TTY_FWD_CONTROL_DIR)) {
    fs.mkdirSync(TTY_FWD_CONTROL_DIR, { recursive: true });
    console.log(`Created control directory: ${TTY_FWD_CONTROL_DIR}`);
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
    status: "running" | "exited";
    stdin: string;
    "stream-out": string;
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
const hotReloadClients = new Set<any>();

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
                if (fs.existsSync(sessionInfo["stream-out"])) {
                    const stats = fs.statSync(sessionInfo["stream-out"]);
                    lastModified = stats.mtime.toISOString();
                }
            } catch (e) {
                // Use started_at as fallback
            }

            return {
                id: sessionId,
                command: sessionInfo.cmdline.join(' '),
                workingDir: sessionInfo.cwd,
                status: sessionInfo.status,
                exitCode: sessionInfo.exit_code,
                startedAt: sessionInfo.started_at,
                lastModified: lastModified,
                pid: sessionInfo.pid
            };
        });

        // Sort by lastModified, most recent first
        sessionData.sort((a, b) => new Date(b.lastModified).getTime() - new Date(a.lastModified).getTime());
        res.json(sessionData);
    } catch (error) {
        console.error('Failed to list sessions:', error);
        res.status(500).json({ error: 'Failed to list sessions' });
    }
});

// Create new session
app.post('/api/sessions', async (req, res) => {
    try {
        const { command, workingDir } = req.body;

        if (!command || !Array.isArray(command) || command.length === 0) {
            return res.status(400).json({ error: 'Command array is required and cannot be empty' });
        }

        const sessionName = `session_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
        const cwd = resolvePath(workingDir, process.cwd());

        const args = [
            '--control-path', TTY_FWD_CONTROL_DIR,
            '--session-name', sessionName,
            '--'
        ].concat(command);

        console.log(`Creating session: ${TTY_FWD_PATH} ${args.join(' ')}`);

        const child = spawn(TTY_FWD_PATH, args, {
            cwd: cwd,
            detached: false,
            stdio: 'pipe'
        });

        // Log output for debugging
        child.stdout.on('data', (data) => {
            console.log(`Session ${sessionName} stdout:`, data.toString());
        });

        child.stderr.on('data', (data) => {
            console.log(`Session ${sessionName} stderr:`, data.toString());
        });

        child.on('close', (code) => {
            console.log(`Session ${sessionName} exited with code: ${code}`);
        });

        // Respond immediately - don't wait for completion
        res.json({ sessionId: sessionName });

    } catch (error) {
        console.error('Error creating session:', error);
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
                    } catch (e) {
                        // Process already dead
                    }
                }, 1000);
            } catch (error) {
                // Process already dead
            }
        }

        res.json({ success: true, message: 'Session killed' });

    } catch (error) {
        console.error('Error killing session:', error);
        res.status(500).json({ error: 'Failed to kill session' });
    }
});

// Cleanup session files
app.delete('/api/sessions/:sessionId/cleanup', async (req, res) => {
    const sessionId = req.params.sessionId;

    try {
        await executeTtyFwd([
            '--control-path', TTY_FWD_CONTROL_DIR,
            '--session', sessionId,
            '--cleanup'
        ]);

        res.json({ success: true, message: 'Session cleaned up' });

    } catch (error) {
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
        await executeTtyFwd([
            '--control-path', TTY_FWD_CONTROL_DIR,
            '--cleanup'
        ]);

        res.json({ success: true, message: 'All exited sessions cleaned up' });

    } catch (error) {
        console.error('Error cleaning up exited sessions:', error);
        res.status(500).json({ error: 'Failed to cleanup exited sessions' });
    }
});

// === TERMINAL I/O ===

// Live streaming cast file for asciinema player
app.get('/api/sessions/:sessionId/stream', async (req, res) => {
    const sessionId = req.params.sessionId;
    const streamOutPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'stream-out');

    if (!fs.existsSync(streamOutPath)) {
        return res.status(404).json({ error: 'Session not found' });
    }

    res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Cache-Control'
    });

    const startTime = Date.now() / 1000;
    let headerSent = false;

    // Send existing content first
    // NOTE: Small race condition possible between reading file and starting tail
    try {
        const content = fs.readFileSync(streamOutPath, 'utf8');
        const lines = content.trim().split('\n');

        for (const line of lines) {
            if (line.trim()) {
                try {
                    const parsed = JSON.parse(line);
                    if (parsed.version && parsed.width && parsed.height) {
                        res.write(`data: ${line}\n\n`);
                        headerSent = true;
                    } else if (Array.isArray(parsed) && parsed.length >= 3) {
                        const instantEvent = [0, parsed[1], parsed[2]];
                        res.write(`data: ${JSON.stringify(instantEvent)}\n\n`);
                    }
                } catch (e) {
                    // Skip invalid lines
                }
            }
        }
    } catch (error) {
        console.error('Error reading existing content:', error);
    }

    // Send default header if none found
    if (!headerSent) {
        const defaultHeader = {
            version: 2,
            width: 80,
            height: 24,
            timestamp: Math.floor(startTime),
            env: { TERM: "xterm-256color" }
        };
        res.write(`data: ${JSON.stringify(defaultHeader)}\n\n`);
    }

    // Stream new content
    const tailProcess = spawn('tail', ['-f', streamOutPath]);
    let buffer = '';
    let streamCleanedUp = false;

    const cleanup = () => {
        if (!streamCleanedUp) {
            streamCleanedUp = true;
            console.log(`Cleaning up tail process for session ${sessionId}`);
            tailProcess.kill('SIGTERM');
        }
    };

    // Get the session info once to get the PID
    let sessionPid: number | null = null;
    try {
        const output = await executeTtyFwd(['--control-path', TTY_FWD_CONTROL_DIR, '--list-sessions']);
        const sessions: TtyFwdListResponse = JSON.parse(output || '{}');
        if (sessions[sessionId]) {
            sessionPid = sessions[sessionId].pid;
        }
    } catch (error) {
        console.error('Error getting session PID:', error);
    }

    // Set a timeout to check if process is still alive
    const sessionCheckInterval = setInterval(() => {
        if (sessionPid) {
            try {
                // Signal 0 just checks if process exists without actually sending a signal
                process.kill(sessionPid, 0);
            } catch (error) {
                console.log(`Session ${sessionId} process ${sessionPid} has died, terminating stream`);
                clearInterval(sessionCheckInterval);
                cleanup();
                res.end();
            }
        } else {
            // If we don't have a PID, fall back to checking session status
            console.log(`No PID found for session ${sessionId}, terminating stream`);
            clearInterval(sessionCheckInterval);
            cleanup();
            res.end();
        }
    }, 2000); // Check every 2 seconds

    tailProcess.stdout.on('data', (chunk) => {
        if (streamCleanedUp) return;
        
        buffer += chunk.toString();
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
            if (line.trim()) {
                try {
                    const parsed = JSON.parse(line);
                    if (parsed.version && parsed.width && parsed.height) {
                        return; // Skip duplicate headers
                    }
                    if (Array.isArray(parsed) && parsed.length >= 3) {
                        const currentTime = Date.now() / 1000;
                        const realTimeEvent = [currentTime - startTime, parsed[1], parsed[2]];
                        res.write(`data: ${JSON.stringify(realTimeEvent)}\n\n`);
                    }
                } catch (e) {
                    // Handle non-JSON as raw output
                    const currentTime = Date.now() / 1000;
                    const castEvent = [currentTime - startTime, "o", line];
                    res.write(`data: ${JSON.stringify(castEvent)}\n\n`);
                }
            }
        }
    });

    tailProcess.on('error', (error) => {
        console.error(`Tail process error for session ${sessionId}:`, error);
        clearInterval(sessionCheckInterval);
        cleanup();
    });

    tailProcess.on('exit', (code) => {
        console.log(`Tail process exited for session ${sessionId} with code ${code}`);
        clearInterval(sessionCheckInterval);
        cleanup();
    });

    // Cleanup on disconnect
    req.on('close', () => {
        clearInterval(sessionCheckInterval);
        cleanup();
    });
    
    req.on('aborted', () => {
        clearInterval(sessionCheckInterval);
        cleanup();
    });
});

// Get session snapshot (asciinema cast with adjusted timestamps for immediate playback)
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
        const events = [];
        let startTime = null;

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
                        if (startTime === null) {
                            startTime = parsed[0];
                        }
                        events.push([0, parsed[1], parsed[2]]);
                    }
                } catch (e) {
                    // Skip invalid lines
                }
            }
        }

        // Build the complete asciinema cast
        const cast = [];

        // Add header if found, otherwise use default
        if (header) {
            cast.push(JSON.stringify(header));
        } else {
            cast.push(JSON.stringify({
                version: 2,
                width: 80,
                height: 24,
                timestamp: Math.floor(Date.now() / 1000),
                env: { TERM: "xterm-256color" }
            }));
        }

        // Add all events
        events.forEach(event => {
            cast.push(JSON.stringify(event));
        });

        res.setHeader('Content-Type', 'text/plain');
        res.send(cast.join('\n'));

    } catch (error) {
        console.error('Error reading session snapshot:', error);
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
            } catch (error) {
                console.error(`Session ${sessionId} process ${session.pid} is dead, cleaning up`);
                // Try to cleanup the stale session
                try {
                    await executeTtyFwd([
                        '--control-path', TTY_FWD_CONTROL_DIR,
                        '--session', sessionId,
                        '--cleanup'
                    ]);
                } catch (cleanupError) {
                    console.error('Failed to cleanup stale session:', cleanupError);
                }
                return res.status(410).json({ error: 'Session process has died' });
            }
        }

        // Check if this is a special key that should use --send-key
        const specialKeys = ['arrow_up', 'arrow_down', 'arrow_left', 'arrow_right', 'escape', 'enter'];
        const isSpecialKey = specialKeys.includes(text);

        const startTime = Date.now();
        
        if (isSpecialKey) {
            await executeTtyFwd([
                '--control-path', TTY_FWD_CONTROL_DIR,
                '--session', sessionId,
                '--send-key', text
            ]);
            console.log(`Successfully sent key: ${text} (${Date.now() - startTime}ms)`);
        } else {
            await executeTtyFwd([
                '--control-path', TTY_FWD_CONTROL_DIR,
                '--session', sessionId,
                '--send-text', text
            ]);
            console.log(`Successfully sent text: ${text} (${Date.now() - startTime}ms)`);
        }

        res.json({ success: true });

    } catch (error) {
        console.error('Error sending input via tty-fwd:', error);
        const errorMessage = error instanceof Error ? error.message : 'Unknown error';
        res.status(500).json({ error: 'Failed to send input', details: errorMessage });
    }
});

// === FILE SYSTEM ===

// Directory listing for file browser
app.get('/api/fs/browse', (req, res) => {
    const dirPath = req.query.path as string || '~';

    try {
        const expandedPath = resolvePath(dirPath, '~');

        if (!fs.existsSync(expandedPath)) {
            return res.status(404).json({ error: 'Directory not found' });
        }

        const stats = fs.statSync(expandedPath);
        if (!stats.isDirectory()) {
            return res.status(400).json({ error: 'Path is not a directory' });
        }

        const files = fs.readdirSync(expandedPath).map(name => {
            const filePath = path.join(expandedPath, name);
            const fileStats = fs.statSync(filePath);

            return {
                name,
                created: fileStats.birthtime.toISOString(),
                lastModified: fileStats.mtime.toISOString(),
                size: fileStats.size,
                isDir: fileStats.isDirectory()
            };
        });

        res.json({
            absolutePath: expandedPath,
            files: files.sort((a, b) => {
                // Directories first, then files
                if (a.isDir && !b.isDir) return -1;
                if (!a.isDir && b.isDir) return 1;
                return a.name.localeCompare(b.name);
            })
        });

    } catch (error) {
        console.error('Error listing directory:', error);
        res.status(500).json({ error: 'Failed to list directory' });
    }
});

// === WEBSOCKETS ===

// WebSocket for hot reload
wss.on('connection', (ws, req) => {
    const url = new URL(req.url!, `http://${req.headers.host}`);
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
        persistent: true
    });

    watcher.on('change', (path: string) => {
        console.log(`File changed: ${path}`);
        hotReloadClients.forEach((ws: any) => {
            if (ws.readyState === ws.OPEN) {
                ws.send(JSON.stringify({ type: 'reload' }));
            }
        });
    });
}

server.listen(PORT, () => {
    console.log(`VibeTunnel New Server running on http://localhost:${PORT}`);
    console.log(`Using tty-fwd: ${TTY_FWD_PATH}`);
});