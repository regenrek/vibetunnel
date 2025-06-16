import express from 'express';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { spawn } from 'child_process';
import * as pty from 'node-pty';

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
    // Try to find in PATH
    try {
        const result = spawn('which', ['tty-fwd'], { stdio: 'pipe' });
        result.stdout.on('data', (data) => {
            TTY_FWD_PATH = data.toString().trim();
        });
    } catch (e) {
        console.error('tty-fwd binary not found. Please ensure it is built and available.');
        process.exit(1);
    }
}

const TTY_FWD_CONTROL_DIR = path.join(os.homedir(), '.vibetunnel');

// Ensure control directory exists
if (!fs.existsSync(TTY_FWD_CONTROL_DIR)) {
    fs.mkdirSync(TTY_FWD_CONTROL_DIR, { recursive: true });
    console.log(`Created control directory: ${TTY_FWD_CONTROL_DIR}`);
}

console.log(`Using tty-fwd at: ${TTY_FWD_PATH}`);
console.log(`Control directory: ${TTY_FWD_CONTROL_DIR}`);

// Parse JSON bodies
app.use(express.json());

// Hot reload functionality for development
const hotReloadClients = new Set<any>();

// Serve static files
app.use(express.static(path.join(__dirname, '..', 'public')));

// Thin wrapper: Get sessions by calling tty-fwd --list-sessions
app.get('/api/sessions', async (req, res) => {
    try {
        const child = spawn(TTY_FWD_PATH, ['--control-path', TTY_FWD_CONTROL_DIR, '--list-sessions']);
        let output = '';
        
        child.stdout.on('data', (data) => {
            output += data.toString();
        });
        
        child.on('close', (code) => {
            if (code === 0) {
                try {
                    const sessions = JSON.parse(output || '{}');
                    const sessionData = [];
                    
                    for (const [sessionId, sessionInfo] of Object.entries(sessions as Record<string, any>)) {
                        const sessionPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'session.json');
                        const streamOutPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'stream-out');
                        
                        let metadata = null;
                        let lastModified = new Date().toISOString();
                        
                        if (fs.existsSync(sessionPath)) {
                            metadata = JSON.parse(fs.readFileSync(sessionPath, 'utf8'));
                        }
                        
                        if (fs.existsSync(streamOutPath)) {
                            const stats = fs.statSync(streamOutPath);
                            lastModified = stats.mtime.toISOString();
                        }
                        
                        sessionData.push({
                            id: sessionId,
                            status: sessionInfo.status,
                            metadata: metadata,
                            lastModified: lastModified
                        });
                    }
                    
                    sessionData.sort((a, b) => new Date(b.lastModified).getTime() - new Date(a.lastModified).getTime());
                    res.json(sessionData);
                } catch (error) {
                    res.json([]);
                }
            } else {
                res.status(500).json({ error: 'Failed to list sessions' });
            }
        });
        
        child.on('error', (error) => {
            res.status(500).json({ error: 'Failed to execute tty-fwd' });
        });
    } catch (error) {
        res.status(500).json({ error: 'Internal server error' });
    }
});

