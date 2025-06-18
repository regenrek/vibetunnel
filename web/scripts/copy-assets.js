const fs = require('fs');
const path = require('path');

// Ensure public directory exists
fs.mkdirSync('public', { recursive: true });

// Copy assets
const srcDir = 'src/client/assets';
const destDir = 'public';

if (fs.existsSync(srcDir)) {
  fs.readdirSync(srcDir).forEach(file => {
    const srcPath = path.join(srcDir, file);
    const destPath = path.join(destDir, file);
    fs.cpSync(srcPath, destPath, { recursive: true });
  });
  console.log('Assets copied successfully');
} else {
  console.log('No assets directory found, skipping copy');
}