import { LitElement, html, TemplateResult } from 'lit';
import { customElement, state } from 'lit/decorators.js';
import { choose } from 'lit/directives/choose.js';

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

@customElement('vibetunnel-app')
export class VibeTunnelApp extends LitElement {
    // Override createRenderRoot to disable shadow DOM and enable Tailwind
    createRenderRoot() {
        return this;
    }

    @state() private currentRoute: Route = 'processes';
    @state() private currentProcess: ProcessMetadata | null = null;
    @state() private processes: ProcessMetadata[] = [];
    @state() private workingDir: string = '~/';
    @state() private command: string = '';
    @state() private showDirBrowser: boolean = false;
    @state() private currentDirPath: string = '~/';
    @state() private dirFiles: FileInfo[] = [];
    @state() private keyboardCaptured: boolean = false;

    private player: any = null;
    private eventSource: EventSource | null = null;
    private hotReloadWs: WebSocket | null = null;
    private processRefreshInterval: number | null = null;

    connectedCallback(): void {
        super.connectedCallback();
        this.setupHotReload();
        this.handleRouting();
        this.startProcessRefresh();
        this.setupGlobalKeyCapture();
        window.addEventListener('popstate', () => this.handleRouting());
    }

    disconnectedCallback(): void {
        super.disconnectedCallback();
        this.disconnectStreaming();
        if (this.processRefreshInterval) {
            clearInterval(this.processRefreshInterval);
        }
        if (this.hotReloadWs) {
            this.hotReloadWs.close();
        }
        window.removeEventListener('popstate', () => this.handleRouting());
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
        this.currentProcess = null; // Clear current process when leaving terminal
        this.disconnectStreaming();
        this.keyboardCaptured = false;
        this.loadProcesses();
        window.history.pushState({}, '', '#');
    }

    private async navigateToTerminal(processId: string): Promise<void> {
        this.currentRoute = 'terminal';
        
        if (this.processes.length === 0) {
            await this.loadProcesses();
        }
        
        const process = this.processes.find(p => p.processId === processId);
        if (process) {
            this.selectProcess(process);
        } else {
            console.error(`Process ${processId} not found`);
            this.navigateToProcesses();
            return;
        }
        
        window.history.pushState({}, '', `#terminal/${processId}`);
    }

    private async loadProcesses(): Promise<void> {
        try {
            const response = await fetch('/api/sessions');
            const sessions = await response.json();
            
            this.processes = sessions.map((session: any) => ({
                processId: session.id,
                command: session.metadata?.cmdline?.join(' ') || 'Unknown',
                workingDir: session.metadata?.cwd || 'Unknown',
                startDate: new Date().toISOString(),
                lastModified: session.lastModified || new Date().toISOString(),
                exitCode: session.status === 'running' ? undefined : 1,
                error: session.status !== 'running' ? 'Not running' : undefined
            }));
        } catch (error) {
            console.error('Failed to load processes:', error);
        }
    }

    private selectProcess(process: ProcessMetadata): void {
        this.disconnectStreaming();
        this.currentProcess = process;
        this.keyboardCaptured = true;
        
        // Create asciinema player with SSE
        this.requestUpdate();
        this.updateComplete.then(() => {
            this.createPlayerWithSSE(process.processId);
        });
    }

    private createPlayerWithSSE(processId: string): void {
        const playerEl = this.querySelector('.terminal-player') as HTMLElement;
        if (!playerEl) return;

        const sseUrl = `/api/stream/${processId}`;
        
        try {
            playerEl.innerHTML = '';
            this.player = AsciinemaPlayer.create({
                driver: 'eventsource',
                url: sseUrl
            }, playerEl, {
                theme: 'asciinema',
                autoPlay: true,
                controls: false,
                fit: 'both'
            });
        } catch (error) {
            console.error('Error creating asciinema player:', error);
            playerEl.innerHTML = '<div style="text-align: center; padding: 2em; color: #ff5555;">Error loading terminal</div>';
        }
    }

    private disconnectStreaming(): void {
        if (this.eventSource) {
            this.eventSource.close();
            this.eventSource = null;
        }
        if (this.player) {
            this.player = null;
        }
    }


