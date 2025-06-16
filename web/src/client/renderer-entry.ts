// Entry point for renderer bundle - exports both renderers for tests
export { TerminalRenderer } from './renderer.js';
export { XTermRenderer } from './xterm-renderer.js';

// Also export with shorter alias for convenience
export { TerminalRenderer as Renderer } from './renderer.js';