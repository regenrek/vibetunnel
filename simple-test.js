const fs = require('fs');

const TEST_FILE = '/tmp/simple-test.log';

// Create test file
fs.writeFileSync(TEST_FILE, 'initial content\n');

console.log('File created with initial content');
console.log('File size:', fs.statSync(TEST_FILE).size);

let lastOffset = fs.statSync(TEST_FILE).size;
let totalBytes = 0;

const watcher = fs.watch(TEST_FILE, (eventType) => {
  if (eventType === 'change') {
    const stats = fs.statSync(TEST_FILE);
    console.log(`Change detected. File size: ${stats.size}, lastOffset: ${lastOffset}`);
    
    if (stats.size > lastOffset) {
      // Read only the new data since lastOffset
      const fd = fs.openSync(TEST_FILE, 'r');
      const buffer = Buffer.alloc(stats.size - lastOffset);
      fs.readSync(fd, buffer, 0, buffer.length, lastOffset);
      fs.closeSync(fd);
      
      const newData = buffer;
      
      console.log(`Read ${newData.length} bytes: "${newData.toString().trim()}"`);
      totalBytes += newData.length;
      lastOffset = stats.size;
    }
  }
});

// Append some data
setTimeout(() => {
  console.log('\nAppending line 1...');
  fs.appendFileSync(TEST_FILE, 'line 1\n');
}, 100);

setTimeout(() => {
  console.log('\nAppending line 2...');
  fs.appendFileSync(TEST_FILE, 'line 2\n');
}, 200);

setTimeout(() => {
  console.log('\nAppending line 3...');
  fs.appendFileSync(TEST_FILE, 'line 3\n');
}, 300);

setTimeout(() => {
  console.log(`\nTotal bytes read: ${totalBytes}`);
  console.log('Final file size:', fs.statSync(TEST_FILE).size);
  console.log('File contents:');
  console.log(fs.readFileSync(TEST_FILE, 'utf8'));
  
  watcher.close();
  fs.unlinkSync(TEST_FILE);
}, 500);