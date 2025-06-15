import express from 'express';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import path from 'path';
import chokidar from 'chokidar';
import fs from 'fs';
import os from 'os';
import { spawn } from 'child_process';
import * as pty from 'node-pty';

const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ server });

const PORT = process.env.PORT || 3000;

// tty-fwd binary path
const TTY_FWD_PATH = path.resolve(__dirname, '..', '..', 'tty-fwd', 'target', 'release', 'tty-fwd');
const TTY_FWD_CONTROL_DIR = path.join(os.homedir(), '.vibetunnel');

// Verify tty-fwd binary exists
if (!fs.existsSync(TTY_FWD_PATH)) {
  console.error(`tty-fwd binary not found at: ${TTY_FWD_PATH}`);
  process.exit(1);
}

// Ensure control directory exists
if (!fs.existsSync(TTY_FWD_CONTROL_DIR)) {
  fs.mkdirSync(TTY_FWD_CONTROL_DIR, { recursive: true });
  console.log(`Created control directory: ${TTY_FWD_CONTROL_DIR}`);
}

// Parse JSON bodies
app.use(express.json());

// Hot reload functionality
const hotReloadClients = new Set<any>();

// Watch for file changes in development
if (process.env.NODE_ENV !== 'production') {
  const watcher = chokidar.watch(['public/**/*', 'src/**/*'], {
    ignored: /node_modules/,
    persistent: true
  });

  watcher.on('change', (path) => {
    console.log(`File changed: ${path}`);
    hotReloadClients.forEach((ws: any) => {
      if (ws.readyState === ws.OPEN) {
        ws.send(JSON.stringify({ type: 'reload' }));
      }
    });
  });
}

// Serve static files
app.use(express.static(path.join(__dirname, '..', 'public')));

// Get tty-fwd sessions with their current stream-out content
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
            let lastOutput = '';
            let lastModified = new Date(0); // Default to epoch if file doesn't exist
            
            if (fs.existsSync(sessionPath)) {
              metadata = JSON.parse(fs.readFileSync(sessionPath, 'utf8'));
            }
            
            if (fs.existsSync(streamOutPath)) {
              const content = fs.readFileSync(streamOutPath, 'utf8');
              lastOutput = content;
              
              // Get the modification time of the stream-out file
              const stats = fs.statSync(streamOutPath);
              lastModified = stats.mtime;
            }
            
            sessionData.push({
              id: sessionId,
              status: sessionInfo.status,
              metadata: metadata,
              lastOutput: lastOutput,
              lastModified: lastModified.toISOString()
            });
          }
          
          // Sort by lastModified time, most recent first
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

