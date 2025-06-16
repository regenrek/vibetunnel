"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = __importDefault(require("express"));
const http_1 = require("http");
const ws_1 = require("ws");
const path_1 = __importDefault(require("path"));
const fs_1 = __importDefault(require("fs"));
const os_1 = __importDefault(require("os"));
const child_process_1 = require("child_process");
const app = (0, express_1.default)();
const server = (0, http_1.createServer)(app);
const wss = new ws_1.WebSocketServer({ server });
const PORT = process.env.PORT || 3000;
// tty-fwd binary path - check multiple possible locations
const possibleTtyFwdPaths = [
    path_1.default.resolve(__dirname, '..', '..', 'tty-fwd', 'target', 'release', 'tty-fwd'),
    path_1.default.resolve(__dirname, '..', '..', '..', 'tty-fwd', 'target', 'release', 'tty-fwd'),
    'tty-fwd' // System PATH
];
let TTY_FWD_PATH = '';
for (const pathToCheck of possibleTtyFwdPaths) {
    if (fs_1.default.existsSync(pathToCheck)) {
        TTY_FWD_PATH = pathToCheck;
        break;
    }
}
if (!TTY_FWD_PATH) {
    console.error('tty-fwd binary not found. Please ensure it is built and available.');
    process.exit(1);
}
const TTY_FWD_CONTROL_DIR = process.env.TTY_FWD_CONTROL_DIR || path_1.default.join(os_1.default.homedir(), '.vibetunnel');
// Ensure control directory exists
if (!fs_1.default.existsSync(TTY_FWD_CONTROL_DIR)) {
    fs_1.default.mkdirSync(TTY_FWD_CONTROL_DIR, { recursive: true });
    console.log(`Created control directory: ${TTY_FWD_CONTROL_DIR}`);
}
console.log(`Using tty-fwd at: ${TTY_FWD_PATH}`);
console.log(`Control directory: ${TTY_FWD_CONTROL_DIR}`);
// Helper function to execute tty-fwd commands
async function executeTtyFwd(args) {
    return new Promise((resolve, reject) => {
        const child = (0, child_process_1.spawn)(TTY_FWD_PATH, args);
        let output = '';
        child.stdout.on('data', (data) => {
            output += data.toString();
        });
        child.on('close', (code) => {
            if (code === 0) {
                resolve(output);
            }
            else {
                reject(new Error(`tty-fwd failed with code ${code}`));
            }
        });
        child.on('error', (error) => {
            reject(error);
        });
    });
}
// Helper function to resolve paths with ~ expansion
function resolvePath(inputPath, fallback) {
    if (!inputPath) {
        return fallback || process.cwd();
    }
    if (inputPath.startsWith('~')) {
        return path_1.default.join(os_1.default.homedir(), inputPath.slice(1));
    }
    return path_1.default.resolve(inputPath);
}
// Middleware
app.use(express_1.default.json());
app.use(express_1.default.static(path_1.default.join(__dirname, '..', 'public')));
// Hot reload functionality for development
const hotReloadClients = new Set();
// === SESSION MANAGEMENT ===
// List all sessions
app.get('/api/sessions', async (req, res) => {
    try {
        const output = await executeTtyFwd(['--control-path', TTY_FWD_CONTROL_DIR, '--list-sessions']);
        const sessions = JSON.parse(output || '{}');
        const sessionData = Object.entries(sessions).map(([sessionId, sessionInfo]) => {
            // Get actual last modified time from stream-out file
            let lastModified = sessionInfo.started_at;
            try {
                if (fs_1.default.existsSync(sessionInfo["stream-out"])) {
                    const stats = fs_1.default.statSync(sessionInfo["stream-out"]);
                    lastModified = stats.mtime.toISOString();
                }
            }
            catch (e) {
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
    }
    catch (error) {
        console.error('Failed to list sessions:', error);
        res.status(500).json({ error: 'Failed to list sessions' });
    }
});
// Create new session
app.post('/api/sessions', async (req, res) => {
    try {
        const { command, workingDir } = req.body;
        if (!command || !Array.isArray(command)) {
            return res.status(400).json({ error: 'Command array is required' });
        }
        const sessionName = `session_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
        const cwd = resolvePath(workingDir, process.cwd());
        const args = [
            '--control-path', TTY_FWD_CONTROL_DIR,
            '--session-name', sessionName,
            '--'
        ].concat(command);
        console.log(`Creating session: ${TTY_FWD_PATH} ${args.join(' ')}`);
        const child = (0, child_process_1.spawn)(TTY_FWD_PATH, args, {
            cwd: cwd,
            detached: true,
            stdio: 'ignore'
        });
        child.unref();
        // Respond immediately - session creation is detached
        res.json({ sessionId: sessionName });
    }
    catch (error) {
        console.error('Error creating session:', error);
        res.status(500).json({ error: 'Failed to create session' });
    }
});
// Kill session (just kill the process)
app.delete('/api/sessions/:sessionId', async (req, res) => {
    const sessionId = req.params.sessionId;
    try {
        const output = await executeTtyFwd(['--control-path', TTY_FWD_CONTROL_DIR, '--list-sessions']);
        const sessions = JSON.parse(output || '{}');
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
                    }
                    catch (e) {
                        // Process already dead
                    }
                }, 1000);
            }
            catch (error) {
                // Process already dead
            }
        }
        res.json({ success: true, message: 'Session killed' });
    }
    catch (error) {
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
    }
    catch (error) {
        // If tty-fwd cleanup fails, force remove directory
        console.log('tty-fwd cleanup failed, force removing directory');
        const sessionDir = path_1.default.join(TTY_FWD_CONTROL_DIR, sessionId);
        try {
            if (fs_1.default.existsSync(sessionDir)) {
                fs_1.default.rmSync(sessionDir, { recursive: true, force: true });
            }
            res.json({ success: true, message: 'Session force cleaned up' });
        }
        catch (fsError) {
            console.error('Error force removing session directory:', fsError);
            res.status(500).json({ error: 'Failed to cleanup session' });
        }
    }
});
// === TERMINAL I/O ===
// Server-sent events for terminal output streaming
app.get('/api/sessions/:sessionId/stream', (req, res) => {
    const sessionId = req.params.sessionId;
    const streamOutPath = path_1.default.join(TTY_FWD_CONTROL_DIR, sessionId, 'stream-out');
    if (!fs_1.default.existsSync(streamOutPath)) {
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
        const content = fs_1.default.readFileSync(streamOutPath, 'utf8');
        const lines = content.trim().split('\n');
        for (const line of lines) {
            if (line.trim()) {
                try {
                    const parsed = JSON.parse(line);
                    if (parsed.version && parsed.width && parsed.height) {
                        res.write(`data: ${line}\n\n`);
                        headerSent = true;
                    }
                    else if (Array.isArray(parsed) && parsed.length >= 3) {
                        const instantEvent = [0, parsed[1], parsed[2]];
                        res.write(`data: ${JSON.stringify(instantEvent)}\n\n`);
                    }
                }
                catch (e) {
                    // Skip invalid lines
                }
            }
        }
    }
    catch (error) {
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
    const tailProcess = (0, child_process_1.spawn)('tail', ['-f', streamOutPath]);
    let buffer = '';
    tailProcess.stdout.on('data', (chunk) => {
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
                }
                catch (e) {
                    // Handle non-JSON as raw output
                    const currentTime = Date.now() / 1000;
                    const castEvent = [currentTime - startTime, "o", line];
                    res.write(`data: ${JSON.stringify(castEvent)}\n\n`);
                }
            }
        }
    });
    // Cleanup on disconnect
    req.on('close', () => tailProcess.kill('SIGTERM'));
    req.on('aborted', () => tailProcess.kill('SIGTERM'));
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
        // Check if this is a special key that should use --send-key
        const specialKeys = ['arrow_up', 'arrow_down', 'arrow_left', 'arrow_right', 'escape', 'enter'];
        const isSpecialKey = specialKeys.includes(text);
        if (isSpecialKey) {
            await executeTtyFwd([
                '--control-path', TTY_FWD_CONTROL_DIR,
                '--session', sessionId,
                '--send-key', text
            ]);
            console.log(`Successfully sent key: ${text}`);
        }
        else {
            await executeTtyFwd([
                '--control-path', TTY_FWD_CONTROL_DIR,
                '--session', sessionId,
                '--send-text', text
            ]);
            console.log(`Successfully sent text: ${text}`);
        }
        res.json({ success: true });
    }
    catch (error) {
        console.error('Error sending input via tty-fwd:', error);
        res.status(500).json({ error: 'Failed to send input' });
    }
});
// === FILE SYSTEM ===
// Directory listing for file browser
app.get('/api/fs/browse', (req, res) => {
    const dirPath = req.query.path || '~';
    try {
        const expandedPath = resolvePath(dirPath, '~');
        if (!fs_1.default.existsSync(expandedPath)) {
            return res.status(404).json({ error: 'Directory not found' });
        }
        const stats = fs_1.default.statSync(expandedPath);
        if (!stats.isDirectory()) {
            return res.status(400).json({ error: 'Path is not a directory' });
        }
        const files = fs_1.default.readdirSync(expandedPath).map(name => {
            const filePath = path_1.default.join(expandedPath, name);
            const fileStats = fs_1.default.statSync(filePath);
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
                if (a.isDir && !b.isDir)
                    return -1;
                if (!a.isDir && b.isDir)
                    return 1;
                return a.name.localeCompare(b.name);
            })
        });
    }
    catch (error) {
        console.error('Error listing directory:', error);
        res.status(500).json({ error: 'Failed to list directory' });
    }
});
// === WEBSOCKETS ===
// WebSocket for hot reload
wss.on('connection', (ws, req) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
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
    watcher.on('change', (path) => {
        console.log(`File changed: ${path}`);
        hotReloadClients.forEach((ws) => {
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
