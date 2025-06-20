#!/usr/bin/env node

const fs = require('fs');
const { spawn } = require('child_process');
const path = require('path');

// Test configuration
const TEST_FILE = '/tmp/stream-test.log';
const TEST_LINES = 1000;
const WRITE_DELAY = 10; // ms between writes

class FSWatchStreamer {
  constructor(filePath) {
    this.filePath = filePath;
    this.lastOffset = 0;
    this.watcher = null;
    this.onDataCallback = null;
    this.bytesRead = 0;
    this.linesRead = 0;
  }

  start(onData) {
    this.onDataCallback = onData;
    
    // Create file if it doesn't exist
    if (!fs.existsSync(this.filePath)) {
      fs.writeFileSync(this.filePath, '');
    }
    
    // Get initial file size
    const stats = fs.statSync(this.filePath);
    this.lastOffset = stats.size;

    // Start watching
    this.watcher = fs.watch(this.filePath, (eventType) => {
      if (eventType === 'change') {
        this.readNewData();
      }
    });
  }

  readNewData() {
    try {
      const stats = fs.statSync(this.filePath);
      if (stats.size > this.lastOffset) {
        // Read only the new data since lastOffset
        const fd = fs.openSync(this.filePath, 'r');
        const buffer = Buffer.alloc(stats.size - this.lastOffset);
        fs.readSync(fd, buffer, 0, buffer.length, this.lastOffset);
        fs.closeSync(fd);
        
        const newData = buffer;
        const oldOffset = this.lastOffset;
        this.lastOffset = stats.size;
        this.bytesRead += newData.length;
        const lines = newData.toString().split('\n').filter(line => line.length > 0);
        this.linesRead += lines.length;
        
        // Debug logging (only first few)
        // if (this.bytesRead < 1000) {
        //   console.log(`fs.watch: read ${newData.length} bytes (${oldOffset} -> ${this.lastOffset}), ${lines.length} lines`);
        // }
        
        if (this.onDataCallback) {
          this.onDataCallback(newData);
        }
      }
    } catch (error) {
      // File might be temporarily locked
      console.log('fs.watch read error:', error.message);
    }
  }

  stop() {
    if (this.watcher) {
      this.watcher.close();
    }
  }

  getStats() {
    return {
      bytesRead: this.bytesRead,
      linesRead: this.linesRead
    };
  }
}

class TailStreamer {
  constructor(filePath) {
    this.filePath = filePath;
    this.tailProcess = null;
    this.bytesRead = 0;
    this.linesRead = 0;
  }

  start(onData) {
    // Create file if it doesn't exist
    if (!fs.existsSync(this.filePath)) {
      fs.writeFileSync(this.filePath, '');
    }
    
    this.tailProcess = spawn('tail', ['-f', this.filePath]);
    
    this.tailProcess.stdout.on('data', (data) => {
      this.bytesRead += data.length;
      const lines = data.toString().split('\n').filter(line => line.length > 0);
      this.linesRead += lines.length;
      onData(data);
    });

    this.tailProcess.stderr.on('data', (data) => {
      console.error('tail stderr:', data.toString());
    });
  }

  stop() {
    if (this.tailProcess) {
      this.tailProcess.kill();
    }
  }

  getStats() {
    return {
      bytesRead: this.bytesRead,
      linesRead: this.linesRead
    };
  }
}

// Data generator
async function generateTestData() {
  console.log(`Generating ${TEST_LINES} lines to ${TEST_FILE}...`);
  
  return new Promise((resolve) => {
    let lineCount = 0;
    const interval = setInterval(() => {
      const line = `Line ${lineCount + 1} - ${Date.now()} - some test data here\n`;
      fs.appendFileSync(TEST_FILE, line);
      lineCount++;
      
      if (lineCount >= TEST_LINES) {
        clearInterval(interval);
        resolve();
      }
    }, WRITE_DELAY);
  });
}

