import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    setupFiles: ['./src/test/setup.integration.ts'],
    include: ['src/test/integration/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html', 'lcov'],
      exclude: [
        'node_modules/',
        'src/test/',
        'dist/',
        'public/',
        '*.config.ts',
        '*.config.js',
        '**/*.test.ts',
        '**/*.spec.ts',
      ],
      include: [
        'src/**/*.ts',
        'src/**/*.js',
      ],
      all: true,
    },
    testTimeout: 30000, // Integration tests may take longer
    pool: 'forks', // Use separate processes for integration tests
    poolOptions: {
      forks: {
        singleFork: true, // Run tests sequentially to avoid port conflicts
      },
    },
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
});