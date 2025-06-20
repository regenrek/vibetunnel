#!/usr/bin/env node

const path = require('path');

// Test the terminal manager directly
async function testTerminalManager() {
  console.log('Testing Terminal Manager...\n');
  
  const { TerminalManager } = require('./dist/terminal-manager.js');
  const controlDir = path.join(process.env.HOME, '.vibetunnel/control');
  
  const tm = new TerminalManager(controlDir);
  
  // Get a specific session
  const sessionId = process.argv[2] || '725f848c-c6d7-4bd4-8030-b83b20b1ee45';
  
  console.log(`Testing session: ${sessionId}`);
  
  try {
    // Get terminal
    const terminal = await tm.getTerminal(sessionId);
    console.log('Terminal created successfully');
    
    // Wait for content to load
    console.log('Waiting for content to load...');
    await new Promise(resolve => setTimeout(resolve, 1000));
    
    // Get buffer stats
    const stats = await tm.getBufferStats(sessionId);
    console.log('\nBuffer stats:', stats);
    
    // Get buffer snapshot
    const snapshot = await tm.getBufferSnapshot(sessionId, undefined, 10);
    console.log('\nBuffer snapshot:');
    console.log('- Dimensions:', `${snapshot.cols}x${snapshot.rows}`);
    console.log('- ViewportY:', snapshot.viewportY);
    console.log('- Cursor:', `(${snapshot.cursorX}, ${snapshot.cursorY})`);
    
    // Check content
    if (snapshot.cells.length > 0) {
      console.log('\nFirst line content:');
      const firstLine = snapshot.cells[0];
      const text = firstLine.map(cell => cell.char).join('');
      console.log(`"${text}"`);
      
      // Check for non-space content
      let hasContent = false;
      for (const row of snapshot.cells) {
        const rowText = row.map(cell => cell.char).join('').trim();
        if (rowText.length > 0) {
          hasContent = true;
          console.log(`\nFound content: "${rowText}"`);
          break;
        }
      }
      
      if (!hasContent) {
        console.log('\n⚠️  Warning: All lines appear to be empty!');
      }
    }
    
    // Close terminal
    tm.closeTerminal(sessionId);
    console.log('\nTerminal closed');
    
  } catch (error) {
    console.error('Error:', error);
  }
}

testTerminalManager().catch(console.error);