// Create new session
app.post('/api/sessions', async (req, res) => {
  try {
    console.log('Received session creation request:', req.body);
    const { command, workingDir } = req.body;
    
    if (!command || !Array.isArray(command)) {
      console.error('Invalid command:', command);
      return res.status(400).json({ error: 'Command array is required' });
    }
    
    const sessionName = `session_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    const cwd = workingDir ? (workingDir.startsWith('~') ? 
      path.join(os.homedir(), workingDir.slice(2)) : 
      path.resolve(workingDir)) : process.cwd();
    
    // Spawn tty-fwd with the command in a pseudo-terminal
    // Use --session-name for creating new sessions
    const fullCommand = command.join(' ');
    const commandLine = `${TTY_FWD_PATH} --control-path "${TTY_FWD_CONTROL_DIR}" --session-name "${sessionName}" -- ${fullCommand}`;
    
    console.log(`Creating session in PTY: ${commandLine}`);
    
    const ptyProcess = pty.spawn('bash', ['-c', commandLine], {
      name: 'xterm-color',
      cols: 80,
      rows: 24,
      cwd: cwd,
      env: process.env
    });
    
    ptyProcess.onData((data) => {
      console.log('PTY output:', data);
    });
    
    ptyProcess.onExit(({ exitCode, signal }) => {
      console.log(`PTY process exited with code ${exitCode}, signal ${signal}`);
    });
    
    // Detach the process after a short delay
    setTimeout(() => {
      ptyProcess.kill();
    }, 1000);
    
    // Wait a bit for session to be created
    setTimeout(() => {
      console.log(`Session creation completed: ${sessionName}`);
      const response = { sessionName };
      console.log('Sending response:', response);
      res.json(response);
    }, 500);
    
  } catch (error) {
    console.error('Error creating session:', error);
    res.status(500).json({ error: 'Failed to create session' });
  }
});

// SSE endpoint for streaming terminal output using tail -f (like Python example)
app.get('/api/stream/:sessionId', (req, res) => {
  const sessionId = req.params.sessionId;
  const streamOutPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'stream-out');
  
  if (!fs.existsSync(streamOutPath)) {
    return res.status(404).json({ error: 'Session not found' });
  }
  
  // Set up SSE headers
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Cache-Control'
  });
  
  console.log(`Starting SSE stream for session ${sessionId} using tail -f`);
  
  const startTime = Date.now() / 1000;
  let headerSent = false;
  
  // First, read the file to get the header and existing content
  try {
    const content = fs.readFileSync(streamOutPath, 'utf8');
    const lines = content.trim().split('\n');
    
    if (lines.length > 0) {
      // Send header first
      try {
        const header = JSON.parse(lines[0]);
        if (header.version && header.width && header.height) {
          res.write(`data: ${lines[0]}\n\n`);
          headerSent = true;
          console.log('Sent existing cast header:', header);
          
          // Send existing cast events with timestamps reset to 0 for instant playback
          let instantTimestamp = 0;
          for (let i = 1; i < lines.length; i++) {
            if (lines[i].trim()) {
              try {
                const event = JSON.parse(lines[i]);
                if (Array.isArray(event) && event.length >= 3) {
                  // Reset timestamp to 0 for instant playback of existing content
                  const instantEvent = [0, event[1], event[2]];
                  res.write(`data: ${JSON.stringify(instantEvent)}\n\n`);
                  console.log('Sent instant event:', instantEvent);
                }
              } catch (e) {
                console.error('Error parsing existing event:', lines[i]);
              }
            }
          }
        }
      } catch (e) {
        console.error('Error parsing header:', e);
      }
    }
  } catch (error) {
    console.error('Error reading existing content:', error);
  }
  
  // If no header was found, send a default one
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
    console.log('Sent default cast header');
  }
  
  // Use tail -f to follow the file for new content
  const tailProcess = spawn('tail', ['-f', streamOutPath], {
    stdio: ['ignore', 'pipe', 'pipe']
  });
  
  console.log(`Started tail -f for ${streamOutPath}`);
  
  let buffer = '';
  
  tailProcess.stdout.on('data', (chunk) => {
    buffer += chunk.toString();
    const lines = buffer.split('\n');
    
    // Keep the last incomplete line in buffer
    buffer = lines.pop() || '';
    
    // Process complete lines
    lines.forEach(line => {
      if (line.trim()) {
        try {
          // Skip header line if we see it again
          const parsed = JSON.parse(line);
          if (parsed.version && parsed.width && parsed.height) {
            console.log('Skipping duplicate header from tail');
            return;
          }
          
          // This is a new cast event - use real-time timestamp
          if (Array.isArray(parsed) && parsed.length >= 3) {
            const currentTime = Date.now() / 1000;
            const relativeTime = currentTime - startTime;
            const realTimeEvent = [relativeTime, parsed[1], parsed[2]];
            console.log('Streaming new cast event with real-time timestamp:', realTimeEvent);
            res.write(`data: ${JSON.stringify(realTimeEvent)}\n\n`);
          } else {
            // Fallback: stream original line
            console.log('Streaming unknown event format:', line);
            res.write(`data: ${line}\n\n`);
          }
        } catch (e) {
          // If it's not JSON, treat it as raw output and create a cast event
          const currentTime = Date.now() / 1000;
          const relativeTime = currentTime - startTime;
          const castEvent = [relativeTime, "o", line];
          console.log('Streaming raw output as cast event:', castEvent);
          res.write(`data: ${JSON.stringify(castEvent)}\n\n`);
        }
      }
    });
  });
  
  tailProcess.stderr.on('data', (data) => {
    console.error(`tail stderr: ${data}`);
  });
  
  tailProcess.on('error', (error) => {
    console.error('tail process error:', error);
    res.write(`data: ${JSON.stringify([Date.now()/1000 - startTime, "o", "Error: tail process failed"])}\n\n`);
  });
  
  tailProcess.on('exit', (code) => {
    console.log(`tail process exited with code ${code}`);
  });
  
  // Clean up on client disconnect
  req.on('close', () => {
    console.log(`SSE stream closed for session ${sessionId}, killing tail process`);
    tailProcess.kill('SIGTERM');
  });
  
  req.on('aborted', () => {
    console.log(`SSE stream aborted for session ${sessionId}, killing tail process`);
    tailProcess.kill('SIGTERM');
  });
});

// Fallback: serve cast file directly (for testing)
app.get('/api/cast/:sessionId', (req, res) => {
  const sessionId = req.params.sessionId;
  const streamOutPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'stream-out');
  
  if (!fs.existsSync(streamOutPath)) {
    return res.status(404).json({ error: 'Session not found' });
  }
  
  try {
    const content = fs.readFileSync(streamOutPath, 'utf8');
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.send(content);
  } catch (error) {
    console.error('Error serving cast file:', error);
    res.status(500).json({ error: 'Failed to read cast file' });
  }
});

// Input endpoint for sending text/keys to sessions
app.post('/api/input/:sessionId', (req, res) => {
  const sessionId = req.params.sessionId;
  const { text } = req.body;
  
  if (text === undefined || text === null) {
    return res.status(400).json({ error: 'Text is required' });
  }
  
  console.log(`Sending input to session ${sessionId}:`, JSON.stringify(text));
  
  // For special characters and escape sequences, we need to write directly to stdin file
  const stdinPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'stdin');
  
  if (!fs.existsSync(stdinPath)) {
    return res.status(404).json({ error: 'Session stdin not found' });
  }
  
  try {
    // Write the text directly to the stdin named pipe
    fs.writeFileSync(stdinPath, text, { encoding: 'binary' });
    console.log(`Successfully wrote ${text.length} bytes to stdin for session ${sessionId}`);
    res.json({ success: true });
  } catch (error) {
    console.error('Error writing to stdin:', error);
    
    // Fallback: try using tty-fwd --send-text for simple text
    if (text.length === 1 && text.charCodeAt(0) < 127) {
      console.log('Falling back to tty-fwd --send-text');
      
      // Escape quotes and special chars for shell
      const escapedText = text.replace(/'/g, "'\"'\"'");
      const sendCommand = `${TTY_FWD_PATH} --control-path "${TTY_FWD_CONTROL_DIR}" --session "${sessionId}" --send-text '${escapedText}'`;
      
      const inputChild = spawn('bash', ['-c', sendCommand], {
        stdio: 'ignore'
      });
      
      inputChild.on('error', (error) => {
        console.error('Error sending input via tty-fwd:', error);
        return res.status(500).json({ error: 'Failed to send input' });
      });
      
      inputChild.on('close', (code) => {
        if (code === 0) {
          res.json({ success: true });
        } else {
          res.status(500).json({ error: 'Failed to send input' });
        }
      });
    } else {
      res.status(500).json({ error: 'Failed to send input to terminal' });
    }
  }
});

// Kill session endpoint
app.delete('/api/sessions/:sessionId', (req, res) => {
  const sessionId = req.params.sessionId;
  
  console.log(`Killing session: ${sessionId}`);
  
  try {
    // First, get session info to find the PID
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
            console.log(`Killing process with PID: ${session.pid}`);
            
            // Kill the process
            try {
              process.kill(session.pid, 'SIGTERM');
              console.log(`Sent SIGTERM to PID ${session.pid}`);
              
              // Give it a moment, then try SIGKILL if needed
              setTimeout(() => {
                try {
                  process.kill(session.pid, 0); // Check if process still exists
                  console.log(`Process ${session.pid} still running, sending SIGKILL`);
                  process.kill(session.pid, 'SIGKILL');
                } catch (e) {
                  // Process already dead, which is good
                  console.log(`Process ${session.pid} successfully terminated`);
                }
              }, 1000);
            } catch (error) {
              console.log(`Process ${session.pid} was already dead or doesn't exist`);
            }
          }
          
          // Clean up session files using tty-fwd --cleanup
          setTimeout(() => {
            const cleanupChild = spawn(TTY_FWD_PATH, [
              '--control-path', TTY_FWD_CONTROL_DIR, 
              '--session', sessionId, 
              '--cleanup'
            ]);
            
            cleanupChild.on('close', (cleanupCode) => {
              console.log(`Cleanup completed with code: ${cleanupCode}`);
              if (cleanupCode !== 0) {
                console.warn(`Cleanup failed with code ${cleanupCode}, force removing directory`);
                // Force remove the session directory if cleanup failed
                const sessionDir = path.join(TTY_FWD_CONTROL_DIR, sessionId);
                try {
                  if (fs.existsSync(sessionDir)) {
                    fs.rmSync(sessionDir, { recursive: true, force: true });
                    console.log(`Force removed session directory: ${sessionDir}`);
                  }
                } catch (error) {
                  console.error('Error force removing session directory:', error);
                }
              }
            });
            
            cleanupChild.on('error', (error) => {
              console.error('Error during cleanup:', error);
            });
          }, 1000); // Reduced timeout to 1 second
          
          res.json({ success: true, message: 'Session killed' });
          
        } catch (error) {
          console.error('Error parsing sessions:', error);
          res.status(500).json({ error: 'Failed to get session info' });
        }
      } else {
        res.status(500).json({ error: 'Failed to list sessions' });
      }
    });
    
    sessionsChild.on('error', (error) => {
      console.error('Error listing sessions:', error);
      res.status(500).json({ error: 'Failed to list sessions' });
    });
    
  } catch (error) {
    console.error('Error killing session:', error);
    res.status(500).json({ error: 'Failed to kill session' });
  }
});

