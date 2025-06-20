#!/usr/bin/env node

/**
 * Test script for the new buffer component
 */

const http = require('http');

const BASE_URL = 'http://localhost:3000';

function httpGet(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => {
        if (res.statusCode === 200) {
          try {
            resolve(JSON.parse(data));
          } catch (e) {
            resolve(data);
          }
        } else {
          reject(new Error(`HTTP ${res.statusCode}: ${data}`));
        }
      });
    }).on('error', reject);
  });
}

async function testBufferEndpoints(sessionId) {
  console.log(`\n=== Testing buffer endpoints for session ${sessionId} ===`);
  
  // Test stats endpoint
  console.log('\n1. Testing /buffer/stats endpoint:');
  try {
    const stats = await httpGet(`${BASE_URL}/api/sessions/${sessionId}/buffer/stats`);
    console.log('   ✅ Stats:', JSON.stringify(stats, null, 2));
  } catch (error) {
    console.error('   ❌ Error:', error.message);
    return;
  }

  // Test JSON buffer endpoint
  console.log('\n2. Testing /buffer endpoint with JSON format:');
  try {
    const buffer = await httpGet(`${BASE_URL}/api/sessions/${sessionId}/buffer?lines=10&format=json`);
    console.log('   ✅ Buffer dimensions:', `${buffer.cols}x${buffer.rows}`);
    console.log('   ✅ Viewport Y:', buffer.viewportY);
    console.log('   ✅ Cursor position:', `(${buffer.cursorX}, ${buffer.cursorY})`);
    console.log('   ✅ Cell count:', buffer.cells.length);
    
    // Show sample of first line
    if (buffer.cells.length > 0) {
      const firstLine = buffer.cells[0];
      const text = firstLine.map(cell => cell.char).join('');
      console.log('   ✅ First line preview:', text.substring(0, 40) + '...');
    }
  } catch (error) {
    console.error('   ❌ Error:', error.message);
    return;
  }

  // Test bottom-up lines (without viewportY)
  console.log('\n3. Testing bottom-up lines (no viewportY):');
  try {
    const buffer = await httpGet(`${BASE_URL}/api/sessions/${sessionId}/buffer?lines=5&format=json`);
    console.log('   ✅ Got', buffer.rows, 'lines from bottom');
    console.log('   ✅ ViewportY:', buffer.viewportY);
  } catch (error) {
    console.error('   ❌ Error:', error.message);
  }
}

async function main() {
  console.log('Buffer Component Test Script');
  console.log('============================');
  
  // First get list of sessions
  console.log('\nFetching sessions...');
  try {
    const sessions = await httpGet(`${BASE_URL}/api/sessions`);
    console.log(`Found ${sessions.length} sessions`);
    
    if (sessions.length === 0) {
      console.log('\nNo sessions found. Please create a session first.');
      return;
    }
    
    // Test first running session
    const runningSessions = sessions.filter(s => s.status === 'running');
    if (runningSessions.length === 0) {
      console.log('\nNo running sessions found. Testing with first session...');
      await testBufferEndpoints(sessions[0].id);
    } else {
      console.log(`\nTesting with running session: ${runningSessions[0].command}`);
      await testBufferEndpoints(runningSessions[0].id);
    }
    
  } catch (error) {
    console.error('Error:', error.message);
  }
}

if (require.main === module) {
  main().catch(console.error);
}