    private setupGlobalKeyCapture(): void {
        document.addEventListener('keydown', (e: KeyboardEvent) => {
            if (this.currentRoute !== 'terminal' || !this.currentProcess || !this.keyboardCaptured) {
                return;
            }

            const target = e.target as HTMLElement;
            if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') {
                return;
            }

            const terminalKey = this.convertKeyToTerminalInput(e);
            if (terminalKey) {
                this.sendKeyToTerminal(terminalKey);
                e.preventDefault();
                e.stopPropagation();
            }
        });
    }

    private convertKeyToTerminalInput(e: KeyboardEvent): { type: 'key' | 'text', value: string } | null {
        const ttyFwdKeys: { [key: string]: string } = {
            'ArrowUp': 'arrow_up', 'ArrowDown': 'arrow_down', 
            'ArrowLeft': 'arrow_left', 'ArrowRight': 'arrow_right',
            'Escape': 'escape', 'Enter': 'enter'
        };

        const specialKeys: { [key: string]: string } = {
            'Backspace': '\x7f', 'Tab': '\t',
            'Home': '\x1b[H', 'End': '\x1b[F',
            'PageUp': '\x1b[5~', 'PageDown': '\x1b[6~',
            'Insert': '\x1b[2~', 'Delete': '\x1b[3~'
        };

        if (ttyFwdKeys[e.key]) {
            return { type: 'key', value: ttyFwdKeys[e.key] };
        }

        if (e.ctrlKey && e.key.length === 1) {
            const code = e.key.toLowerCase().charCodeAt(0);
            if (code >= 97 && code <= 122) {
                return { type: 'text', value: String.fromCharCode(code - 96) };
            }
        }

        if (e.altKey && e.key.length === 1) {
            return { type: 'text', value: '\x1b' + e.key };
        }

        if (specialKeys[e.key]) {
            return { type: 'text', value: specialKeys[e.key] };
        }

        if (e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
            return { type: 'text', value: e.key };
        }

        return null;
    }

    private async sendKeyToTerminal(keyData: { type: 'key' | 'text', value: string }): Promise<void> {
        // Only send input if we're actually in terminal mode with a valid process
        if (this.currentRoute !== 'terminal' || !this.currentProcess || !this.keyboardCaptured) {
            return;
        }

        try {
            // Send as text to match old working version
            const response = await fetch(`/api/input/${this.currentProcess.processId}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ text: keyData.value })
            });
            
            if (!response.ok) {
                console.error('Failed to send key to terminal:', response.status, response.statusText);
            }
        } catch (error) {
            console.error('Error sending key to terminal:', error);
        }
    }

    private async createProcess(): Promise<void> {
        if (!this.workingDir.trim() || !this.command.trim()) {
            alert('Please fill in both working directory and command');
            return;
        }

        try {
            const response = await fetch('/api/sessions', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    workingDir: this.workingDir,
                    command: [this.command]
                })
            });

            if (response.ok) {
                this.command = '';
                await this.loadProcesses();
            } else {
                const error = await response.json();
                alert(`Failed to create process: ${error.error}`);
            }
        } catch (error) {
            console.error('Error creating process:', error);
            alert('Failed to create process');
        }
    }

    private async killSession(processId: string): Promise<void> {
        if (!confirm('Are you sure you want to kill this session?')) return;

        try {
            const response = await fetch(`/api/sessions/${processId}`, { method: 'DELETE' });
            
            if (response.ok) {
                if (this.currentProcess && this.currentProcess.processId === processId) {
                    this.navigateToProcesses();
                }
                
                // Wait a moment for server cleanup to complete, then refresh
                setTimeout(async () => {
                    await this.loadProcesses();
                }, 1500);
                
                // Also refresh immediately
                await this.loadProcesses();
            } else {
                const error = await response.json();
                alert(`Failed to kill session: ${error.error}`);
            }
        } catch (error) {
            console.error('Error killing session:', error);
            alert('Failed to kill session');
        }
    }

    private async openDirectoryBrowser(): Promise<void> {
        this.showDirBrowser = true;
        await this.loadDirectoryContents(this.currentDirPath);
    }

    private async loadDirectoryContents(dirPath: string): Promise<void> {
        try {
            const response = await fetch(`/api/ls?dir=${encodeURIComponent(dirPath)}`);
            const data: DirectoryListing = await response.json();
            
            this.currentDirPath = data.absolutePath;
            this.dirFiles = data.files;
        } catch (error) {
            console.error('Error loading directory:', error);
        }
    }

    private selectDirectory(): void {
        this.workingDir = this.currentDirPath;
        this.showDirBrowser = false;
    }

    private startProcessRefresh(): void {
        this.processRefreshInterval = window.setInterval(() => {
            if (this.currentRoute === 'processes') {
                this.loadProcesses();
            }
        }, 2000); // Refresh every 2 seconds instead of 5
    }

    private setupHotReload(): void {
        if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
            const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
            const wsUrl = `${protocol}//${window.location.host}?hotReload=true`;
            
            this.hotReloadWs = new WebSocket(wsUrl);
            this.hotReloadWs.onmessage = (event) => {
                const message = JSON.parse(event.data);
                if (message.type === 'reload') {
                    window.location.reload();
                }
            };
        }
    }

    render(): TemplateResult {
        return html`
            <div style="position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: #1e1e1e; color: #cccccc; overflow: hidden;">
                ${choose(this.currentRoute, [
                    ['processes', () => this.renderProcessList()],
                    ['terminal', () => this.renderTerminal()]
                ])}

                ${this.showDirBrowser ? this.renderDirectoryBrowser() : ''}
            </div>
        `;
    }

    private renderProcessList(): TemplateResult {
        return html`
            <div style="padding: 1em; max-width: 100%; overflow-x: auto;">
                <!-- Header -->
                <div style="margin-bottom: 1.5em; text-align: center;">
                    <div style="color: #569cd6; font-size: 1.2em; font-weight: bold;">VibeTunnel</div>
                    <div style="color: #6a9955; font-size: 0.9em;">Terminal Multiplexer</div>
                </div>

                <!-- Create Process Form -->
                <div style="border: 1px solid #3c3c3c; padding: 1em; margin-bottom: 1em; background: #252526;">
                    <div style="color: #4ec9b0; margin-bottom: 1em;">Create New Process</div>
                    <div style="margin-bottom: 1em;">
                        <div style="margin-bottom: 1em;">Working Directory:</div>
                        <div style="display: flex; flex-wrap: wrap; gap: 1em; align-items: stretch;">
                            <input style="flex: 1; background: #3c3c3c; color: #cccccc; border: 1px solid #464647; padding: 0.5em; height: 2em; outline: none; font-size: 1em;" 
                                   .value=${this.workingDir} 
                                   @input=${(e: Event) => this.workingDir = (e.target as HTMLInputElement).value}
                                   placeholder="~/projects/my-app">
                            <button style="min-width: 5em; height: 3em; border: 1px solid #6272a4; background: #44475a; color: #cccccc; cursor: pointer; padding: 0.5em; font-size: 1em;" 
                                    @click=${this.openDirectoryBrowser}>Browse</button>
                        </div>
                    </div>
                    <div style="margin-bottom: 1em;">
                        <div style="margin-bottom: 1em;">Command:</div>
                        <input style="width: 100%; max-width: 40em; background: #3c3c3c; color: #cccccc; border: 1px solid #464647; padding: 0.5em; height: 2em; outline: none; font-size: 1em;" 
                               .value=${this.command}
                               @input=${(e: Event) => this.command = (e.target as HTMLInputElement).value}
                               placeholder="bash">
                    </div>
                    <button style="min-width: 6em; height: 3em; background: #0e639c; color: #ffffff; border: 1px solid #6272a4; cursor: pointer; padding: 0.5em; font-size: 1em; font-weight: bold;" 
                            @click=${this.createProcess}>Create</button>
                </div>

                <!-- Process List -->
                <div style="border: 1px solid #6272a4; padding: 1em;">
                    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1em;">
                        <span style="color: #8be9fd;">Active Processes</span>
                        <button style="min-width: 6em; height: 3em; border: 1px solid #6272a4; background: #44475a; color: #cccccc; cursor: pointer; padding: 0.5em; font-size: 1em;" 
                                @click=${this.loadProcesses}>Refresh</button>
                    </div>
                    
                    ${this.processes.length === 0 ? 
                        html`<div style="color: #6a9955;">No processes found</div>` :
                        this.processes.map(process => html`
                            <div style="border: 1px solid #3c3c3c; padding: 1.5em; margin-bottom: 1em; cursor: pointer; min-height: 4em; background: #252526; transition: background-color 0.2s;" 
                                 @click=${() => this.navigateToTerminal(process.processId)}
                                 @mouseover=${(e: Event) => (e.currentTarget as HTMLElement).style.background = '#2d2d30'}
                                 @mouseout=${(e: Event) => (e.currentTarget as HTMLElement).style.background = '#252526'}>
                                <div style="display: flex; justify-content: space-between; align-items: center; width: 100%;">
                                    <div style="flex: 1;">
                                        <div style="color: #cccccc;">${process.command}</div>
                                        <div style="color: ${process.exitCode === undefined ? '#4ec9b0' : '#f14c4c'};">
                                            ${process.exitCode === undefined ? 'running' : 'stopped'}
                                        </div>
                                        <div style="color: #6272a4;">ID: ${process.processId}</div>
                                        <div style="color: #6272a4;">Dir: ${process.workingDir}</div>
                                    </div>
                                    <button style="min-width: 4em; height: 3em; background: #f14c4c; color: #ffffff; border: 1px solid #6272a4; cursor: pointer; padding: 0.5em; font-size: 1em; font-weight: bold;" 
                                            @click=${(e: Event) => { e.stopPropagation(); this.killSession(process.processId); }}>
                                        Kill
                                    </button>
                                </div>
                            </div>
                        `)
                    }
                </div>
            </div>
        `;
    }

    private renderTerminal(): TemplateResult {
        return html`
            <div style="position: fixed; top: 0; left: 0; right: 0; bottom: 0; display: flex; flex-direction: column;">
                <!-- Header -->
                <div style="padding: 1em; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #3c3c3c; background: #2d2d30;">
                    <button style="min-width: 5em; height: 3em; border: 1px solid #6272a4; background: #44475a; color: #cccccc; cursor: pointer; padding: 0.5em; font-size: 1em;" 
                            @click=${this.navigateToProcesses}>← Back</button>
                    <span style="color: #dcdcaa;">${this.currentProcess?.command} (${this.currentProcess?.processId})</span>
                    <button style="min-width: 4em; height: 3em; background: #f14c4c; color: #ffffff; border: 1px solid #6272a4; cursor: pointer; padding: 0.5em; font-size: 1em; font-weight: bold;" 
                            @click=${() => this.currentProcess && this.killSession(this.currentProcess.processId)}>
                        Kill
                    </button>
                </div>

                <!-- Terminal Player -->
                <div class="terminal-player" style="flex: 1; background: #1e1e1e; overflow: hidden;"></div>
            </div>
        `;
    }

    private renderDirectoryBrowser(): TemplateResult {
        return html`
            <div style="position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0, 0, 0, 0.8); display: flex; align-items: center; justify-content: center; z-index: 1000;" 
                 @click=${(e: Event) => e.target === e.currentTarget && (this.showDirBrowser = false)}>
                <div style="background: #252526; border: 1px solid #3c3c3c; width: 90vw; max-width: 60em; height: 80vh; max-height: 30em; margin: 1em; display: flex; flex-direction: column;">
                    <div style="padding: 1em; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #3c3c3c;">
                        <span style="color: #4ec9b0;">Browse Directory</span>
                        <button style="min-width: 3em; height: 3em; border: 1px solid #6272a4; background: #44475a; color: #cccccc; cursor: pointer; padding: 0.5em; font-size: 1em;" 
                                @click=${() => this.showDirBrowser = false}>✕</button>
                    </div>
                    
                    <div style="padding: 1em; border-bottom: 1px solid #3c3c3c;">
                        <span style="color: #6a9955;">Current: </span>
                        <span style="color: #4ec9b0;">${this.currentDirPath}</span>
                    </div>
                    
                    <div style="flex: 1; overflow: auto; padding: 1em; min-height: 0;">
                        ${this.currentDirPath !== '/' ? html`
                            <div style="cursor: pointer; color: #569cd6; padding: 0; margin-bottom: 1em;" 
                                 @click=${() => this.loadDirectoryContents(this.currentDirPath.split('/').slice(0, -1).join('/') || '/')}
                                 @mouseover=${(e: Event) => (e.target as HTMLElement).style.background = '#2d2d30'}
                                 @mouseout=${(e: Event) => (e.target as HTMLElement).style.background = '#252526'}>
                                .. (parent directory)
                            </div>
                        ` : ''}
                        
                        ${this.dirFiles.filter(f => f.isDir).map(file => html`
                            <div style="cursor: pointer; padding: 0; margin-bottom: 1em; display: flex;" 
                                 @click=${() => this.loadDirectoryContents(this.currentDirPath + '/' + file.name)}
                                 @mouseover=${(e: Event) => (e.target as HTMLElement).style.background = '#2d2d30'}
                                 @mouseout=${(e: Event) => (e.target as HTMLElement).style.background = '#252526'}>
                                <span style="color: #569cd6; width: 2em;">📁</span>
                                <span>${file.name}</span>
                            </div>
                        `)}
                        
                        ${this.dirFiles.filter(f => !f.isDir).map(file => html`
                            <div style="padding: 0; margin-bottom: 1em; color: #6a9955; display: flex;">
                                <span style="width: 2em;">📄</span>
                                <span>${file.name}</span>
                            </div>
                        `)}
                    </div>
                    
                    <div style="padding: 1em; display: flex; gap: 1em; border-top: 1px solid #3c3c3c;">
                        <button style="min-width: 6em; height: 3em; border: 1px solid #6272a4; background: #44475a; color: #cccccc; cursor: pointer; padding: 0.5em; font-size: 1em;" 
                                @click=${() => this.showDirBrowser = false}>Cancel</button>
                        <button style="min-width: 6em; height: 3em; background: #0e639c; color: #ffffff; border: 1px solid #6272a4; cursor: pointer; padding: 0.5em; font-size: 1em; font-weight: bold;" 
                                @click=${this.selectDirectory}>Select</button>
                    </div>
                </div>
            </div>
        `;
    }
}