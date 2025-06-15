import { LitElement, html, css } from 'https://unpkg.com/lit@latest/index.js?module';

// Header component with ASCII art
class VibeHeader extends LitElement {
  static styles = css`
    :host {
      display: block;
      font-family: 'Courier New', monospace;
      color: var(--terminal-green);
      margin: 1em 0;
    }
    .ascii-art {
      font-size: 12px;
      line-height: 1em;
      white-space: pre;
      margin: 1em 0;
    }
    .title {
      font-size: 24px;
      margin: 1em 0;
    }
  `;

  render() {
    return html`
      <div class="ascii-art">
██╗   ██╗██╗██████╗ ███████╗    ████████╗██╗   ██╗███╗   ███╗███╗   ██╗███████╗██╗
██║   ██║██║██╔══██╗██╔════╝    ╚══██╔══╝██║   ██║████╗ ████║████╗  ██║██╔════╝██║
██║   ██║██║██████╔╝█████╗         ██║   ██║   ██║██╔████╔██║██╔██╗ ██║█████╗  ██║
╚██╗ ██╔╝██║██╔══██╗██╔══╝         ██║   ██║   ██║██║╚██╔╝██║██║╚██╗██║██╔══╝  ██║
 ╚████╔╝ ██║██████╔╝███████╗       ██║   ╚██████╔╝██║ ╚═╝ ██║██║ ╚████║███████╗███████╗
  ╚═══╝  ╚═╝╚═════╝ ╚══════╝       ╚═╝    ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝
      </div>
      <p>Terminal Multiplexer Web Interface</p>
    `;
  }
}

// Session card component
class SessionCard extends LitElement {
  static properties = {
    session: { type: Object }
  };

  static styles = css`
    :host {
      display: block;
      font-family: 'Courier New', monospace;
    }
    .card {
      border: 1px solid var(--terminal-gray);
      background: var(--terminal-bg);
      padding: 1em;
      cursor: pointer;
      height: 20em;
      display: flex;
      flex-direction: column;
    }
    .card:hover {
      border-color: var(--terminal-green);
    }
    .header {
      color: var(--terminal-cyan);
      margin-bottom: 1em;
    }
    .status {
      color: var(--terminal-yellow);
    }
    .status.running {
      color: var(--terminal-green);
    }
    .preview {
      flex: 1;
      border: 1px solid var(--terminal-gray);
      min-height: 12em;
      position: relative;
    }
    .preview-content {
      position: absolute;
      top: 0;
      left: 0;
      right: 0;
      bottom: 0;
    }
  `;

  firstUpdated() {
    this.renderPreview();
  }

  updated(changedProperties) {
    if (changedProperties.has('session')) {
      this.renderPreview();
    }
  }

  renderPreview() {
    const previewEl = this.shadowRoot.querySelector('.preview-content');
    if (!previewEl || !this.session?.lastOutput) return;

    try {
      const lines = this.session.lastOutput.trim().split('\n');
      if (lines.length > 1) {
        // Parse asciinema format
        const castData = [];
        for (let i = 1; i < lines.length; i++) {
          if (lines[i].trim()) {
            try {
              castData.push(JSON.parse(lines[i]));
            } catch (e) {
              // Skip invalid lines
            }
          }
        }

        if (castData.length > 0) {
          const cast = {
            version: 2,
            width: 80,
            height: 24,
            timestamp: Math.floor(Date.now() / 1000)
          };

          AsciinemaPlayer.create({
            data: castData,
            ...cast
          }, previewEl, {
            theme: 'asciinema',
            loop: false,
            autoPlay: false,
            controls: false,
            fit: 'width'
          });
        }
      }
    } catch (error) {
      previewEl.innerHTML = '<p style="color: var(--terminal-gray); padding: 1em;">No preview available</p>';
    }
  }

  handleClick() {
    this.dispatchEvent(new CustomEvent('session-select', {
      detail: { sessionId: this.session.id },
      bubbles: true
    }));
  }

  render() {
    if (!this.session) return html``;

    const command = this.session.metadata?.cmdline?.join(' ') || 'Unknown';
    const status = this.session.status || 'unknown';

    return html`
      <div class="card" @click="${this.handleClick}">
        <div class="header">
          ${command}
        </div>
        <div class="status ${status}">
          Status: ${status}
        </div>
        <div>ID: ${this.session.id.substring(0, 8)}...</div>
        <div class="preview">
          <div class="preview-content"></div>
        </div>
      </div>
    `;
  }
}

