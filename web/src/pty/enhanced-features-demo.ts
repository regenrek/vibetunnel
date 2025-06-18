/**
 * Demo of Enhanced PTY Features
 *
 * This demonstrates the new waiting state detection and proper process termination
 * features that match tty-fwd behavior.
 */

import { PtyService } from './PtyService.js';

async function demonstrateEnhancedFeatures() {
  const ptyService = new PtyService();

  console.log('=== Enhanced PTY Features Demo ===');
  console.log('');

  // 1. Demonstrate waiting state detection
  console.log('1. Creating a session that will be in "waiting" state...');
  const result = await ptyService.createSession(['sleep', '10'], {
    sessionName: 'waiting-demo',
    workingDir: process.cwd(),
  });

  console.log(`Created session: ${result.sessionId}`);
  console.log('');

  // 2. Check session states
  console.log('2. Checking session states...');
  const sessions = ptyService.listSessions();
  for (const session of sessions) {
    console.log(`Session ${session.session_id}:`);
    console.log(`  Status: ${session.status}`);
    console.log(`  Waiting: ${session.waiting}`);
    console.log(`  PID: ${session.pid}`);
    console.log('');
  }

  // 3. Demonstrate proper kill escalation
  console.log('3. Demonstrating SIGTERM -> SIGKILL escalation...');
  console.log('This will:');
  console.log('  - Send SIGTERM first');
  console.log('  - Wait up to 3 seconds (checking every 500ms)');
  console.log("  - Send SIGKILL if process doesn't terminate gracefully");
  console.log('');

  // Kill the session to demonstrate escalation
  ptyService.killSession(result.sessionId);

  console.log('Kill command sent. Check the console output above for escalation details.');
  console.log('');

  // 4. Show final session state
  setTimeout(() => {
    console.log('4. Final session states:');
    const finalSessions = ptyService.listSessions();
    console.log(`Active sessions: ${finalSessions.length}`);

    for (const session of finalSessions) {
      console.log(`Session ${session.session_id}: ${session.status}`);
    }
  }, 4000); // Wait 4 seconds to see full escalation process
}

// Export the demo function
export { demonstrateEnhancedFeatures };

// Run demo if this file is executed directly
if (process.argv[1] && process.argv[1].endsWith('enhanced-features-demo.ts')) {
  demonstrateEnhancedFeatures().catch(console.error);
}