// WebSocket connections for streaming
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
  
  const sessionId = url.searchParams.get('session');
  if (!sessionId) {
    ws.close(1008, 'Session ID required');
    return;
  }
  
  const streamOutPath = path.join(TTY_FWD_CONTROL_DIR, sessionId, 'stream-out');
  
  if (!fs.existsSync(streamOutPath)) {
    ws.close(1008, 'Session not found');
    return;
  }
  
  // Send existing content
  try {
    const content = fs.readFileSync(streamOutPath, 'utf8');
    const lines = content.trim().split('\n');
    
    for (const line of lines) {
      if (line.trim() && ws.readyState === ws.OPEN) {
        ws.send(line);
      }
    }
  } catch (error) {
    console.error('Error reading stream-out:', error);
  }
  
  // Watch for new content
  let watcher: any = null;
  try {
    watcher = chokidar.watch(streamOutPath);
    let lastSize = fs.statSync(streamOutPath).size;
    
    watcher.on('change', () => {
      try {
        const stats = fs.statSync(streamOutPath);
        if (stats.size > lastSize) {
          const stream = fs.createReadStream(streamOutPath, {
            start: lastSize,
            encoding: 'utf8'
          });
          
          stream.on('data', (chunk) => {
            const lines = chunk.toString().split('\n');
            lines.forEach(line => {
              if (line.trim() && ws.readyState === ws.OPEN) {
                ws.send(line);
              }
            });
          });
          
          lastSize = stats.size;
        }
      } catch (error) {
        console.error('Error reading new content:', error);
      }
    });
  } catch (error) {
    console.error('Error setting up watcher:', error);
  }
  
  // Handle input using tty-fwd --send-text
  ws.on('message', (data) => {
    try {
      const message = JSON.parse(data.toString());
      if (message.type === 'input') {
        console.log(`Sending input to session ${sessionId}: ${message.data}`);
        
        // Use tty-fwd --send-text to send input
        const sendCommand = `${TTY_FWD_PATH} --control-path "${TTY_FWD_CONTROL_DIR}" --session "${sessionId}" --send-text "${message.data}"`;
        
        const inputChild = spawn('bash', ['-c', sendCommand], {
          stdio: 'ignore'
        });
        
        inputChild.on('error', (error) => {
          console.error('Error sending input via tty-fwd:', error);
        });
      }
    } catch (error) {
      console.error('Error handling input:', error);
    }
  });
  
  ws.on('close', () => {
    if (watcher) {
      watcher.close();
    }
  });
});

server.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});