// Type definitions for asciinema-player
declare var AsciinemaPlayer: {
    create(
        cast: string | { driver: string; url: string; } | { data: any[]; version: number; width: number; height: number; timestamp: number; env: any },
        element: HTMLElement,
        options?: { theme?: string; loop?: boolean; autoPlay?: boolean; controls?: boolean; fit?: string; logger?: any }
    ): any;
};

interface ProcessMetadata {
    processId: string;
    command: string;
    workingDir: string;
    startDate: string;
    lastModified: string;
    exitCode?: number;
    error?: string;
}

interface CastEvent {
    0: number; // timestamp
    1: string; // type ('o' for output, 'i' for input, 'r' for resize)
    2: string; // data
}

interface WebSocketMessage {
    type: 'input' | 'reload';
    data?: string;
}

interface FileInfo {
    name: string;
    created: string;
    lastModified: string;
    size: number;
    isDir: boolean;
}

interface DirectoryListing {
    absolutePath: string;
    files: FileInfo[];
}

type Route = 'processes' | 'terminal';

class VibeTunnelApp {
    private currentRoute: Route = 'processes';
    private currentProcess: ProcessMetadata | null = null;
    private websocket: WebSocket | null = null;
    private eventSource: EventSource | null = null;
    private player: any = null;
    private hotReloadWs: WebSocket | null = null;
    private processRefreshInterval: number | null = null;
    private currentDirPath: string = '~/';
    private processesCache: ProcessMetadata[] = [];
    
    // Page elements
    private processListPageEl!: HTMLElement;
    private terminalPageEl!: HTMLElement;
    
    // Process list page elements
    private processListEl!: HTMLElement;
    private refreshBtn!: HTMLButtonElement;
    private createProcessFormEl!: HTMLFormElement;
    private workingDirEl!: HTMLInputElement;
    private commandEl!: HTMLInputElement;
    private browseDirBtn!: HTMLButtonElement;
    
    // Terminal page elements
    private currentProcessEl!: HTMLElement;
    private terminalPlayerEl!: HTMLElement;
    private terminalInputEl!: HTMLInputElement;
    private sendInputBtn!: HTMLButtonElement;
    private backToProcessesBtn!: HTMLButtonElement;
    private killCurrentProcessBtn!: HTMLButtonElement;
    
    // Directory browser elements
    private dirBrowserModalEl!: HTMLElement;
    private dirBrowserContentEl!: HTMLElement;
    private currentDirPathEl!: HTMLElement;
    private closeDirBrowserBtn!: HTMLButtonElement;
    private cancelDirBrowserBtn!: HTMLButtonElement;
    private selectDirBtn!: HTMLButtonElement;
    
    // Navigation elements
    private homeLinkEl!: HTMLElement;
    
    constructor() {
        this.initializeElements();
        this.setupEventListeners();
        this.setupHotReload();
        this.handleRouting();
        this.startProcessRefresh();
    }
    
    private initializeElements(): void {
        // Page elements
        this.processListPageEl = document.getElementById('process-list-page')!;
        this.terminalPageEl = document.getElementById('terminal-page')!;
        
        // Process list page elements
        this.processListEl = document.getElementById('process-list')!;
        this.refreshBtn = document.getElementById('refresh-processes') as HTMLButtonElement;
        this.createProcessFormEl = document.getElementById('create-process-form') as HTMLFormElement;
        this.workingDirEl = document.getElementById('working-dir') as HTMLInputElement;
        this.commandEl = document.getElementById('command') as HTMLInputElement;
        this.browseDirBtn = document.getElementById('browse-dir') as HTMLButtonElement;
        
        // Terminal page elements
        this.currentProcessEl = document.getElementById('current-process')!;
        this.terminalPlayerEl = document.getElementById('terminal-player')!;
        this.terminalInputEl = document.getElementById('terminal-input') as HTMLInputElement;
        this.sendInputBtn = document.getElementById('send-input') as HTMLButtonElement;
        this.backToProcessesBtn = document.getElementById('back-to-processes') as HTMLButtonElement;
        this.killCurrentProcessBtn = document.getElementById('kill-current-process') as HTMLButtonElement;
        
        // Directory browser elements
        this.dirBrowserModalEl = document.getElementById('dir-browser-modal')!;
        this.dirBrowserContentEl = document.getElementById('dir-browser-content')!;
        this.currentDirPathEl = document.getElementById('current-dir-path')!;
        this.closeDirBrowserBtn = document.getElementById('close-dir-browser') as HTMLButtonElement;
        this.cancelDirBrowserBtn = document.getElementById('cancel-dir-browser') as HTMLButtonElement;
        this.selectDirBtn = document.getElementById('select-dir') as HTMLButtonElement;
        
        // Navigation elements
        this.homeLinkEl = document.getElementById('home-link')!;
    }
    
