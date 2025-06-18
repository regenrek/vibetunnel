const fs = require('fs');
const path = require('path');

function removeRecursive(dirPath) {
  if (fs.existsSync(dirPath)) {
    fs.rmSync(dirPath, { recursive: true, force: true });
    console.log(`Removed: ${dirPath}`);
  }
}

// Clean public and dist directories
removeRecursive('public');
removeRecursive('dist');

console.log('Clean completed successfully');