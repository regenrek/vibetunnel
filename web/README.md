# VibeTunnel Web Frontend

A modern web interface for the VibeTunnel terminal multiplexer built with TypeScript, Lit Elements, and XTerm.js. Provides professional terminal emulation with mobile-optimized controls and real-time session management.

## Features

- **Professional Terminal Emulation** using XTerm.js with full VT compatibility
- **Real-time Session Management** with live streaming via Server-Sent Events
- **Mobile-Optimized Interface** with touch controls and responsive design
- **Session Snapshots** for previewing terminal output in card view
- **Interactive Terminal Input** with full keyboard support and mobile input overlay
- **VS Code Dark Theme** with consistent styling throughout
- **Custom Font Support** using Fira Code with programming ligatures
- **File Browser** for selecting working directories
- **Session Lifecycle Management** (create, monitor, kill, cleanup)

## Quick Start

1. **Install dependencies:**
   ```bash
   npm install
   ```

2. **Start development server:**
   ```bash
   npm run dev
   ```

3. **Open browser:**
   Navigate to `http://localhost:3000`

## Development Scripts

```bash
# Development (auto-rebuild and watch)
npm run dev                 # Start full dev environment
npm run watch:server        # Watch server TypeScript only
npm run watch:css          # Watch CSS changes only

# Building
npm run build              # Build everything for production
npm run build:server       # Build server TypeScript
npm run build:client       # Build client TypeScript  
npm run build:css          # Build Tailwind CSS

# Bundling (ES modules)
npm run bundle             # Bundle client code
npm run bundle:watch       # Watch and bundle client code

# Code Quality
npm run lint               # Check ESLint issues
npm run lint:fix           # Auto-fix ESLint issues
npm run format             # Format code with Prettier
npm run format:check       # Check code formatting
npm run pre-commit         # Run all quality checks

# Testing
npm run test               # Run Jest tests
npm run test:watch         # Watch and run tests
```

## Architecture

### Client-Side Components

Built with **Lit Elements** (Web Components):

```
src/client/
├── app.ts                    # Main application controller
├── components/
│   ├── app-header.ts         # Main navigation and controls
│   ├── session-list.ts       # Session grid with cards
│   ├── session-card.ts       # Individual session preview
│   ├── session-view.ts       # Full terminal view
│   ├── session-create-form.ts # New session modal
│   └── file-browser.ts       # Directory selection
├── renderer.ts               # XTerm.js terminal renderer
└── scale-fit-addon.ts        # Custom terminal scaling
```

### Server-Side Architecture

**Express.js** server with **tty-fwd integration**:

```
src/
├── server.ts                 # Main Express server
└── input.css                # Tailwind source styles
```

### Build Output

```
dist/                         # Compiled TypeScript
public/
├── bundle/
│   ├── client-bundle.js      # Bundled client code
│   ├── renderer.js           # Terminal renderer
│   └── output.css            # Compiled styles
├── fonts/                    # Fira Code font files
└── index.html                # Main HTML
```

## API Reference

### Session Management

```
GET    /api/sessions                    # List all sessions
POST   /api/sessions                    # Create new session
DELETE /api/sessions/:id                # Kill session
DELETE /api/sessions/:id/cleanup        # Clean up session files
POST   /api/cleanup-exited              # Clean all exited sessions
```

### Terminal I/O

```
GET    /api/sessions/:id/stream         # Live session stream (SSE)
GET    /api/sessions/:id/snapshot       # Session snapshot (cast format)
POST   /api/sessions/:id/input          # Send input to session
```

### File System

```
GET    /api/fs/browse?path=<path>       # Browse directories
POST   /api/mkdir                       # Create directory
```

## Technology Stack

- **Frontend Framework:** Lit Elements (Web Components)
- **Terminal Emulation:** XTerm.js with custom addons
- **Styling:** Tailwind CSS with VS Code theme
- **Typography:** Fira Code Variable Font
- **Backend:** Express.js + TypeScript
- **Terminal Backend:** tty-fwd (Rust binary)
- **Build Tools:** TypeScript, ESBuild, Tailwind
- **Code Quality:** ESLint, Prettier, Pre-commit hooks

## Mobile Support

- **Touch-optimized scrolling** with proper overscroll prevention
- **Mobile input overlay** with virtual keyboard support
- **Responsive design** with mobile-first approach
- **Gesture navigation** (swipe from edge to go back)
- **Pull-to-refresh prevention** during terminal interaction

## Browser Compatibility

- **Modern ES6+ browsers** (Chrome 63+, Firefox 67+, Safari 13+)
- **Mobile browsers** with full touch support
- **Progressive enhancement** with graceful degradation

## Deployment

1. **Build for production:**
   ```bash
   npm run build
   ```

2. **Start production server:**
   ```bash
   npm start
   ```

3. **Environment variables:**
   - `PORT` - Server port (default: 3000)
   - `TTY_FWD_CONTROL_DIR` - tty-fwd control directory

## Development Notes

- **Hot reload** enabled in development
- **TypeScript strict mode** with comprehensive type checking
- **ESLint + Prettier** enforced via pre-commit hooks
- **Component-based architecture** for maintainability
- **Mobile-first responsive design** principles