    private setupEventListeners(): void {
        // Navigation
        this.homeLinkEl.addEventListener('click', (e) => {
            e.preventDefault();
            this.navigateToProcesses();
        });
        
        this.backToProcessesBtn.addEventListener('click', () => {
            this.navigateToProcesses();
        });
        
        this.killCurrentProcessBtn.addEventListener('click', () => {
            if (this.currentProcess) {
                this.killSession(this.currentProcess.processId);
            }
        });
        
        // Process list page
        this.refreshBtn.addEventListener('click', () => this.loadProcesses());
        this.createProcessFormEl.addEventListener('submit', (e) => this.handleCreateProcess(e));
        this.browseDirBtn.addEventListener('click', () => this.openDirectoryBrowser());
        
        // Terminal page
        this.sendInputBtn.addEventListener('click', () => this.sendInput());
        this.terminalInputEl.addEventListener('keypress', (e: KeyboardEvent) => {
            if (e.key === 'Enter') {
                this.sendInput();
            }
        });
        
        // Directory browser
        this.closeDirBrowserBtn.addEventListener('click', () => this.closeDirectoryBrowser());
        this.cancelDirBrowserBtn.addEventListener('click', () => this.closeDirectoryBrowser());
        this.selectDirBtn.addEventListener('click', () => this.selectCurrentDirectory());
        
        // Handle browser back/forward
        window.addEventListener('popstate', () => this.handleRouting());
        
        // Global keyboard capture for terminal
        this.setupGlobalKeyCapture();
    }
    
    private setupGlobalKeyCapture(): void {
        // Capture all keyboard events when in terminal mode
        document.addEventListener('keydown', (e: KeyboardEvent) => {
            // Only capture keys when viewing a terminal and not in input fields
            if (this.currentRoute !== 'terminal' || !this.currentProcess) {
                return;
            }
            
            // Don't capture keys when user is in input fields (except terminal input)
            const target = e.target as HTMLElement;
            if (target.tagName === 'INPUT' && target !== this.terminalInputEl) {
                return;
            }
            
            // Don't capture keys when user is in other form elements
            if (target.tagName === 'TEXTAREA' || target.tagName === 'SELECT') {
                return;
            }
            
            // Don't capture browser shortcuts (Ctrl+R, Ctrl+T, etc.)
            if (e.ctrlKey && ['r', 't', 'w', 'n', 'shift+t'].includes(e.key.toLowerCase())) {
                return;
            }
            
            // Convert key event to terminal input
            const terminalKey = this.convertKeyToTerminalInput(e);
            if (terminalKey) {
                console.log('Captured key:', e.key, 'converted to:', terminalKey);
                this.sendKeyToTerminal(terminalKey);
                e.preventDefault();
                e.stopPropagation();
            }
        });
    }
    
