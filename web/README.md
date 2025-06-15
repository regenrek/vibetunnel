# VibeTunnel Web Frontend

A web interface for the VibeTunnel terminal multiplexer. This frontend allows you to view and interact with multiple terminal sessions through a browser interface.

## Features

- View multiple terminal processes in a web interface
- Real-time terminal output using asciinema player
- Interactive terminal input via WebSocket connections
- Terminal-themed UI with monospace fonts
- Mock server for development without backend dependencies

## Setup

1. **Install dependencies:**
   ```bash
   npm install
   ```

2. **Build CSS:**
   ```bash
   npm run build-css
   ```

## Development

1. **Start the development server:**
   ```bash
   npm run dev
   ```

2. **Open your browser:**
   Navigate to `http://localhost:3000`

3. **CSS Development:**
   For live CSS rebuilding during development, run in a separate terminal:
   ```bash
   npm run build-css
   ```

The development server includes:
- Mock API endpoints for process management
- Mock WebSocket connections with sample terminal data
- Hot reloading for server changes (restart with `npm run dev`)

## Build for Deployment

To build the project for production deployment:

1. **Compile TypeScript:**
   ```bash
   npm run build
   ```

2. **Build CSS:**
   ```bash
   npm run build-css
   ```

3. **Create deployment files:**
   ```bash
   # Create dist directory structure
   mkdir -p dist/public
   
   # Copy static files
   cp public/index.html dist/public/
   cp public/app.js dist/public/
   cp public/output.css dist/public/
   
   # The compiled server will be in dist/server.js
   ```

After building, your `dist/` folder will contain:
- `dist/server.js` - Compiled Express server
- `dist/public/index.html` - Main HTML file
- `dist/public/app.js` - Client-side JavaScript
- `dist/public/output.css` - Compiled Tailwind CSS

## Deployment

1. **Production server:**
   ```bash
   npm start
   ```

2. **Environment variables:**
   - `PORT` - Server port (default: 3000)

## Project Structure

```
src/
├── server.ts          # Express server with mock API and WebSocket
├── input.css          # Tailwind CSS source
public/
├── index.html         # Main HTML interface
└── app.js            # Client-side terminal management
dist/                  # Built files (created after build)
├── server.js         # Compiled server
└── public/           # Static assets
```

## API Endpoints

The mock server provides these endpoints:

- `GET /api/processes` - List all processes
- `GET /api/processes/:id` - Get specific process details
- `WebSocket /?processId=:id` - Connect to process terminal stream

## Technology Stack

- **Frontend:** Vanilla JavaScript, Tailwind CSS, Asciinema Player
- **Backend:** Express.js, WebSocket, TypeScript
- **Build Tools:** TypeScript Compiler, Tailwind CSS, PostCSS