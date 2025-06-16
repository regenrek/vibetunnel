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
    
    // Focus the component to ensure it receives keyboard events
    setTimeout(() => {
      this.focus();
    }, 100);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this.connected = false;
    
    // Remove global keyboard event listener
    document.removeEventListener('keydown', this.keyboardHandler);
    
    // Cleanup player if exists
    if (this.player) {
      this.player = null;
    }
  }

  updated(changedProperties: any) {
    super.updated(changedProperties);
    
    if (changedProperties.has('session') && this.session) {
      this.createInteractiveTerminal();
    }
  }

  private createInteractiveTerminal() {
    if (!this.session) return;
    
    const terminalElement = this.querySelector('#interactive-terminal') as HTMLElement;
    if (terminalElement && (window as any).AsciinemaPlayer) {
      try {
        const streamUrl = `/api/sessions/${this.session.id}/stream`;
        
        this.player = (window as any).AsciinemaPlayer.create({
          driver: "eventsource", 
          url: streamUrl
        }, terminalElement, {
          autoPlay: true,
          loop: false,
          controls: false,
          fit: 'width',
          terminalFontSize: '12px',
          idleTimeLimit: 0.5,
          preload: true,
          poster: 'npt:999999'
        });
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

  render() {
    if (!this.session) {
      return html`
        <div class="p-4 text-vs-muted">
          No session selected
        </div>
      `;
    }

    return html`
      <div class="h-screen flex flex-col bg-vs-bg font-mono" tabindex="0">
        <!-- Header -->
        <div class="flex items-center justify-between p-4 border-b border-vs-border bg-vs-bg-secondary">
          <div class="flex items-center gap-4">
            <button
              class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-3 py-2 border-none rounded transition-colors"
              @click=${this.handleBack}
            >
              ← BACK
            </button>
            <div class="text-vs-text">
              <span class="text-vs-accent">${this.session.command}</span>
              <span class="text-vs-muted ml-2">(${this.session.id.substring(0, 8)}...)</span>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-xs ${this.session.status === 'running' ? 'text-vs-user' : 'text-vs-warning'}">
              ${this.session.status.toUpperCase()}
            </span>
          </div>
        </div>

        <!-- Terminal Container -->
        <div class="flex-1 bg-black overflow-hidden">
          <div id="interactive-terminal" class="w-full h-full"></div>
        </div>

        <!-- Footer -->
        <div class="p-2 border-t border-vs-border bg-vs-bg-secondary text-xs text-vs-muted">
          <div class="flex justify-between">
            <span>Working Directory: ${this.session.workingDir}</span>
            <span>Interactive Mode - All keyboard input will be sent to the terminal</span>
          </div>
        </div>
      </div>
    `;
  }
}