// Session overview component
class SessionOverview extends LitElement {
  static properties = {
    sessions: { type: Array }
  };

  static styles = css`
    :host {
      display: block;
      font-family: 'Courier New', monospace;
    }
    .controls {
      margin: 1em 0;
      display: flex;
      gap: 1em;
      align-items: center;
    }
    .form {
      border: 1px solid var(--terminal-gray);
      padding: 1em;
      margin: 1em 0;
    }
    .form-row {
      display: flex;
      gap: 1em;
      margin: 1em 0;
      align-items: center;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(40ch, 1fr));
      gap: 1em;
      margin: 1em 0;
    }
    input {
      font-family: 'Courier New', monospace;
      background: var(--terminal-bg);
      color: var(--terminal-fg);
      border: 1px solid var(--terminal-gray);
      padding: 0 1ch;
      height: 2em;
    }
    button {
      font-family: 'Courier New', monospace;
      background: var(--terminal-gray);
      color: var(--terminal-bg);
      border: 1px solid var(--terminal-gray);
      padding: 0 1ch;
      height: 2em;
      cursor: pointer;
      min-width: 8ch;
    }
    button:hover {
      background: var(--terminal-fg);
    }
    button.primary {
      background: var(--terminal-green);
      border-color: var(--terminal-green);
    }
  `;

  constructor() {
    super();
    this.sessions = [];
    this.loadSessions();
    this.refreshInterval = setInterval(() => this.loadSessions(), 5000);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this.refreshInterval) {
      clearInterval(this.refreshInterval);
    }
  }

  async loadSessions() {
    try {
      const response = await fetch('/api/sessions');
      const data = await response.json();
      this.sessions = data;
    } catch (error) {
      console.error('Failed to load sessions:', error);
    }
  }

  async createSession(event) {
    event.preventDefault();
    const formData = new FormData(event.target);
    const command = formData.get('command').trim().split(' ');
    const workingDir = formData.get('workingDir').trim();

    if (!command[0]) {
      alert('Command is required');
      return;
    }

    try {
      const response = await fetch('/api/sessions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          command,
          workingDir: workingDir || undefined
        })
      });

      if (response.ok) {
        event.target.reset();
        this.shadowRoot.querySelector('input[name="workingDir"]').value = '~/';
        setTimeout(() => this.loadSessions(), 1000);
      } else {
        const error = await response.json();
        alert(`Failed to create session: ${error.error}`);
      }
    } catch (error) {
      console.error('Error creating session:', error);
      alert('Failed to create session');
    }
  }

  render() {
    return html`
      <h2>Session Overview</h2>
      
      <div class="form">
        <h3>Create New Session</h3>
        <form @submit="${this.createSession}">
          <div class="form-row">
            <label>Working Directory:</label>
            <input name="workingDir" type="text" value="~/" placeholder="~/projects/my-app" style="flex: 1;">
          </div>
          <div class="form-row">
            <label>Command:</label>
            <input name="command" type="text" placeholder="bash" required style="flex: 1;">
            <button type="submit" class="primary">Create</button>
          </div>
        </form>
      </div>

      <div class="controls">
        <h3>Active Sessions (${this.sessions.length})</h3>
        <button @click="${this.loadSessions}">Refresh</button>
      </div>

      <div class="grid">
        ${this.sessions.map(session => html`
          <session-card .session="${session}"></session-card>
        `)}
      </div>

      ${this.sessions.length === 0 ? html`
        <p style="color: var(--terminal-gray); text-align: center; margin: 2em;">
          No active sessions. Create one above to get started.
        </p>
      ` : ''}
    `;
  }
}

// Session detail component
class SessionDetail extends LitElement {
  static properties = {
    sessionId: { type: String },
    session: { type: Object }
  };