    private convertKeyToTerminalInput(e: KeyboardEvent): string | null {
        // Handle special keys first
        const specialKeys: { [key: string]: string } = {
            'Enter': '\r',
            'Backspace': '\x7f',
            'Tab': '\t',
            'Escape': '\x1b',
            'ArrowUp': '\x1b[A',
            'ArrowDown': '\x1b[B',
            'ArrowRight': '\x1b[C',
            'ArrowLeft': '\x1b[D',
            'Home': '\x1b[H',
            'End': '\x1b[F',
            'PageUp': '\x1b[5~',
            'PageDown': '\x1b[6~',
            'Insert': '\x1b[2~',
            'Delete': '\x1b[3~',
            'F1': '\x1bOP',
            'F2': '\x1bOQ',
            'F3': '\x1bOR',
            'F4': '\x1bOS',
            'F5': '\x1b[15~',
            'F6': '\x1b[17~',
            'F7': '\x1b[18~',
            'F8': '\x1b[19~',
            'F9': '\x1b[20~',
            'F10': '\x1b[21~',
            'F11': '\x1b[23~',
            'F12': '\x1b[24~'
        };
        
        // Handle Ctrl combinations
        if (e.ctrlKey && e.key.length === 1) {
            const code = e.key.toLowerCase().charCodeAt(0);
            if (code >= 97 && code <= 122) { // a-z
                return String.fromCharCode(code - 96); // Ctrl+A = \x01, Ctrl+C = \x03, etc.
            }
        }
        
        // Handle Alt combinations (ESC prefix)
        if (e.altKey && e.key.length === 1) {
            return '\x1b' + e.key;
        }
        
        // Check for special keys
        if (specialKeys[e.key]) {
            return specialKeys[e.key];
        }
        
        // Handle regular printable characters
        if (e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
            return e.key;
        }
        
        return null;
    }
    
