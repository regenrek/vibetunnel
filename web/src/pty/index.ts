/**
 * PTY Module Entry Point
 *
 * This module exports all the PTY-related components for easy integration
 * with the existing server code.
 */

// Core types
export * from './types.js';

// Main service interface
export { PtyService } from './PtyService.js';

// Individual components (for advanced usage)
export { PtyManager } from './PtyManager.js';
export { AsciinemaWriter } from './AsciinemaWriter.js';
export { SessionManager } from './SessionManager.js';

// Re-export for convenience
export { PtyError } from './types.js';