// Benchmark function
async function benchmarkStreamer(StreamerClass, name) {
  console.log(`\n=== Testing ${name} ===`);
  
  // Clear the test file before each test
  fs.writeFileSync(TEST_FILE, '');
  
  const streamer = new StreamerClass(TEST_FILE);
  const startTime = process.hrtime.bigint();
  let firstDataTime = null;
  let lastDataTime = null;
  let dataChunks = 0;
  
  // Start the streamer
  streamer.start((data) => {
    const now = process.hrtime.bigint();
    if (!firstDataTime) {
      firstDataTime = now;
    }
    lastDataTime = now;
    dataChunks++;
  });
  
  // Wait a bit for setup
  await new Promise(resolve => setTimeout(resolve, 100));
  
  // Generate test data
  await generateTestData();
  
  // Wait for all data to be processed
  await new Promise(resolve => setTimeout(resolve, 500));
  
  const endTime = process.hrtime.bigint();
  streamer.stop();
  
  const stats = streamer.getStats();
  const totalTime = Number(endTime - startTime) / 1000000; // Convert to ms
  const firstDataLatency = firstDataTime ? Number(firstDataTime - startTime) / 1000000 : 0;
  const processingTime = lastDataTime && firstDataTime ? Number(lastDataTime - firstDataTime) / 1000000 : 0;
  
  console.log(`${name} Results:`);
  console.log(`  Total time: ${totalTime.toFixed(2)}ms`);
  console.log(`  First data latency: ${firstDataLatency.toFixed(2)}ms`);
  console.log(`  Processing time: ${processingTime.toFixed(2)}ms`);
  console.log(`  Data chunks received: ${dataChunks}`);
  console.log(`  Bytes read: ${stats.bytesRead}`);
  console.log(`  Lines read: ${stats.linesRead}`);
  console.log(`  Throughput: ${(stats.bytesRead / (totalTime / 1000)).toFixed(0)} bytes/sec`);
  
  return {
    name,
    totalTime,
    firstDataLatency,
    processingTime,
    dataChunks,
    bytesRead: stats.bytesRead,
    linesRead: stats.linesRead,
    throughput: stats.bytesRead / (totalTime / 1000)
  };
}

// Resource usage monitoring
function getResourceUsage() {
  const usage = process.cpuUsage();
  const memUsage = process.memoryUsage();
  return {
    cpu: usage,
    memory: memUsage
  };
}

async function main() {
  console.log('🏁 Stream Performance Benchmark');
  console.log(`Test file: ${TEST_FILE}`);
  console.log(`Lines to write: ${TEST_LINES}`);
  console.log(`Write delay: ${WRITE_DELAY}ms`);
  
  // Clean up any existing test file
  if (fs.existsSync(TEST_FILE)) {
    fs.unlinkSync(TEST_FILE);
  }
  
  const results = [];
  
  // Test fs.watch()
  const fsWatchResult = await benchmarkStreamer(FSWatchStreamer, 'fs.watch()');
  results.push(fsWatchResult);
  
  // Wait between tests
  await new Promise(resolve => setTimeout(resolve, 1000));
  
  // Test tail -f
  const tailResult = await benchmarkStreamer(TailStreamer, 'tail -f');
  results.push(tailResult);
  
  // Comparison
  console.log('\n🏆 COMPARISON:');
  console.log('=================');
  
  const fsWatch = results[0];
  const tail = results[1];
  
  console.log(`Setup latency:`);
  console.log(`  fs.watch(): ${fsWatch.firstDataLatency.toFixed(2)}ms`);
  console.log(`  tail -f:    ${tail.firstDataLatency.toFixed(2)}ms`);
  console.log(`  Winner:     ${fsWatch.firstDataLatency < tail.firstDataLatency ? 'fs.watch()' : 'tail -f'} (${Math.abs(fsWatch.firstDataLatency - tail.firstDataLatency).toFixed(2)}ms faster)`);
  
  console.log(`\nTotal time:`);
  console.log(`  fs.watch(): ${fsWatch.totalTime.toFixed(2)}ms`);
  console.log(`  tail -f:    ${tail.totalTime.toFixed(2)}ms`);
  console.log(`  Winner:     ${fsWatch.totalTime < tail.totalTime ? 'fs.watch()' : 'tail -f'} (${Math.abs(fsWatch.totalTime - tail.totalTime).toFixed(2)}ms faster)`);
  
  console.log(`\nThroughput:`);
  console.log(`  fs.watch(): ${fsWatch.throughput.toFixed(0)} bytes/sec`);
  console.log(`  tail -f:    ${tail.throughput.toFixed(0)} bytes/sec`);
  console.log(`  Winner:     ${fsWatch.throughput > tail.throughput ? 'fs.watch()' : 'tail -f'} (${Math.abs(fsWatch.throughput - tail.throughput).toFixed(0)} bytes/sec faster)`);
  
  console.log(`\nData integrity:`);
  console.log(`  fs.watch(): ${fsWatch.linesRead} lines, ${fsWatch.bytesRead} bytes`);
  console.log(`  tail -f:    ${tail.linesRead} lines, ${tail.bytesRead} bytes`);
  console.log(`  Match:      ${fsWatch.bytesRead === tail.bytesRead ? '✅ Both read same amount' : '❌ Different amounts read'}`);
  
  // Clean up
  if (fs.existsSync(TEST_FILE)) {
    fs.unlinkSync(TEST_FILE);
  }
  
  console.log('\n✨ Benchmark complete!');
}

if (require.main === module) {
  main().catch(console.error);
}