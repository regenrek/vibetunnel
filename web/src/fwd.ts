#!/usr/bin/env npx tsx --no-deprecation
/**
 * VibeTunnel Forward (fwd.ts)
 *
 * A simple command-line tool that spawns a PTY session and forwards it
 * using the VibeTunnel PTY infrastructure.
 *
 * Usage:
 *   npx tsx src/fwd.ts <command> [args...]
 *   npx tsx src/fwd.ts claude --resume
 */

import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import { PtyService } from './pty/index.js';

function showUsage() {
  console.log('VibeTunnel Forward (fwd.ts)');
  console.log('');
  console.log('Usage:');
  console.log('  npx tsx src/fwd.ts <command> [args...]');
  console.log('  npx tsx src/fwd.ts --monitor-only <command> [args...]');
  console.log('');
  console.log('Options:');
  console.log('  --monitor-only   Just create session and monitor, no interactive I/O');
  console.log('');
  console.log('Examples:');
  console.log('  npx tsx src/fwd.ts claude --resume');
  console.log('  npx tsx src/fwd.ts bash -l');
  console.log('  npx tsx src/fwd.ts python3 -i');
  console.log('  npx tsx src/fwd.ts --monitor-only long-running-command');
  console.log('');
  console.log('The command will be spawned in the current working directory');
  console.log('and managed through the VibeTunnel PTY infrastructure.');
}