  static styles = css`
    :host {
      display: block;
      font-family: 'Courier New', monospace;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin: 1em 0;
    }
    .terminal {
      border: 1px solid var(--terminal-gray);
      min-height: 30em;
      position: relative;
    }
    .input-area {
      display: flex;
      gap: 1em;
      margin: 1em 0;
      align-items: center;
    }
    input {
      font-family: 'Courier New', monospace;
      background: var(--terminal-bg);
      color: var(--terminal-fg);
      border: 1px solid var(--terminal-gray);
      padding: 0 1ch;
      height: 2em;
      flex: 1;
    }
    button {
      font-family: 'Courier New', monospace;
      background: var(--terminal-gray);
      color: var(--terminal-bg);
      border: 1px solid var(--terminal-gray);
      padding: 0 1ch;
      height: 2em;
      cursor: pointer;
      min-width: 8ch;
    }
    button:hover {
      background: var(--terminal-fg);
    }
    button.primary {
      background: var(--terminal-green);
      border-color: var(--terminal-green);
    }
  `;

  constructor() {
    super();
    this.sessionId = null;
    this.session = null;
    this.websocket = null;
    this.player = null;
    this.castData = [];
  }

  updated(changedProperties) {
    if (changedProperties.has('sessionId') && this.sessionId) {
      this.loadSession();
      this.connectWebSocket();
    }
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this.disconnectWebSocket();
  }

  async loadSession() {
    try {
      const response = await fetch('/api/sessions');
      const sessions = await response.json();
      this.session = sessions.find(s => s.id === this.sessionId);
    } catch (error) {
      console.error('Failed to load session:', error);
    }
  }

  connectWebSocket() {
    this.disconnectWebSocket();
    
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${window.location.host}?session=${this.sessionId}`;
    
    this.websocket = new WebSocket(wsUrl);
    
    this.websocket.onopen = () => {
      console.log(`Connected to session ${this.sessionId}`);
    };
    
    this.websocket.onmessage = (event) => {
      try {
        const castEvent = JSON.parse(event.data);
        this.castData.push(castEvent);
        this.updatePlayer();
      } catch (error) {
        console.error('Error parsing WebSocket message:', error);
      }
    };
    
    this.websocket.onclose = () => {
      console.log(`Disconnected from session ${this.sessionId}`);
    };
    
    this.websocket.onerror = (error) => {
      console.error('WebSocket error:', error);
    };
  }

  disconnectWebSocket() {
    if (this.websocket) {
      this.websocket.close();
      this.websocket = null;
    }
  }

  updatePlayer() {
    const terminalEl = this.shadowRoot.querySelector('.terminal');
    if (!terminalEl || this.castData.length === 0) return;

    terminalEl.innerHTML = '';

    try {
      const cast = {
        version: 2,
        width: 80,
        height: 24,
        timestamp: Math.floor(Date.now() / 1000)
      };

      this.player = AsciinemaPlayer.create({
        data: this.castData,
        ...cast
      }, terminalEl, {
        theme: 'asciinema',
        loop: false,
        autoPlay: true,
        controls: false,
        fit: 'width'
      });
    } catch (error) {
      console.error('Error creating player:', error);
      terminalEl.innerHTML = '<p style="color: var(--terminal-red); padding: 1em;">Error loading terminal</p>';
    }
  }

  sendInput(event) {
    event.preventDefault();
    const input = this.shadowRoot.querySelector('input[name="input"]');
    const value = input.value.trim();
    
    if (!value || !this.websocket || this.websocket.readyState !== WebSocket.OPEN) {
      return;
    }

    this.websocket.send(JSON.stringify({
      type: 'input',
      data: value
    }));

    input.value = '';
  }

  goBack() {
    this.dispatchEvent(new CustomEvent('go-back', { bubbles: true }));
  }

  render() {
    if (!this.session) {
      return html`<p>Loading session...</p>`;
    }

    const command = this.session.metadata?.cmdline?.join(' ') || 'Unknown';

    return html`
      <div class="header">
        <button @click="${this.goBack}">← Back to Sessions</button>
        <h2>${command}</h2>
        <span style="color: var(--terminal-gray);">ID: ${this.sessionId.substring(0, 8)}...</span>
      </div>

      <div class="terminal"></div>

      <form @submit="${this.sendInput}" class="input-area">
        <span style="color: var(--terminal-green);">$</span>
        <input name="input" type="text" placeholder="Enter command..." autofocus>
        <button type="submit" class="primary">Send</button>
      </form>
    `;
  }
}

// Register components
customElements.define('vibe-header', VibeHeader);
customElements.define('session-card', SessionCard);
customElements.define('session-overview', SessionOverview);
customElements.define('session-detail', SessionDetail);