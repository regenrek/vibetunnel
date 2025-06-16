"use strict";
// Terminal renderer for asciinema cast format with DOM rendering
// Supports complete cast files and streaming events
Object.defineProperty(exports, "__esModule", { value: true });
exports.TerminalRenderer = void 0;
class TerminalRenderer {
    constructor(container, width = 80, height = 20) {
        this.maxScrollback = 1000;
        this.ansiColorMap = [
            '#000000', '#cc241d', '#98971a', '#d79921', // Standard colors (0-7) - brighter
            '#458588', '#b16286', '#689d6a', '#a89984',
            '#928374', '#fb4934', '#b8bb26', '#fabd2f', // Bright colors (8-15) - very bright
            '#83a598', '#d3869b', '#8ec07c', '#ebdbb2'
        ];
        this.container = container;
        this.state = {
            width,
            height,
            cursorX: 0,
            cursorY: 0,
            currentFg: '#ffffff',
            currentBg: '#000000',
            bold: false,
            italic: false,
            underline: false,
            strikethrough: false,
            inverse: false,
            alternateScreen: false,
            scrollRegionTop: 0,
            scrollRegionBottom: height - 1,
            originMode: false,
            autowrap: true,
            insertMode: false
        };
        this.primaryBuffer = this.createBuffer(width, height);
        this.alternateBuffer = this.createBuffer(width, height);
        this.scrollbackBuffer = [];
        this.setupDOM();
    }
    createBuffer(width, height) {
        const buffer = [];
        for (let y = 0; y < height; y++) {
            buffer[y] = [];
            for (let x = 0; x < width; x++) {
                buffer[y][x] = {
                    char: ' ',
                    fg: '#ffffff',
                    bg: '#000000',
                    bold: false,
                    italic: false,
                    underline: false,
                    strikethrough: false,
                    inverse: false
                };
            }
        }
        return buffer;
    }
    setupDOM() {
        this.container.style.fontFamily = 'Monaco, "Lucida Console", monospace';
        this.container.style.fontSize = '14px';
        this.container.style.lineHeight = '1.2';
        this.container.style.backgroundColor = '#000000';
        this.container.style.color = '#ffffff';
        this.container.style.padding = '10px';
        this.container.style.overflow = 'auto';
        this.container.style.whiteSpace = 'pre';
        this.container.innerHTML = '';
    }
    getCurrentBuffer() {
        return this.state.alternateScreen ? this.alternateBuffer : this.primaryBuffer;
    }
    renderBuffer() {
        const buffer = this.getCurrentBuffer();
        const allLines = [];
        // Render scrollback buffer first (only for primary screen)
        if (!this.state.alternateScreen && this.scrollbackBuffer.length > 0) {
            for (let i = 0; i < this.scrollbackBuffer.length; i++) {
                const line = this.renderLine(this.scrollbackBuffer[i]);
                allLines.push(`<div class="scrollback-line">${line}</div>`);
            }
        }
        // Render current buffer
        for (let y = 0; y < this.state.height; y++) {
            const line = this.renderLine(buffer[y]);
            const isCurrentLine = y === this.state.cursorY;
            allLines.push(`<div class="terminal-line ${isCurrentLine ? 'current-line' : ''}">${line}</div>`);
        }
        this.container.innerHTML = allLines.join('');
        // Auto-scroll to bottom unless user has scrolled up
        if (this.container.scrollTop + this.container.clientHeight >= this.container.scrollHeight - 10) {
            this.container.scrollTop = this.container.scrollHeight;
        }
    }
    renderLine(lineBuffer) {
        let line = '';
        let lastBg = '';
        let lastFg = '';
        let lastStyles = '';
        let spanOpen = false;
        for (let x = 0; x < lineBuffer.length; x++) {
            const cell = lineBuffer[x];
            const fg = cell.inverse ? cell.bg : cell.fg;
            const bg = cell.inverse ? cell.fg : cell.bg;
            let styles = '';
            if (cell.bold)
                styles += 'font-weight: bold; ';
            if (cell.italic)
                styles += 'font-style: italic; ';
            if (cell.underline)
                styles += 'text-decoration: underline; ';
            if (cell.strikethrough)
                styles += 'text-decoration: line-through; ';
            if (fg !== lastFg || bg !== lastBg || styles !== lastStyles) {
                if (spanOpen) {
                    line += '</span>';
                    spanOpen = false;
                }
                // Always add span for consistent rendering
                line += `<span style="color: ${fg}; background-color: ${bg}; ${styles}">`;
                spanOpen = true;
                lastFg = fg;
                lastBg = bg;
                lastStyles = styles;
            }
            const char = cell.char || ' ';
            line += char === ' ' ? '&nbsp;' : this.escapeHtml(char);
        }
        // Close any open span
        if (spanOpen) {
            line += '</span>';
        }
        return line || '&nbsp;'; // Ensure empty lines have height
    }
    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
    parseAnsiSequence(data) {
        let i = 0;
        while (i < data.length) {
            const char = data[i];
            if (char === '\x1b' && i + 1 < data.length && data[i + 1] === '[') {
                // CSI sequence
                i += 2;
                let params = '';
                let finalChar = '';
                while (i < data.length) {
                    const c = data[i];
                    if (c >= '0' && c <= '9' || c === ';' || c === ':') {
                        params += c;
                    }
                    else {
                        finalChar = c;
                        break;
                    }
                    i++;
                }
                this.handleCSI(params, finalChar);
            }
            else if (char === '\x1b' && i + 1 < data.length && data[i + 1] === ']') {
                // OSC sequence - skip for now
                i += 2;
                while (i < data.length && data[i] !== '\x07' && data[i] !== '\x1b') {
                    i++;
                }
                if (i < data.length && data[i] === '\x1b' && i + 1 < data.length && data[i + 1] === '\\') {
                    i++; // Skip the backslash too
                }
            }
            else if (char === '\r') {
                this.state.cursorX = 0;
            }
            else if (char === '\n') {
                this.newline();
            }
            else if (char === '\t') {
                this.state.cursorX = Math.min(this.state.width - 1, (Math.floor(this.state.cursorX / 8) + 1) * 8);
            }
            else if (char === '\b') {
                if (this.state.cursorX > 0) {
                    this.state.cursorX--;
                }
            }
            else if (char >= ' ' || char === '\x00') {
                this.writeChar(char === '\x00' ? ' ' : char);
            }
            i++;
        }
    }
    handleCSI(params, finalChar) {
        const paramList = params ? params.split(';').map(p => parseInt(p) || 0) : [0];
        switch (finalChar) {
            case 'A': // Cursor Up
                this.state.cursorY = Math.max(this.state.scrollRegionTop, this.state.cursorY - (paramList[0] || 1));
                break;
            case 'B': // Cursor Down
                this.state.cursorY = Math.min(this.state.scrollRegionBottom, this.state.cursorY + (paramList[0] || 1));
                break;
            case 'C': // Cursor Forward
                this.state.cursorX = Math.min(this.state.width - 1, this.state.cursorX + (paramList[0] || 1));
                break;
            case 'D': // Cursor Backward
                this.state.cursorX = Math.max(0, this.state.cursorX - (paramList[0] || 1));
                break;
            case 'H': // Cursor Position
            case 'f':
                this.state.cursorY = Math.min(this.state.height - 1, Math.max(0, (paramList[0] || 1) - 1));
                this.state.cursorX = Math.min(this.state.width - 1, Math.max(0, (paramList[1] || 1) - 1));
                break;
            case 'J': // Erase Display
                this.eraseDisplay(paramList[0] || 0);
                break;
            case 'K': // Erase Line
                this.eraseLine(paramList[0] || 0);
                break;
            case 'm': // Set Graphics Rendition
                this.handleSGR(paramList);
                break;
            case 'r': // Set Scroll Region
                this.state.scrollRegionTop = Math.max(0, (paramList[0] || 1) - 1);
                this.state.scrollRegionBottom = Math.min(this.state.height - 1, (paramList[1] || this.state.height) - 1);
                this.state.cursorX = 0;
                this.state.cursorY = this.state.scrollRegionTop;
                break;
            case 's': // Save Cursor Position
                // TODO: Implement cursor save/restore
                break;
            case 'u': // Restore Cursor Position
                // TODO: Implement cursor save/restore
                break;
            case 'h': // Set Mode
                if (params === '?1049' || params === '?47') {
                    this.state.alternateScreen = true;
                }
                else if (params === '?2004') {
                    // Bracketed paste mode - ignore
                }
                break;
            case 'l': // Reset Mode
                if (params === '?1049' || params === '?47') {
                    this.state.alternateScreen = false;
                }
                else if (params === '?2004') {
                    // Bracketed paste mode - ignore
                }
                break;
        }
    }
    handleSGR(params) {
        for (let i = 0; i < params.length; i++) {
            const param = params[i];
            if (param === 0) {
                // Reset
                this.state.currentFg = '#ffffff';
                this.state.currentBg = '#000000';
                this.state.bold = false;
                this.state.italic = false;
                this.state.underline = false;
                this.state.strikethrough = false;
                this.state.inverse = false;
            }
            else if (param === 1) {
                this.state.bold = true;
            }
            else if (param === 3) {
                this.state.italic = true;
            }
            else if (param === 4) {
                this.state.underline = true;
            }
            else if (param === 7) {
                this.state.inverse = true;
            }
            else if (param === 9) {
                this.state.strikethrough = true;
            }
            else if (param === 22) {
                this.state.bold = false;
            }
            else if (param === 23) {
                this.state.italic = false;
            }
            else if (param === 24) {
                this.state.underline = false;
            }
            else if (param === 27) {
                this.state.inverse = false;
            }
            else if (param === 29) {
                this.state.strikethrough = false;
            }
            else if (param === 39) {
                // Default foreground color
                this.state.currentFg = '#ffffff';
            }
            else if (param === 49) {
                // Default background color
                this.state.currentBg = '#000000';
            }
            else if (param >= 30 && param <= 37) {
                // Standard foreground colors
                this.state.currentFg = this.ansiColorMap[param - 30];
            }
            else if (param >= 40 && param <= 47) {
                // Standard background colors
                this.state.currentBg = this.ansiColorMap[param - 40];
            }
            else if (param >= 90 && param <= 97) {
                // Bright foreground colors
                this.state.currentFg = this.ansiColorMap[param - 90 + 8];
            }
            else if (param >= 100 && param <= 107) {
                // Bright background colors
                this.state.currentBg = this.ansiColorMap[param - 100 + 8];
            }
            else if (param === 38) {
                // Extended foreground color
                if (i + 1 < params.length && params[i + 1] === 2 && i + 4 < params.length) {
                    // RGB: 38;2;r;g;b
                    const r = params[i + 2];
                    const g = params[i + 3];
                    const b = params[i + 4];
                    this.state.currentFg = `rgb(${r},${g},${b})`;
                    i += 4;
                }
                else if (i + 1 < params.length && params[i + 1] === 5 && i + 2 < params.length) {
                    // 256-color: 38;5;n
                    this.state.currentFg = this.get256Color(params[i + 2]);
                    i += 2;
                }
            }
            else if (param === 48) {
                // Extended background color
                if (i + 1 < params.length && params[i + 1] === 2 && i + 4 < params.length) {
                    // RGB: 48;2;r;g;b
                    const r = params[i + 2];
                    const g = params[i + 3];
                    const b = params[i + 4];
                    this.state.currentBg = `rgb(${r},${g},${b})`;
                    i += 4;
                }
                else if (i + 1 < params.length && params[i + 1] === 5 && i + 2 < params.length) {
                    // 256-color: 48;5;n
                    this.state.currentBg = this.get256Color(params[i + 2]);
                    i += 2;
                }
            }
        }
    }
    get256Color(index) {
        if (index < 16) {
            return this.ansiColorMap[index];
        }
        else if (index < 232) {
            // 216 color cube
            const n = index - 16;
            const r = Math.floor(n / 36);
            const g = Math.floor((n % 36) / 6);
            const b = n % 6;
            const values = [0, 95, 135, 175, 215, 255];
            return `rgb(${values[r]},${values[g]},${values[b]})`;
        }
        else {
            // Grayscale
            const gray = 8 + (index - 232) * 10;
            return `rgb(${gray},${gray},${gray})`;
        }
    }
    eraseDisplay(mode) {
        const buffer = this.getCurrentBuffer();
        switch (mode) {
            case 0: // Erase from cursor to end of screen
                this.eraseLine(0);
                for (let y = this.state.cursorY + 1; y < this.state.height; y++) {
                    for (let x = 0; x < this.state.width; x++) {
                        buffer[y][x] = this.createEmptyCell();
                    }
                }
                break;
            case 1: // Erase from beginning of screen to cursor
                for (let y = 0; y < this.state.cursorY; y++) {
                    for (let x = 0; x < this.state.width; x++) {
                        buffer[y][x] = this.createEmptyCell();
                    }
                }
                this.eraseLine(1);
                break;
            case 2: // Erase entire screen
            case 3: // Erase entire screen and scrollback
                for (let y = 0; y < this.state.height; y++) {
                    for (let x = 0; x < this.state.width; x++) {
                        buffer[y][x] = this.createEmptyCell();
                    }
                }
                if (mode === 3) {
                    this.scrollbackBuffer = [];
                }
                break;
        }
    }
    eraseLine(mode) {
        const buffer = this.getCurrentBuffer();
        const y = this.state.cursorY;
        switch (mode) {
            case 0: // Erase from cursor to end of line
                for (let x = this.state.cursorX; x < this.state.width; x++) {
                    buffer[y][x] = this.createEmptyCell();
                }
                break;
            case 1: // Erase from beginning of line to cursor
                for (let x = 0; x <= this.state.cursorX; x++) {
                    buffer[y][x] = this.createEmptyCell();
                }
                break;
            case 2: // Erase entire line
                for (let x = 0; x < this.state.width; x++) {
                    buffer[y][x] = this.createEmptyCell();
                }
                break;
        }
    }
    createEmptyCell() {
        return {
            char: ' ',
            fg: this.state.currentFg,
            bg: this.state.currentBg,
            bold: false,
            italic: false,
            underline: false,
            strikethrough: false,
            inverse: false
        };
    }
    writeChar(char) {
        const buffer = this.getCurrentBuffer();
        if (this.state.cursorX >= this.state.width) {
            if (this.state.autowrap) {
                this.newline();
            }
            else {
                this.state.cursorX = this.state.width - 1;
            }
        }
        buffer[this.state.cursorY][this.state.cursorX] = {
            char,
            fg: this.state.currentFg,
            bg: this.state.currentBg,
            bold: this.state.bold,
            italic: this.state.italic,
            underline: this.state.underline,
            strikethrough: this.state.strikethrough,
            inverse: this.state.inverse
        };
        this.state.cursorX++;
    }
    newline() {
        this.state.cursorX = 0;
        if (this.state.cursorY >= this.state.scrollRegionBottom) {
            this.scrollUp();
        }
        else {
            this.state.cursorY++;
        }
    }
    scrollUp() {
        const buffer = this.getCurrentBuffer();
        // Add the top line to scrollback if we're in primary buffer
        if (!this.state.alternateScreen) {
            this.scrollbackBuffer.push([...buffer[this.state.scrollRegionTop]]);
            if (this.scrollbackBuffer.length > this.maxScrollback) {
                this.scrollbackBuffer.shift();
            }
        }
        // Scroll the region
        for (let y = this.state.scrollRegionTop; y < this.state.scrollRegionBottom; y++) {
            buffer[y] = [...buffer[y + 1]];
        }
        // Clear the bottom line
        for (let x = 0; x < this.state.width; x++) {
            buffer[this.state.scrollRegionBottom][x] = this.createEmptyCell();
        }
    }
    // Public API methods
    async loadCastFile(url) {
        const response = await fetch(url);
        const text = await response.text();
        this.parseCastFile(text);
    }
    parseCastFile(content) {
        const lines = content.trim().split('\n');
        let header = null;
        for (const line of lines) {
            if (!line.trim())
                continue;
            try {
                const parsed = JSON.parse(line);
                if (parsed.version && parsed.width && parsed.height) {
                    // Header
                    header = parsed;
                    this.resize(parsed.width, parsed.height);
                }
                else if (Array.isArray(parsed) && parsed.length >= 3) {
                    // Event: [timestamp, type, data]
                    const event = {
                        timestamp: parsed[0],
                        type: parsed[1],
                        data: parsed[2]
                    };
                    if (event.type === 'o') {
                        this.processOutput(event.data);
                    }
                }
            }
            catch (e) {
                console.warn('Failed to parse cast line:', line);
            }
        }
        this.renderBuffer();
    }
    processOutput(data) {
        this.parseAnsiSequence(data);
        this.renderBuffer();
    }
    processEvent(event) {
        if (event.type === 'o') {
            this.processOutput(event.data);
            this.renderBuffer();
        }
    }
    resize(width, height) {
        this.state.width = width;
        this.state.height = height;
        this.state.scrollRegionBottom = height - 1;
        this.primaryBuffer = this.createBuffer(width, height);
        this.alternateBuffer = this.createBuffer(width, height);
        this.state.cursorX = 0;
        this.state.cursorY = 0;
    }
    clear() {
        this.primaryBuffer = this.createBuffer(this.state.width, this.state.height);
        this.alternateBuffer = this.createBuffer(this.state.width, this.state.height);
        this.scrollbackBuffer = [];
        this.state.cursorX = 0;
        this.state.cursorY = 0;
        this.state.alternateScreen = false;
        this.renderBuffer();
    }
    // Stream support - connect to SSE endpoint
    connectToStream(sessionId) {
        const eventSource = new EventSource(`/api/sessions/${sessionId}/stream`);
        eventSource.onmessage = (event) => {
            try {
                const data = JSON.parse(event.data);
                if (data.version && data.width && data.height) {
                    // Header
                    this.resize(data.width, data.height);
                }
                else if (Array.isArray(data) && data.length >= 3) {
                    // Event
                    const castEvent = {
                        timestamp: data[0],
                        type: data[1],
                        data: data[2]
                    };
                    this.processEvent(castEvent);
                }
            }
            catch (e) {
                console.warn('Failed to parse stream event:', event.data);
            }
        };
        eventSource.onerror = (error) => {
            console.error('Stream error:', error);
        };
        return eventSource;
    }
}
exports.TerminalRenderer = TerminalRenderer;
//# sourceMappingURL=renderer.js.map