async function main() {
  // Parse command line arguments
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
    showUsage();
    process.exit(0);
  }

  const monitorOnly = args[0] === '--monitor-only';
  const command = monitorOnly ? args.slice(1) : args;

  if (command.length === 0) {
    console.error('Error: No command specified');
    showUsage();
    process.exit(1);
  }

  const cwd = process.cwd();

  console.log(`Starting command: ${command.join(' ')}`);
  console.log(`Working directory: ${cwd}`);

  // Initialize PTY service
  const controlPath = path.join(os.homedir(), '.vibetunnel', 'control');
  const ptyService = new PtyService({
    implementation: 'auto', // Let it choose the best available
    controlPath,
    fallbackToTtyFwd: true,
  });

  try {
    // Create the session
    const sessionName = `fwd_${command[0]}_${Date.now()}`;
    console.log(`Creating session: ${sessionName}`);

    const result = await ptyService.createSession(command, {
      sessionName,
      workingDir: cwd,
      term: process.env.TERM || 'xterm-256color',
      cols: process.stdout.columns || 80,
      rows: process.stdout.rows || 24,
    });

    console.log(`Session created with ID: ${result.sessionId}`);
    console.log(`Implementation: ${ptyService.getCurrentImplementation()}`);

    // Get session info
    const session = ptyService.getSession(result.sessionId);
    if (!session) {
      throw new Error('Session not found after creation');
    }

    console.log(`PID: ${session.pid}`);
    console.log(`Status: ${session.status}`);
    console.log(`Stream output: ${session['stream-out']}`);
    console.log(`Input pipe: ${session.stdin}`);

    // Set up control FIFO for external commands (resize, etc.)
    const controlPath = path.join(path.dirname(session.stdin), 'control');
    try {
      // Create control FIFO (like stdin)
      if (!fs.existsSync(controlPath)) {
        const { spawnSync } = require('child_process');
        const result = spawnSync('mkfifo', [controlPath], { stdio: 'ignore' });
        if (result.status !== 0) {
          // Fallback to regular file if mkfifo fails
          fs.writeFileSync(controlPath, '');
        }
      }

      // Update session info to include control pipe
      const sessionInfoPath = path.join(path.dirname(session.stdin), 'session.json');
      if (fs.existsSync(sessionInfoPath)) {
        const sessionInfo = JSON.parse(fs.readFileSync(sessionInfoPath, 'utf8'));
        sessionInfo.control = controlPath;
        fs.writeFileSync(sessionInfoPath, JSON.stringify(sessionInfo, null, 2));
      }

      console.log(`Control FIFO: ${controlPath}`);

      // Open control FIFO for both read and write (like stdin) to keep it open
      const controlFd = fs.openSync(controlPath, 'r+');
      const controlStream = fs.createReadStream('', { fd: controlFd, encoding: 'utf8' });

      controlStream.on('data', (data: string) => {
        const lines = data.split('\n');
        for (const line of lines) {
          if (line.trim()) {
            try {
              const message = JSON.parse(line);
              handleControlMessage(message);
            } catch (_e) {
              console.warn('Invalid control message:', line);
            }
          }
        }
      });

      controlStream.on('error', (error) => {
        console.warn('Control FIFO stream error:', error);
      });

      controlStream.on('end', () => {
        console.log('Control FIFO stream ended');
      });

      // Handle control messages
      const handleControlMessage = (message: Record<string, unknown>) => {
        if (message.cmd === 'resize' && message.cols && message.rows) {
          console.log(`Received resize command: ${message.cols}x${message.rows}`);
          // Get current session from PTY service and resize if possible
          try {
            ptyService.resizeSession(result.sessionId, message.cols, message.rows);
          } catch (error) {
            console.warn('Failed to resize session:', error);
          }
        } else if (message.cmd === 'kill') {
          console.log(`Received kill command: ${message.signal || 'SIGTERM'}`);
          // The session monitoring will detect the exit and handle cleanup
          try {
            ptyService.killSession(result.sessionId, message.signal || 'SIGTERM');
          } catch (error) {
            console.warn('Failed to kill session:', error);
          }
        }
      };

      // Clean up control stream on exit
      process.on('exit', () => {
        try {
          controlStream.destroy();
          fs.closeSync(controlFd);
          if (fs.existsSync(controlPath)) {
            fs.unlinkSync(controlPath);
          }
        } catch (_e) {
          // Ignore cleanup errors
        }
      });
    } catch (error) {
      console.warn('Failed to set up control pipe:', error);
    }

    if (monitorOnly) {
      console.log(`Monitor-only mode enabled\n`);
    } else {
      console.log(`Starting interactive session...\n`);

      // Set up raw mode for terminal input
      if (process.stdin.isTTY) {
        process.stdin.setRawMode(true);
      }
      process.stdin.resume();
      process.stdin.setEncoding('utf8');

      // Forward stdin to PTY
      process.stdin.on('data', (data: string) => {
        try {
          ptyService.sendInput(result.sessionId, { text: data });
        } catch (error) {
          console.error('Failed to send input:', error);
        }
      });
    }

    // Also monitor the stdin FIFO for input from web server
    const stdinPath = session.stdin;
    if (stdinPath && fs.existsSync(stdinPath)) {
      console.log(`Monitoring stdin pipe: ${stdinPath}`);

      try {
        // Open FIFO for both read and write (like tty-fwd) to keep it open
        const stdinFd = fs.openSync(stdinPath, 'r+'); // r+ = read/write
        const stdinStream = fs.createReadStream('', { fd: stdinFd, encoding: 'utf8' });

        stdinStream.on('data', (data: string) => {
          try {
            // Forward data from web server to PTY
            ptyService.sendInput(result.sessionId, { text: data });
          } catch (error) {
            console.error('Failed to forward stdin data to PTY:', error);
          }
        });

        stdinStream.on('error', (error) => {
          console.warn('Stdin FIFO stream error:', error);
        });

        stdinStream.on('end', () => {
          console.log('Stdin FIFO stream ended');
        });

        // Clean up on exit
        process.on('exit', () => {
          try {
            stdinStream.destroy();
            fs.closeSync(stdinFd);
          } catch (_e) {
            // Ignore cleanup errors
          }
        });
      } catch (error) {
        console.warn('Failed to set up stdin FIFO monitoring:', error);
      }
    }

    // Stream PTY output to stdout
    const streamOutput = session['stream-out'];
    console.log(`Waiting for output stream file: ${streamOutput}`);

    // Wait for the stream file to be created
    const waitForStreamFile = async (maxWait = 5000) => {
      const startTime = Date.now();
      while (Date.now() - startTime < maxWait) {
        if (streamOutput && fs.existsSync(streamOutput)) {
          return true;
        }
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      return false;
    };

    const streamExists = await waitForStreamFile();
    if (!streamExists) {
      console.log('Warning: Stream output file not found, proceeding without real-time output');
    } else {
      console.log('Stream file found, starting output monitoring...');

      let lastPosition = 0;

      const readNewData = () => {
        try {
          if (!streamOutput || !fs.existsSync(streamOutput)) return;

          const stats = fs.statSync(streamOutput);
          if (stats.size > lastPosition) {
            const fd = fs.openSync(streamOutput, 'r');
            const buffer = Buffer.allocUnsafe(stats.size - lastPosition);
            fs.readSync(fd, buffer, 0, buffer.length, lastPosition);
            fs.closeSync(fd);
            const chunk = buffer.toString('utf8');

            // Parse asciinema format and extract text content
            const lines = chunk.split('\n');
            for (const line of lines) {
              if (line.trim()) {
                try {
                  const record = JSON.parse(line);
                  if (Array.isArray(record) && record.length >= 3 && record[1] === 'o') {
                    // This is an output record: [timestamp, 'o', text]
                    process.stdout.write(record[2]);
                  }
                } catch (_e) {
                  // If JSON parse fails, might be partial line, skip it
                }
              }
            }

            lastPosition = stats.size;
          }
        } catch (_error) {
          // File might be locked or temporarily unavailable
        }
      };

      // Start monitoring
      const streamInterval = setInterval(readNewData, 50);

      // Clean up on exit
      process.on('exit', () => {
        clearInterval(streamInterval);
      });
    }

    // Set up signal handlers for graceful shutdown
    let shuttingDown = false;

    const shutdown = async (signal: string) => {
      if (shuttingDown) return;
      shuttingDown = true;

      // Restore terminal settings (only if we were in interactive mode)
      if (!monitorOnly && process.stdin.isTTY) {
        process.stdin.setRawMode(false);
      }
      if (!monitorOnly) {
        process.stdin.pause();
      }

      console.log(`\n\nReceived ${signal}, checking session status...`);

      try {
        const currentSession = ptyService.getSession(result.sessionId);
        if (currentSession && currentSession.status === 'running') {
          console.log('Session is still running. Leaving it active.');
          console.log(`Session ID: ${result.sessionId}`);
          console.log('You can reconnect to it later via the web interface.');
        } else {
          console.log('Session has exited.');
        }
      } catch (error) {
        console.error('Error checking session status:', error);
      }

      process.exit(0);
    };

    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));

    // Monitor session status
    const checkInterval = setInterval(() => {
      try {
        const currentSession = ptyService.getSession(result.sessionId);
        if (!currentSession || currentSession.status === 'exited') {
          // Restore terminal settings before exit (only if we were in interactive mode)
          if (!monitorOnly && process.stdin.isTTY) {
            process.stdin.setRawMode(false);
          }
          if (!monitorOnly) {
            process.stdin.pause();
          }

          console.log('\n\nSession has exited.');
          if (currentSession?.exit_code !== undefined) {
            console.log(`Exit code: ${currentSession.exit_code}`);
          }
          clearInterval(checkInterval);
          process.exit(currentSession?.exit_code || 0);
        }
      } catch (error) {
        console.error('Error monitoring session:', error);
        clearInterval(checkInterval);
        process.exit(1);
      }
    }, 1000); // Check every second

    // Keep the process alive
    await new Promise<void>((resolve) => {
      // This will keep running until the session exits or we get a signal
      process.on('exit', () => resolve());
    });
  } catch (error) {
    console.error('Failed to create or manage session:', error);

    if (error instanceof Error) {
      console.error('Error details:', error.message);
    }

    process.exit(1);
  }
}

// Handle uncaught exceptions
process.on('uncaughtException', (error) => {
  console.error('Uncaught exception:', error);
  process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled rejection at:', promise, 'reason:', reason);
  process.exit(1);
});

// Run the main function
main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});