// Thin wrapper: Create session by calling tty-fwd
app.post('/api/sessions', async (req, res) => {
    try {
        const { command, workingDir } = req.body;
        
        if (!command || !Array.isArray(command)) {
            return res.status(400).json({ error: 'Command array is required' });
        }
        
        const sessionName = `session_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
        const cwd = workingDir ? (workingDir.startsWith('~') ? 
            path.join(os.homedir(), workingDir.slice(2)) : 
            path.resolve(workingDir)) : process.cwd();
        
        const fullCommand = command.join(' ');
        const commandLine = `${TTY_FWD_PATH} --control-path "${TTY_FWD_CONTROL_DIR}" --session-name "${sessionName}" -- ${fullCommand}`;
        
        console.log(`Creating session: ${commandLine}`);
        
        const ptyProcess = pty.spawn('bash', ['-c', commandLine], {
            name: 'xterm-color',
            cols: 80,
            rows: 24,
            cwd: cwd,
            env: process.env
        });
        
        // Detach after short delay
        setTimeout(() => {
            ptyProcess.kill();
        }, 1000);
        
        setTimeout(() => {
            res.json({ sessionName });
        }, 500);
        
    } catch (error) {
        console.error('Error creating session:', error);
        res.status(500).json({ error: 'Failed to create session' });
    }
});

// Server-Sent Events for streaming - preserving the existing streaming functionality
app.get('/api/stream/:sessionId', (req, res) => {
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
    
    // Send existing content
    try {
        const content = fs.readFileSync(streamOutPath, 'utf8');
        const lines = content.trim().split('\n');
        
        if (lines.length > 0) {
            try {
                const header = JSON.parse(lines[0]);
                if (header.version && header.width && header.height) {
                    res.write(`data: ${lines[0]}\n\n`);
                    headerSent = true;
                    
                    // Send existing events with instant timestamp
                    for (let i = 1; i < lines.length; i++) {
                        if (lines[i].trim()) {
                            try {
                                const event = JSON.parse(lines[i]);
                                if (Array.isArray(event) && event.length >= 3) {
                                    const instantEvent = [0, event[1], event[2]];
                                    res.write(`data: ${JSON.stringify(instantEvent)}\n\n`);
                                }
                            } catch (e) {
                                // Skip invalid lines
                            }
                        }
                    }
                }
            } catch (e) {
                // Skip invalid header
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
        headerSent = true;
    }
    
    // Use tail -f to follow new content
    const tailProcess = spawn('tail', ['-f', streamOutPath], {
        stdio: ['ignore', 'pipe', 'pipe']
    });
    
    let buffer = '';
    
    tailProcess.stdout.on('data', (chunk) => {
        buffer += chunk.toString();
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';
        
        lines.forEach(line => {
            if (line.trim()) {
                try {
                    const parsed = JSON.parse(line);
                    if (parsed.version && parsed.width && parsed.height) {
                        return; // Skip duplicate headers
                    }
                    
                    if (Array.isArray(parsed) && parsed.length >= 3) {
                        const currentTime = Date.now() / 1000;
                        const relativeTime = currentTime - startTime;
                        const realTimeEvent = [relativeTime, parsed[1], parsed[2]];
                        res.write(`data: ${JSON.stringify(realTimeEvent)}\n\n`);
                    }
                } catch (e) {
                    // Handle non-JSON lines as raw output
                    const currentTime = Date.now() / 1000;
                    const relativeTime = currentTime - startTime;
                    const castEvent = [relativeTime, "o", line];
                    res.write(`data: ${JSON.stringify(castEvent)}\n\n`);
                }
            }
        });
    });
    
    // Cleanup on disconnect
    req.on('close', () => {
        tailProcess.kill('SIGTERM');
    });
    
    req.on('aborted', () => {
        tailProcess.kill('SIGTERM');
    });
});

// Input endpoint for sending text/keys to sessions (like old working version)
app.post('/api/input/:sessionId', (req, res) => {
    const sessionId = req.params.sessionId;
    const { type, value, text } = req.body;
    
    const inputValue = value || text;
    
    if (inputValue === undefined || inputValue === null) {
        return res.status(400).json({ error: 'Input value is required' });
    }
    
    console.log(`Sending input to session ${sessionId}:`, JSON.stringify(inputValue));
    
    // Write directly to stdin file like the old working version
    const stdinPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'stdin');
    
    if (!fs.existsSync(stdinPath)) {
        return res.status(404).json({ error: 'Session stdin not found' });
    }
    
    try {
        // Write the text directly to the stdin named pipe
        fs.writeFileSync(stdinPath, inputValue, { encoding: 'binary' });
        console.log(`Successfully wrote ${inputValue.length} bytes to stdin for session ${sessionId}`);
        res.json({ success: true });
    } catch (error) {
        console.error('Error writing to stdin:', error);
        
        // Fallback: try using tty-fwd commands based on input type
        console.log('Falling back to tty-fwd commands');
        
        // Check if this is a special key that should use --send-key
        const specialKeys = ['arrow_up', 'arrow_down', 'arrow_left', 'arrow_right', 'escape', 'enter'];
        const isSpecialKey = specialKeys.includes(inputValue);
        
        let sendCommand;
        if (isSpecialKey) {
            // Use --send-key for special keys
            sendCommand = `${TTY_FWD_PATH} --control-path "${TTY_FWD_CONTROL_DIR}" --session "${sessionId}" --send-key "${inputValue}"`;
            console.log(`Using --send-key for: ${inputValue}`);
        } else if (typeof inputValue === 'string' && inputValue.length <= 10 && inputValue.charCodeAt(0) < 127) {
            // Use --send-text for regular text
            const escapedText = inputValue.replace(/'/g, "'\"'\"'");
            sendCommand = `${TTY_FWD_PATH} --control-path "${TTY_FWD_CONTROL_DIR}" --session "${sessionId}" --send-text '${escapedText}'`;
            console.log(`Using --send-text for: ${inputValue}`);
        } else {
            console.error('Input value not supported by tty-fwd fallback:', inputValue);
            return res.status(500).json({ error: 'Input type not supported' });
        }
        
        const inputChild = spawn('bash', ['-c', sendCommand], {
            stdio: 'ignore'
        });
        
        inputChild.on('error', (error) => {
            console.error('Error sending input via tty-fwd:', error);
            return res.status(500).json({ error: 'Failed to send input' });
        });
        
        inputChild.on('close', (code) => {
            if (code === 0) {
                console.log(`Successfully sent input via tty-fwd: ${inputValue}`);
                res.json({ success: true });
            } else {
                console.error(`tty-fwd failed with code: ${code}`);
                res.status(500).json({ error: 'Failed to send input' });
            }
        });
    }
});

// Thin wrapper: Kill session by calling tty-fwd
app.delete('/api/sessions/:sessionId', (req, res) => {
    const sessionId = req.params.sessionId;
    
    // Get session info first
    const sessionsChild = spawn(TTY_FWD_PATH, ['--control-path', TTY_FWD_CONTROL_DIR, '--list-sessions']);
    let output = '';
    
    sessionsChild.stdout.on('data', (data) => {
        output += data.toString();
    });
    
    sessionsChild.on('close', (code) => {
        if (code === 0) {
            try {
                const sessions = JSON.parse(output || '{}');
                const session = sessions[sessionId];
                
                if (session && session.pid) {
                    try {
                        process.kill(session.pid, 'SIGTERM');
                        setTimeout(() => {
                            try {
                                process.kill(session.pid, 0);
                                process.kill(session.pid, 'SIGKILL');
                            } catch (e) {
                                // Process already dead
                            }
                        }, 1000);
                    } catch (error) {
                        // Process already dead
                    }
                }
                
                // Cleanup using tty-fwd
                setTimeout(() => {
                    const cleanupChild = spawn(TTY_FWD_PATH, [
                        '--control-path', TTY_FWD_CONTROL_DIR, 
                        '--session', sessionId, 
                        '--cleanup'
                    ]);
                    
                    cleanupChild.on('close', (cleanupCode) => {
                        if (cleanupCode !== 0) {
                            // Force remove if cleanup failed
                            const sessionDir = path.join(TTY_FWD_CONTROL_DIR, sessionId);
                            try {
                                if (fs.existsSync(sessionDir)) {
                                    fs.rmSync(sessionDir, { recursive: true, force: true });
                                }
                            } catch (error) {
                                console.error('Error force removing session directory:', error);
                            }
                        }
                    });
                }, 1000);
                
                res.json({ success: true, message: 'Session killed' });
                
            } catch (error) {
                console.error('Error parsing sessions:', error);
                res.status(500).json({ error: 'Failed to get session info' });
            }
        } else {
            res.status(500).json({ error: 'Failed to list sessions' });
        }
    });
});

// Directory listing endpoint (needed by frontend)
app.get('/api/ls', (req, res) => {
    const dirPath = req.query.dir as string || '~';
    
    try {
        const expandedPath = dirPath.startsWith('~') ? 
            path.join(os.homedir(), dirPath.slice(1)) : 
            path.resolve(dirPath);
        
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
    console.log(`VibeTunnel server running on http://localhost:${PORT}`);
    console.log(`Using tty-fwd: ${TTY_FWD_PATH}`);
});