    private async sendKeyToTerminal(key: string): Promise<void> {
        if (!this.currentProcess) {
            return;
        }
        
        try {
            const response = await fetch(`/api/input/${this.currentProcess.processId}`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    text: key
                })
            });
            
            if (!response.ok) {
                console.error('Failed to send key to terminal');
            }
        } catch (error) {
            console.error('Error sending key to terminal:', error);
        }
    }
    
    private handleRouting(): void {
        const hash = window.location.hash;
        if (hash.startsWith('#terminal/')) {
            const processId = hash.substring(10);
            this.navigateToTerminal(processId);
        } else {
            this.navigateToProcesses();
        }
    }
    
    private navigateToProcesses(): void {
        this.currentRoute = 'processes';
        this.processListPageEl.classList.remove('hidden');
        this.terminalPageEl.classList.add('hidden');
        this.disconnectWebSocket();
        this.removeKeyboardIndicator();
        this.loadProcesses();
        window.history.pushState({}, '', '#');
    }
    
    private async navigateToTerminal(processId: string): Promise<void> {
        this.currentRoute = 'terminal';
        this.processListPageEl.classList.add('hidden');
        this.terminalPageEl.classList.remove('hidden');
        
        // Find process metadata - load if not cached
        let process = this.findProcessById(processId);
        if (!process && this.processesCache.length === 0) {
            await this.loadProcesses();
            process = this.findProcessById(processId);
        }
        
        if (process) {
            this.selectProcess(process);
        } else {
            console.error(`Process ${processId} not found`);
            // Process not found, go back to process list
            this.navigateToProcesses();
            return;
        }
        
        window.history.pushState({}, '', `#terminal/${processId}`);
    }
    
    private async loadProcesses(): Promise<void> {
        try {
            const response = await fetch('/api/sessions');
            const sessions = await response.json();
            
            // Transform sessions to match ProcessMetadata interface
            const data: ProcessMetadata[] = sessions.map((session: any) => ({
                processId: session.id,
                command: session.metadata?.cmdline?.join(' ') || 'Unknown',
                workingDir: session.metadata?.cwd || 'Unknown',
                startDate: new Date().toISOString(), // tty-fwd doesn't provide start time
                lastModified: session.lastModified || new Date().toISOString(),
                exitCode: session.status === 'running' ? undefined : 1,
                error: session.status !== 'running' ? 'Not running' : undefined
            }));
            
            this.processesCache = data; // Cache the processes data
            this.renderProcessList(data);
        } catch (error) {
            console.error('Failed to load processes:', error);
            this.processListEl.innerHTML = '<p class="text-terminal-red">Failed to load processes</p>';
        }
    }
    
    private renderProcessList(processes: ProcessMetadata[]): void {
        this.processListEl.innerHTML = '';
        
        if (processes.length === 0) {
            this.processListEl.innerHTML = '<p class="text-gray-400 text-center py-4">No processes found</p>';
            return;
        }
        
        processes.forEach(process => {
            const processEl = document.createElement('div');
            processEl.className = 'p-3 rounded cursor-pointer hover:bg-gray-700 border border-gray-600';
            
            // Determine status color - if process has exitCode it's stopped
            const isRunning = process.exitCode === undefined && !process.error;
            const statusColor = isRunning ? 'text-terminal-green' : 'text-terminal-red';
            const status = isRunning ? 'running' : 'stopped';
            
            processEl.innerHTML = `
                <div class="flex justify-between items-start">
                    <div class="flex-1">
                        <div class="font-bold text-terminal-fg">${process.command}</div>
                        <div class="text-sm ${statusColor} mb-1">${status}</div>
                        <div class="text-xs text-gray-400">ID: ${process.processId}</div>
                        <div class="text-xs text-gray-400">Dir: ${process.workingDir}</div>
                        <div class="text-xs text-gray-400">Last Activity: ${new Date(process.lastModified).toLocaleString()}</div>
                    </div>
                    <button class="kill-btn bg-terminal-red text-white px-2 py-1 rounded text-xs hover:opacity-80 ml-2" 
                            data-process-id="${process.processId}">Kill</button>
                </div>
            `;
            
            processEl.addEventListener('click', (e) => {
                // Don't navigate if kill button was clicked
                if ((e.target as HTMLElement).classList.contains('kill-btn')) {
                    return;
                }
                this.navigateToTerminal(process.processId);
            });
            
            // Add kill button event listener
            const killBtn = processEl.querySelector('.kill-btn') as HTMLButtonElement;
            killBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                this.killSession(process.processId);
            });
            
            this.processListEl.appendChild(processEl);
        });
    }
    
    private findProcessById(processId: string): ProcessMetadata | null {
        return this.processesCache.find(process => process.processId === processId) || null;
    }
    
    private selectProcess(process: ProcessMetadata): void {
        this.disconnectWebSocket();
        this.currentProcess = process;
        this.currentProcessEl.textContent = `${process.command} (${process.processId})`;
        
        // Clear previous terminal content
        this.terminalPlayerEl.innerHTML = '<div class="text-center py-4 text-terminal-fg opacity-60">Connecting...</div>';
        
        // Create asciinema player with eventsource driver for real-time streaming
        this.createPlayerWithSSE(process.processId);
        
        // Add visual feedback for keyboard capture
        this.showKeyboardIndicator();
    }
    
    private createPlayerWithSSE(processId: string): void {
        const sseUrl = `/api/stream/${processId}`;
        
        console.log(`Creating asciinema player with SSE stream: ${sseUrl}`);
        
        // Clear the container
        this.terminalPlayerEl.innerHTML = '';
        
        try {
            // First try with eventsource driver
            console.log('Attempting to create player with eventsource driver...');
            this.player = AsciinemaPlayer.create({
                driver: 'eventsource',
                url: sseUrl
            }, this.terminalPlayerEl, {
                theme: 'asciinema',
                autoPlay: true,
                controls: false,
                fit: 'both',
                logger: console
            });
            
            // Debug: Check player dimensions after creation
            setTimeout(() => {
                const playerEl = this.terminalPlayerEl.querySelector('.ap-player');
                if (playerEl) {
                    console.log('Player dimensions:', {
                        width: playerEl.style.width,
                        height: playerEl.style.height,
                        computed: window.getComputedStyle(playerEl)
                    });
                }
            }, 1000);
            
            console.log('Asciinema player with SSE created successfully');
            
            // Add a timeout to check if player actually loads content
            setTimeout(() => {
                if (this.terminalPlayerEl.children.length === 0 || 
                    this.terminalPlayerEl.innerHTML.includes('Connecting...')) {
                    console.warn('Player seems not to be loading content, trying fallback...');
                    this.tryFallbackPlayer(processId);
                }
            }, 3000);
            
        } catch (error) {
            console.error('Error creating asciinema player with SSE:', error);
            this.tryFallbackPlayer(processId);
        }
    }
    
    private tryFallbackPlayer(processId: string): void {
        console.log('Trying fallback: direct file streaming...');
        
        // Fallback: try loading the cast file directly
        const castUrl = `/api/cast/${processId}`;
        
        try {
            this.terminalPlayerEl.innerHTML = '<div class="text-center py-4 text-terminal-fg opacity-60">Loading cast file...</div>';
            
            this.player = AsciinemaPlayer.create(castUrl, this.terminalPlayerEl, {
                theme: 'asciinema',
                autoPlay: true,
                controls: false,
                fit: 'both',
                logger: console
            });
            
            console.log('Fallback player created with cast file');
        } catch (error) {
            console.error('Fallback player also failed:', error);
            this.terminalPlayerEl.innerHTML = '<div class="text-center py-4 text-terminal-red">Error loading terminal display</div>';
        }
    }
    
    private showKeyboardIndicator(): void {
        // Remove existing indicator
        this.removeKeyboardIndicator();
        
        // Create new indicator
        const indicator = document.createElement('div');
        indicator.id = 'keyboard-capture-indicator';
        indicator.className = 'keyboard-capture-indicator';
        indicator.textContent = '⌨️ Keyboard Captured';
        document.body.appendChild(indicator);
        
        // Add focus styling to terminal container
        this.terminalPlayerEl.classList.add('terminal-focused');
    }
    
    private removeKeyboardIndicator(): void {
        const indicator = document.getElementById('keyboard-capture-indicator');
        if (indicator) {
            indicator.remove();
        }
        
        // Remove focus styling
        this.terminalPlayerEl.classList.remove('terminal-focused');
    }
    
    private disconnectWebSocket(): void {
        if (this.websocket) {
            this.websocket.close();
            this.websocket = null;
        }
        
        if (this.eventSource) {
            this.eventSource.close();
            this.eventSource = null;
        }
        
        if (this.player) {
            this.player = null;
        }
    }
    
    
    private async sendInput(): Promise<void> {
        const input = this.terminalInputEl.value.trim();
        if (!input || !this.currentProcess) {
            return;
        }
        
        try {
            const response = await fetch(`/api/input/${this.currentProcess.processId}`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    text: input
                })
            });
            
            if (response.ok) {
                this.terminalInputEl.value = '';
            } else {
                console.error('Failed to send input');
            }
        } catch (error) {
            console.error('Error sending input:', error);
        }
    }
    
    private parseCommand(command: string): string[] {
        // Simple command parser that respects quotes
        const args: string[] = [];
        let current = '';
        let inQuotes = false;
        let quoteChar = '';
        
        for (let i = 0; i < command.length; i++) {
            const char = command[i];
            
            if ((char === '"' || char === "'") && !inQuotes) {
                inQuotes = true;
                quoteChar = char;
            } else if (char === quoteChar && inQuotes) {
                inQuotes = false;
                quoteChar = '';
            } else if (char === ' ' && !inQuotes) {
                if (current.length > 0) {
                    args.push(current);
                    current = '';
                }
            } else {
                current += char;
            }
        }
        
        if (current.length > 0) {
            args.push(current);
        }
        
        return args;
    }
    
    private async killSession(processId: string): Promise<void> {
        if (!confirm('Are you sure you want to kill this session? This action cannot be undone.')) {
            return;
        }
        
        try {
            console.log(`Killing session: ${processId}`);
            
            const response = await fetch(`/api/sessions/${processId}`, {
                method: 'DELETE'
            });
            
            if (response.ok) {
                console.log('Session killed successfully');
                
                // If we're currently viewing this session, go back to process list
                if (this.currentProcess && this.currentProcess.processId === processId) {
                    this.navigateToProcesses();
                }
                
                // Refresh the process list immediately and again after cleanup
                await this.loadProcesses();
                
                // Refresh again after cleanup time to ensure session is removed
                setTimeout(async () => {
                    await this.loadProcesses();
                }, 2000);
            } else {
                const error = await response.json();
                alert(`Failed to kill session: ${error.error}`);
            }
        } catch (error) {
            console.error('Error killing session:', error);
            alert('Failed to kill session');
        }
    }
    
    private async handleCreateProcess(e: Event): Promise<void> {
        e.preventDefault();
        
        const workingDir = this.workingDirEl.value.trim();
        const command = this.commandEl.value.trim();
        
        if (!workingDir || !command) {
            alert('Please fill in both working directory and command');
            return;
        }
        
        try {
            const response = await fetch('/api/sessions', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    workingDir,
                    command: [command] // Send as single string since we use -- in tty-fwd
                })
            });
            
            console.log('Response status:', response.status);
            console.log('Response ok:', response.ok);
            
            if (response.ok) {
                const result = await response.json();
                console.log('Session created successfully:', result);
                // Clear form
                this.commandEl.value = '';
                // Refresh process list
                await this.loadProcesses();
            } else {
                const error = await response.json();
                console.error('Session creation failed:', error);
                alert(`Failed to create process: ${error.error}`);
            }
        } catch (error) {
            console.error('Error creating process:', error);
            alert('Failed to create process');
        }
    }
    
    private async openDirectoryBrowser(): Promise<void> {
        this.dirBrowserModalEl.classList.remove('hidden');
        await this.loadDirectoryContents(this.currentDirPath);
    }
    
    private closeDirectoryBrowser(): void {
        this.dirBrowserModalEl.classList.add('hidden');
    }
    
    private selectCurrentDirectory(): void {
        this.workingDirEl.value = this.currentDirPath;
        this.closeDirectoryBrowser();
    }
    
    private async loadDirectoryContents(dirPath: string): Promise<void> {
        try {
            const response = await fetch(`/api/ls?dir=${encodeURIComponent(dirPath)}`);
            const data: DirectoryListing = await response.json();
            
            this.currentDirPath = data.absolutePath;
            this.currentDirPathEl.textContent = this.currentDirPath;
            this.renderDirectoryContents(data.files);
        } catch (error) {
            console.error('Error loading directory:', error);
            this.dirBrowserContentEl.innerHTML = '<p class="text-terminal-red">Failed to load directory</p>';
        }
    }
    
    private renderDirectoryContents(files: FileInfo[]): void {
        this.dirBrowserContentEl.innerHTML = '';
        
        // Add parent directory option if not at root
        if (this.currentDirPath !== '/') {
            const parentEl = document.createElement('div');
            parentEl.className = 'p-2 cursor-pointer hover:bg-gray-700 rounded text-terminal-blue';
            parentEl.textContent = '.. (parent directory)';
            parentEl.addEventListener('click', () => {
                const parentPath = this.currentDirPath.split('/').slice(0, -1).join('/') || '/';
                this.loadDirectoryContents(parentPath);
            });
            this.dirBrowserContentEl.appendChild(parentEl);
        }
        
        // Add directories first
        files.filter(f => f.isDir).forEach(file => {
            const fileEl = document.createElement('div');
            fileEl.className = 'p-2 cursor-pointer hover:bg-gray-700 rounded flex items-center';
            fileEl.innerHTML = `<span class="text-terminal-blue mr-2">📁</span> ${file.name}`;
            fileEl.addEventListener('click', () => {
                const newPath = this.currentDirPath + '/' + file.name;
                this.loadDirectoryContents(newPath);
            });
            this.dirBrowserContentEl.appendChild(fileEl);
        });
        
        // Add files
        files.filter(f => !f.isDir).forEach(file => {
            const fileEl = document.createElement('div');
            fileEl.className = 'p-2 text-gray-400 flex items-center';
            fileEl.innerHTML = `<span class="mr-2">📄</span> ${file.name}`;
            this.dirBrowserContentEl.appendChild(fileEl);
        });
    }
    
    private startProcessRefresh(): void {
        // Refresh process list every 5 seconds when on process list page
        this.processRefreshInterval = window.setInterval(() => {
            if (this.currentRoute === 'processes') {
                this.loadProcesses();
            }
        }, 5000);
    }
    
    private setupHotReload(): void {
        // Only setup hot reload in development (not in production)
        if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
            const wsUrl = `${protocol}//${window.location.host}?hotReload=true`;
            
            this.hotReloadWs = new WebSocket(wsUrl);
            
            this.hotReloadWs.onopen = () => {
                console.log('Hot reload connected');
            };
            
            this.hotReloadWs.onmessage = (event: MessageEvent) => {
                try {
                    const message: WebSocketMessage = JSON.parse(event.data);
                    if (message.type === 'reload') {
                        console.log('Hot reload triggered - reloading page');
                        window.location.reload();
                    }
                } catch (error) {
                    console.error('Error parsing hot reload message:', error);
                }
            };
            
            this.hotReloadWs.onclose = () => {
                console.log('Hot reload disconnected');
                // Attempt to reconnect after a delay
                setTimeout(() => {
                    this.setupHotReload();
                }, 1000);
            };
            
            this.hotReloadWs.onerror = (error: Event) => {
                console.error('Hot reload WebSocket error:', error);
            };
        }
    }
}

// Initialize the application when the DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    new VibeTunnelApp();
});