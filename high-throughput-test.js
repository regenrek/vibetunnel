#!/usr/bin/env node

const fs = require('fs');
const { spawn } = require('child_process');

const TEST_FILE = '/tmp/high-throughput-test.log';
const DATA_SIZE = 10 * 1024 * 1024; // 10MB
const CHUNK_SIZE = 1024; // 1KB chunks

class FSWatchStreamer {
  constructor(filePath) {
    this.filePath = filePath;
    this.lastOffset = 0;
    this.watcher = null;
    this.bytesReceived = 0;
    this.chunksReceived = 0;
    this.startTime = null;
  }

  start(onData) {
    if (!fs.existsSync(this.filePath)) {
      fs.writeFileSync(this.filePath, '');
    }
    
    const stats = fs.statSync(this.filePath);
    this.lastOffset = stats.size;
    this.startTime = process.hrtime.bigint();

    this.watcher = fs.watch(this.filePath, (eventType) => {
      if (eventType === 'change') {
        this.readNewData(onData);
      }
    });
  }

  readNewData(onData) {
    try {
      const stats = fs.statSync(this.filePath);
      if (stats.size > this.lastOffset) {
        const fd = fs.openSync(this.filePath, 'r');
        const buffer = Buffer.alloc(stats.size - this.lastOffset);
        fs.readSync(fd, buffer, 0, buffer.length, this.lastOffset);
        fs.closeSync(fd);
        
        this.lastOffset = stats.size;
        this.bytesReceived += buffer.length;
        this.chunksReceived++;
        
        onData(buffer);
      }
    } catch (error) {
      // Ignore read errors
    }
  }

  stop() {
    if (this.watcher) {
      this.watcher.close();
    }
    
    const endTime = process.hrtime.bigint();
    const durationMs = Number(endTime - this.startTime) / 1000000;
    const throughputMBps = (this.bytesReceived / (1024 * 1024)) / (durationMs / 1000);
    
    return {
      bytesReceived: this.bytesReceived,
      chunksReceived: this.chunksReceived,
      durationMs,
      throughputMBps
    };
  }
}

class TailStreamer {
  constructor(filePath) {
    this.filePath = filePath;
    this.tailProcess = null;
    this.bytesReceived = 0;
    this.chunksReceived = 0;
    this.startTime = null;
  }

  start(onData) {
    if (!fs.existsSync(this.filePath)) {
      fs.writeFileSync(this.filePath, '');
    }
    
    this.startTime = process.hrtime.bigint();
    this.tailProcess = spawn('tail', ['-f', this.filePath]);
    
    this.tailProcess.stdout.on('data', (data) => {
      this.bytesReceived += data.length;
      this.chunksReceived++;
      onData(data);
    });
  }

  stop() {
    if (this.tailProcess) {
      this.tailProcess.kill();
    }
    
    const endTime = process.hrtime.bigint();
    const durationMs = Number(endTime - this.startTime) / 1000000;
    const throughputMBps = (this.bytesReceived / (1024 * 1024)) / (durationMs / 1000);
    
    return {
      bytesReceived: this.bytesReceived,
      chunksReceived: this.chunksReceived,
      durationMs,
      throughputMBps
    };
  }
}

// High-speed data generator
async function generateHighThroughputData() {
  console.log(`Writing ${DATA_SIZE / (1024 * 1024)}MB in ${CHUNK_SIZE} byte chunks...`);
  
  const chunk = 'x'.repeat(CHUNK_SIZE - 1) + '\n'; // 1KB chunk
  const totalChunks = Math.floor(DATA_SIZE / CHUNK_SIZE);
  
  const startTime = process.hrtime.bigint();
  
  for (let i = 0; i < totalChunks; i++) {
    fs.appendFileSync(TEST_FILE, chunk);
    
    // Small delay every 100 chunks to simulate realistic writing
    if (i % 100 === 0) {
      await new Promise(resolve => setImmediate(resolve));
    }
  }
  
  const endTime = process.hrtime.bigint();
  const writeTimeMs = Number(endTime - startTime) / 1000000;
  const writeThroughputMBps = (DATA_SIZE / (1024 * 1024)) / (writeTimeMs / 1000);
  
  console.log(`Write completed in ${writeTimeMs.toFixed(2)}ms`);
  console.log(`Write throughput: ${writeThroughputMBps.toFixed(2)} MB/sec`);
}

async function benchmarkHighThroughput(StreamerClass, name) {
  console.log(`\n=== ${name} High Throughput Test ===`);
  
  // Clear test file
  fs.writeFileSync(TEST_FILE, '');
  
  const streamer = new StreamerClass(TEST_FILE);
  let dataReceived = false;
  
  streamer.start((data) => {
    if (!dataReceived) {
      dataReceived = true;
      console.log(`${name}: First data received`);
    }
  });
  
  // Wait for setup
  await new Promise(resolve => setTimeout(resolve, 100));
  
  // Generate data
  await generateHighThroughputData();
  
  // Wait for processing
  await new Promise(resolve => setTimeout(resolve, 1000));
  
  const results = streamer.stop();
  
  console.log(`${name} Results:`);
  console.log(`  Bytes received: ${(results.bytesReceived / (1024 * 1024)).toFixed(2)} MB`);
  console.log(`  Chunks received: ${results.chunksReceived}`);
  console.log(`  Duration: ${results.durationMs.toFixed(2)}ms`);
  console.log(`  Throughput: ${results.throughputMBps.toFixed(2)} MB/sec`);
  console.log(`  Efficiency: ${((results.bytesReceived / DATA_SIZE) * 100).toFixed(1)}%`);
  
  return results;
}

async function main() {
  console.log('🚀 High Throughput Streaming Test');
  console.log(`Target: ${DATA_SIZE / (1024 * 1024)}MB of data`);
  
  // Clean up
  if (fs.existsSync(TEST_FILE)) {
    fs.unlinkSync(TEST_FILE);
  }
  
  // Test fs.watch()
  const fsWatchResults = await benchmarkHighThroughput(FSWatchStreamer, 'fs.watch()');
  
  await new Promise(resolve => setTimeout(resolve, 1000));
  
  // Test tail -f
  const tailResults = await benchmarkHighThroughput(TailStreamer, 'tail -f');
  
  // Comparison
  console.log('\n🏆 HIGH THROUGHPUT COMPARISON:');
  console.log('================================');
  console.log(`fs.watch(): ${fsWatchResults.throughputMBps.toFixed(2)} MB/sec`);
  console.log(`tail -f:    ${tailResults.throughputMBps.toFixed(2)} MB/sec`);
  
  const winner = fsWatchResults.throughputMBps > tailResults.throughputMBps ? 'fs.watch()' : 'tail -f';
  const difference = Math.abs(fsWatchResults.throughputMBps - tailResults.throughputMBps);
  console.log(`Winner:     ${winner} (+${difference.toFixed(2)} MB/sec)`);
  
  // Clean up
  if (fs.existsSync(TEST_FILE)) {
    fs.unlinkSync(TEST_FILE);
  }
}

if (require.main === module) {
  main().catch(console.error);
}