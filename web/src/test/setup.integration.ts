import { vi } from 'vitest';

// Set test environment
process.env.NODE_ENV = 'test';
process.env.VITEST_INTEGRATION = 'true';

// Don't mock dependencies for integration tests
// We want to test the real implementation

// Set up global test utilities
global.fetch = vi.fn();

// Increase timeout for integration tests
vi.setConfig({ testTimeout: 30000 });

// Clean up any leftover test data
import fs from 'fs';
import path from 'path';
import os from 'os';

const cleanupTestDirectories = () => {
  const testDirPattern = /vibetunnel-(test|ws-test|lifecycle-test)/;
  const tmpDir = os.tmpdir();

  try {
    const entries = fs.readdirSync(tmpDir);
    entries.forEach((entry) => {
      if (testDirPattern.test(entry)) {
        const fullPath = path.join(tmpDir, entry);
        try {
          fs.rmSync(fullPath, { recursive: true, force: true });
        } catch (e) {
          // Ignore errors during cleanup
        }
      }
    });
  } catch (e) {
    // Ignore errors
  }
};

// Clean up before tests
cleanupTestDirectories();
