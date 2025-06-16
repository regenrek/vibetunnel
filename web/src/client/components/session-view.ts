import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import type { Session } from './session-list.js';

@customElement('session-view')
export class SessionView extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @property({ type: Object }) session: Session | null = null;
  @state() private connected = false;
  @state() private player: any = null;
  @state() private sessionStatusInterval: number | null = null;

  private keyboardHandler = (e: KeyboardEvent) => {
    if (!this.session) return;
    
    e.preventDefault();
    e.stopPropagation();
    
    this.handleKeyboardInput(e);
  };

  connectedCallback() {
    super.connectedCallback();
    this.connected = true;
    
    // Add global keyboard event listener
    document.addEventListener('keydown', this.keyboardHandler);
    
    // Start polling session status
    this.startSessionStatusPolling();
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this.connected = false;
    
    // Remove global keyboard event listener
    document.removeEventListener('keydown', this.keyboardHandler);
    
    // Stop polling session status
    this.stopSessionStatusPolling();
    
    // Cleanup player if exists
    if (this.player) {
      this.player = null;
    }
  }

  updated(changedProperties: any) {
    super.updated(changedProperties);
    
    if (changedProperties.has('session') && this.session) {
      // Use setTimeout to ensure DOM is rendered first
      setTimeout(() => {
        this.createInteractiveTerminal();
      }, 10);
    }
  }

  private createInteractiveTerminal() {
    if (!this.session) return;
    
    const terminalElement = this.querySelector('#interactive-terminal') as HTMLElement;
    if (terminalElement && (window as any).AsciinemaPlayer) {
      try {
        // For ended sessions, use snapshot instead of stream to avoid reloading
        const url = this.session.status === 'exited' 
          ? `/api/sessions/${this.session.id}/snapshot`
          : `/api/sessions/${this.session.id}/stream`;
        
        const config = this.session.status === 'exited'
          ? { url } // Static snapshot
          : { driver: "eventsource", url }; // Live stream
        
        this.player = (window as any).AsciinemaPlayer.create(config, terminalElement, {
          autoPlay: true,
          loop: false,
          controls: false,
          fit: 'both',
          terminalFontSize: '12px',
          idleTimeLimit: 0.5,
          preload: true,
          poster: 'npt:999999'
        });

        // Disable focus outline and fullscreen functionality
        if (this.player && this.player.el) {
          // Remove focus outline
          this.player.el.style.outline = 'none';
          this.player.el.style.border = 'none';
          
          // Disable fullscreen hotkey by removing tabindex and preventing focus
          this.player.el.removeAttribute('tabindex');
          this.player.el.style.pointerEvents = 'none';
          
          // Find the terminal element and make it non-focusable
          const terminal = this.player.el.querySelector('.ap-terminal, .ap-screen, pre');
          if (terminal) {
            terminal.removeAttribute('tabindex');
            terminal.style.outline = 'none';
          }
        }
      } catch (error) {
        console.error('Error creating interactive terminal:', error);
      }
    }
  }

  private async handleKeyboardInput(e: KeyboardEvent) {
    if (!this.session) return;

    let inputText = '';
    
    // Handle special keys
    switch (e.key) {
      case 'Enter':
        inputText = 'enter';
        break;
      case 'Escape':
        inputText = 'escape';
        break;
      case 'ArrowUp':
        inputText = 'arrow_up';
        break;
      case 'ArrowDown':
        inputText = 'arrow_down';
        break;
      case 'ArrowLeft':
        inputText = 'arrow_left';
        break;
      case 'ArrowRight':
        inputText = 'arrow_right';
        break;
      case 'Tab':
        inputText = '\t';
        break;
      case 'Backspace':
        inputText = '\b';
        break;
      case 'Delete':
        inputText = '\x7f';
        break;
      case ' ':
        inputText = ' ';
        break;
      default:
        // Handle regular printable characters
        if (e.key.length === 1) {
          inputText = e.key;
        } else {
          // Ignore other special keys
          return;
        }
        break;
    }

    // Handle Ctrl combinations
    if (e.ctrlKey && e.key.length === 1) {
      const charCode = e.key.toLowerCase().charCodeAt(0);
      if (charCode >= 97 && charCode <= 122) { // a-z
        inputText = String.fromCharCode(charCode - 96); // Ctrl+A = \x01, etc.
      }
    }

    // Send the input to the session
    try {
      const response = await fetch(`/api/sessions/${this.session.id}/input`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ text: inputText })
      });

      if (!response.ok) {
        console.error('Failed to send input to session');
      }
    } catch (error) {
      console.error('Error sending input:', error);
    }
  }

  private handleBack() {
    this.dispatchEvent(new CustomEvent('back'));
  }

  private startSessionStatusPolling() {
    if (this.sessionStatusInterval) {
      clearInterval(this.sessionStatusInterval);
    }
    
    // Poll every 2 seconds
    this.sessionStatusInterval = window.setInterval(() => {
      this.checkSessionStatus();
    }, 2000);
  }

  private stopSessionStatusPolling() {
    if (this.sessionStatusInterval) {
      clearInterval(this.sessionStatusInterval);
      this.sessionStatusInterval = null;
    }
  }

  private async checkSessionStatus() {
    if (!this.session) return;

    try {
      const response = await fetch('/api/sessions');
      if (!response.ok) return;
      
      const sessions = await response.json();
      const currentSession = sessions.find((s: Session) => s.id === this.session!.id);
      
      if (currentSession && currentSession.status !== this.session.status) {
        // Session status changed
        this.session = { ...this.session, status: currentSession.status };
        this.requestUpdate();
        
        // If session ended, switch from stream to snapshot to prevent restarts
        if (currentSession.status === 'exited' && this.player && this.session.status === 'running') {
          console.log('Session ended, switching to snapshot view');
          try {
            // Dispose the streaming player
            if (this.player.dispose) {
              this.player.dispose();
            }
            this.player = null;
            
            // Recreate with snapshot
            setTimeout(() => {
              this.createInteractiveTerminal();
            }, 100);
          } catch (error) {
            console.error('Error switching to snapshot:', error);
          }
        }
      }
    } catch (error) {
      console.error('Error checking session status:', error);
    }
  }

  render() {
    if (!this.session) {
      return html`
        <div class="p-4 text-vs-muted">
          No session selected
        </div>
      `;
    }

    return html`
      <style>
        session-view *, session-view *:focus, session-view *:focus-visible {
          outline: none !important;
          box-shadow: none !important;
        }
      </style>
      <div class="h-screen flex flex-col bg-vs-bg font-mono" style="outline: none !important; box-shadow: none !important;">
        <!-- Compact Header -->
        <div class="flex items-center justify-between px-3 py-2 border-b border-vs-border bg-vs-bg-secondary text-sm">
          <div class="flex items-center gap-3">
            <button
              class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-2 py-1 border-none rounded transition-colors text-xs"
              @click=${this.handleBack}
            >
              ← BACK
            </button>
            <div class="text-vs-text">
              <span class="text-vs-accent">${this.session.command}</span>
              <span class="text-vs-muted text-xs ml-2">(${this.session.id.substring(0, 8)}...)</span>
            </div>
          </div>
          <div class="flex items-center gap-3 text-xs">
            <span class="text-vs-muted">
              ${this.session.workingDir}
            </span>
            <span class="${this.session.status === 'running' ? 'text-vs-user' : 'text-vs-warning'}">
              ${this.session.status.toUpperCase()}
            </span>
          </div>
        </div>

        <!-- Terminal Container -->
        <div class="flex-1 bg-black overflow-hidden">
          <div id="interactive-terminal" class="w-full h-full"></div>
        </div>
      </div>
    `;
  }
}