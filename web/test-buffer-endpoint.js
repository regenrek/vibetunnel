#!/usr/bin/env node

// Test script for the new buffer endpoint

const BASE_URL = 'http://localhost:3000';

async function testBufferEndpoint() {
  try {
    // First, get list of sessions
    const sessionsRes = await fetch(`${BASE_URL}/api/sessions`);
    const sessions = await sessionsRes.json();
    
    if (sessions.length === 0) {
      console.log('No sessions available. Create a session first.');
      return;
    }
    
    const sessionId = sessions[0].id;
    console.log(`Testing with session: ${sessionId}`);
    
    // Test buffer endpoint
    const bufferRes = await fetch(`${BASE_URL}/api/sessions/${sessionId}/buffer?viewportY=0&lines=24`);
    
    if (!bufferRes.ok) {
      console.error('Buffer request failed:', bufferRes.status, await bufferRes.text());
      return;
    }
    
    const buffer = await bufferRes.arrayBuffer();
    const bytes = new Uint8Array(buffer);
    
    console.log(`Received ${bytes.length} bytes`);
    
    // Parse header
    if (bytes.length < 16) {
      console.error('Buffer too small for header');
      return;
    }
    
    const magic = (bytes[1] << 8) | bytes[0];
    const version = bytes[2];
    const flags = bytes[3];
    const cols = (bytes[5] << 8) | bytes[4];
    const rows = (bytes[7] << 8) | bytes[6];
    const viewportY = (bytes[9] << 8) | bytes[8];
    const cursorX = (bytes[11] << 8) | bytes[10];
    const cursorY = (bytes[13] << 8) | bytes[12];
    
    console.log('\nHeader:');
    console.log(`  Magic: 0x${magic.toString(16)} (${magic === 0x5654 ? 'Valid' : 'Invalid'})`);
    console.log(`  Version: ${version}`);
    console.log(`  Flags: ${flags}`);
    console.log(`  Terminal: ${cols}x${rows}`);
    console.log(`  ViewportY: ${viewportY}`);
    console.log(`  Cursor: (${cursorX}, ${cursorY})`);
    
    // Sample first few cells
    console.log('\nFirst few cells:');
    let offset = 16;
    for (let i = 0; i < Math.min(10, bytes.length - 16); i++) {
      if (offset >= bytes.length) break;
      
      const byte = bytes[offset];
      if (byte === 0xFF) {
        // RLE marker
        const count = bytes[offset + 1];
        console.log(`  RLE: ${count} repeated cells`);
        offset += 2;
      } else if (byte === 0xFE) {
        // Empty line marker
        const count = bytes[offset + 1];
        console.log(`  Empty lines: ${count}`);
        offset += 2;
      } else if (byte & 0x80) {
        // Extended cell
        console.log(`  Extended cell at offset ${offset}`);
        offset += 4; // Skip for now
      } else {
        // Basic cell
        const char = String.fromCharCode(byte);
        const attrs = bytes[offset + 1];
        const fg = bytes[offset + 2];
        const bg = bytes[offset + 3];
        console.log(`  Cell: '${char}' fg=${fg} bg=${bg} attrs=${attrs}`);
        offset += 4;
      }
    }
    
  } catch (error) {
    console.error('Test failed:', error);
  }
}

testBufferEndpoint();