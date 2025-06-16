import { LitElement, PropertyValues, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import type { Session } from './session-list.js';
import { Renderer } from '../renderer.js';

@customElement('session-view')
export class SessionView extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @property({ type: Object }) session: Session | null = null;
  @state() private connected = false;
  @state() private renderer: Renderer | null = null;
  @state() private showMobileInput = false;
  @state() private mobileInputText = '';
  @state() private isMobile = false;
  @state() private touchStartX = 0;
  @state() private touchStartY = 0;
  @state() private loading = false;
  @state() private loadingFrame = 0;

  private loadingInterval: number | null = null;
  private keyboardListenerAdded = false;
  private touchListenersAdded = false;

  private keyboardHandler = (e: KeyboardEvent) => {
    if (!this.session) return;

    e.preventDefault();
    e.stopPropagation();

    this.handleKeyboardInput(e);
  };

  private touchStartHandler = (e: TouchEvent) => {
    if (!this.isMobile) return;

    const touch = e.touches[0];
    this.touchStartX = touch.clientX;
    this.touchStartY = touch.clientY;
  };

  private touchEndHandler = (e: TouchEvent) => {
    if (!this.isMobile) return;

    const touch = e.changedTouches[0];
    const touchEndX = touch.clientX;
    const touchEndY = touch.clientY;

    const deltaX = touchEndX - this.touchStartX;
    const deltaY = touchEndY - this.touchStartY;

    // Check for horizontal swipe from left edge (back gesture)
    const isSwipeRight = deltaX > 100;
    const isVerticallyStable = Math.abs(deltaY) < 100;
    const startedFromLeftEdge = this.touchStartX < 50;

    if (isSwipeRight && isVerticallyStable && startedFromLeftEdge) {
      // Trigger back navigation
      this.handleBack();
    }
  };

  connectedCallback() {
    super.connectedCallback();
    this.connected = true;

    // Show loading animation if no session yet
    if (!this.session) {
      this.startLoading();
    }

    // Detect mobile device
    this.isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent) ||
                   window.innerWidth <= 768;

    // Only add listeners if not already added
    if (!this.isMobile && !this.keyboardListenerAdded) {
      document.addEventListener('keydown', this.keyboardHandler);
      this.keyboardListenerAdded = true;
    } else if (this.isMobile && !this.touchListenersAdded) {
      // Add touch event listeners for mobile swipe gestures
      document.addEventListener('touchstart', this.touchStartHandler, { passive: true });
      document.addEventListener('touchend', this.touchEndHandler, { passive: true });
      this.touchListenersAdded = true;
    }

  }

  disconnectedCallback() {
    super.disconnectedCallback();
    this.connected = false;

    // Remove global keyboard event listener
    if (!this.isMobile && this.keyboardListenerAdded) {
      document.removeEventListener('keydown', this.keyboardHandler);
      this.keyboardListenerAdded = false;
    } else if (this.isMobile && this.touchListenersAdded) {
      // Remove touch event listeners
      document.removeEventListener('touchstart', this.touchStartHandler);
      document.removeEventListener('touchend', this.touchEndHandler);
      this.touchListenersAdded = false;
    }


    // Stop loading animation
    this.stopLoading();

    // Cleanup renderer if it exists
    if (this.renderer) {
      this.renderer.dispose();
      this.renderer = null;
    }
  }

  firstUpdated(changedProperties: PropertyValues) {
    super.firstUpdated(changedProperties);
    if (this.session) {
      this.stopLoading();
      this.createInteractiveTerminal();
    }
  }

  updated(changedProperties: any) {
    super.updated(changedProperties);

    // Stop loading and create terminal when session becomes available
    if (changedProperties.has('session') && this.session && this.loading) {
      this.stopLoading();
      this.createInteractiveTerminal();
    }

    // Adjust terminal height for mobile buttons after render
    if (changedProperties.has('showMobileInput') || changedProperties.has('isMobile')) {
      requestAnimationFrame(() => {
        this.adjustTerminalForMobileButtons();
      });
    }
  }

  private createInteractiveTerminal() {
    if (!this.session) return;

    const terminalElement = this.querySelector('#interactive-terminal') as HTMLElement;
    if (!terminalElement) return;

    // Create renderer once and connect to current session
    this.renderer = new Renderer(terminalElement);

    // Wait a moment for freshly created sessions before connecting
    const sessionAge = Date.now() - new Date(this.session.startedAt).getTime();
    const delay = sessionAge < 5000 ? 2000 : 0; // 2 second delay if session is less than 5 seconds old

    if (delay > 0) {
      // Show loading animation during delay for fresh sessions
      this.startLoading();
    }

    setTimeout(() => {
      if (this.renderer && this.session) {
        this.stopLoading(); // Stop loading before connecting
        this.renderer.connectToStream(this.session.id);
      }
    }, delay);

    // Listen for session exit events
    terminalElement.addEventListener('session-exit', this.handleSessionExit.bind(this) as EventListener);
  }

  private async handleKeyboardInput(e: KeyboardEvent) {
    if (!this.session) return;

    // Don't send input to exited sessions
    if (this.session.status === 'exited') {
      console.log('Ignoring keyboard input - session has exited');
      return;
    }

    let inputText = '';

    // Handle special keys
    switch (e.key) {
      case 'Enter':
        if (e.ctrlKey) {
          // Ctrl+Enter - send to tty-fwd for proper handling
          inputText = 'ctrl_enter';
        } else if (e.shiftKey) {
          // Shift+Enter - send to tty-fwd for proper handling
          inputText = 'shift_enter';
        } else {
          // Regular Enter
          inputText = 'enter';
        }
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

    // Handle Ctrl combinations (but not if we already handled Ctrl+Enter above)
    if (e.ctrlKey && e.key.length === 1 && e.key !== 'Enter') {
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
        if (response.status === 400) {
          console.log('Session no longer accepting input (likely exited)');
          // Update session status to exited if we get 400 error
          if (this.session && (this.session.status as string) !== 'exited') {
            this.session = { ...this.session, status: 'exited' };
            this.requestUpdate();
          }
        } else {
          console.error('Failed to send input to session:', response.status);
        }
      }
    } catch (error) {
      console.error('Error sending input:', error);
    }
  }

  private handleBack() {
    window.location.search = '';
  }

  private handleSessionExit(e: Event) {
    const customEvent = e as CustomEvent;
    console.log('Session exit event received:', customEvent.detail);

    if (this.session && customEvent.detail.sessionId === this.session.id) {
      // Update session status to exited
      this.session = { ...this.session, status: 'exited' };
      this.requestUpdate();


      // Switch to snapshot mode
      requestAnimationFrame(() => {
        this.createInteractiveTerminal();
      });
    }
  }

  // Mobile input methods
  private handleMobileInputToggle() {
    this.showMobileInput = !this.showMobileInput;
    if (this.showMobileInput) {
      // Focus the textarea after a short delay to ensure it's rendered
      requestAnimationFrame(() => {
        const textarea = this.querySelector('#mobile-input-textarea') as HTMLTextAreaElement;
        if (textarea) {
          textarea.focus();
          this.adjustTextareaForKeyboard();
        }
      });
    } else {
      // Clean up viewport listener when closing overlay
      const textarea = this.querySelector('#mobile-input-textarea') as HTMLTextAreaElement;
      if (textarea && (textarea as any)._viewportCleanup) {
        (textarea as any)._viewportCleanup();
      }
    }
  }

  private adjustTextareaForKeyboard() {
    // Adjust the layout when virtual keyboard appears
    const textarea = this.querySelector('#mobile-input-textarea') as HTMLTextAreaElement;
    const controls = this.querySelector('#mobile-controls') as HTMLElement;
    if (!textarea || !controls) return;

    const adjustLayout = () => {
      const viewportHeight = window.visualViewport?.height || window.innerHeight;
      const windowHeight = window.innerHeight;
      const keyboardHeight = windowHeight - viewportHeight;

      // If keyboard is visible (viewport height is significantly smaller)
      if (keyboardHeight > 100) {
        // Move controls above the keyboard
        controls.style.transform = `translateY(-${keyboardHeight}px)`;
        controls.style.transition = 'transform 0.3s ease';

        // Calculate available space for textarea
        const header = this.querySelector('.flex.items-center.justify-between.p-4.border-b') as HTMLElement;
        const headerHeight = header?.offsetHeight || 60;
        const controlsHeight = controls?.offsetHeight || 120;
        const padding = 48; // Additional padding for spacing

        // Available height is viewport height minus header and controls (controls are now above keyboard)
        const maxTextareaHeight = viewportHeight - headerHeight - controlsHeight - padding;
        const inputArea = textarea.parentElement as HTMLElement;
        if (inputArea && maxTextareaHeight > 0) {
          // Set the input area to not exceed the available space
          inputArea.style.height = `${maxTextareaHeight}px`;
          inputArea.style.maxHeight = `${maxTextareaHeight}px`;
          inputArea.style.overflow = 'hidden';

          // Set textarea height within the container
          const labelHeight = 40; // Height of the label above textarea
          const textareaMaxHeight = Math.max(maxTextareaHeight - labelHeight, 80);
          textarea.style.height = `${textareaMaxHeight}px`;
          textarea.style.maxHeight = `${textareaMaxHeight}px`;
        }
      } else {
        // Reset position when keyboard is hidden
        controls.style.transform = 'translateY(0px)';
        controls.style.transition = 'transform 0.3s ease';

        // Reset textarea height and constraints
        const inputArea = textarea.parentElement as HTMLElement;
        if (inputArea) {
          inputArea.style.height = '';
          inputArea.style.maxHeight = '';
          inputArea.style.overflow = '';
          textarea.style.height = '';
          textarea.style.maxHeight = '';
        }
      }
    };

    // Listen for viewport changes (keyboard show/hide)
    if (window.visualViewport) {
      window.visualViewport.addEventListener('resize', adjustLayout);
      // Clean up listener when overlay is closed
      const cleanup = () => {
        if (window.visualViewport) {
          window.visualViewport.removeEventListener('resize', adjustLayout);
        }
      };
      // Store cleanup function for later use
      (textarea as any)._viewportCleanup = cleanup;
    }

    // Initial adjustment
    requestAnimationFrame(adjustLayout);
  }

  private handleMobileInputChange(e: Event) {
    const textarea = e.target as HTMLTextAreaElement;
    this.mobileInputText = textarea.value;
  }

  private async handleMobileInputSendOnly() {
    // Get the current value from the textarea directly
    const textarea = this.querySelector('#mobile-input-textarea') as HTMLTextAreaElement;
    const textToSend = textarea?.value?.trim() || this.mobileInputText.trim();

    if (!textToSend) return;

    try {
      // Send text without enter key
      await this.sendInputText(textToSend);

      // Clear both the reactive property and textarea
      this.mobileInputText = '';
      if (textarea) {
        textarea.value = '';
      }

      // Trigger re-render to update button state
      this.requestUpdate();

      // Hide the input overlay after sending
      this.showMobileInput = false;
    } catch (error) {
      console.error('Error sending mobile input:', error);
      // Don't hide the overlay if there was an error
    }
  }

  private async handleMobileInputSend() {
    // Get the current value from the textarea directly
    const textarea = this.querySelector('#mobile-input-textarea') as HTMLTextAreaElement;
    const textToSend = textarea?.value?.trim() || this.mobileInputText.trim();

    if (!textToSend) return;

    try {
      // Add enter key at the end to execute the command
      await this.sendInputText(textToSend + '\n');

      // Clear both the reactive property and textarea
      this.mobileInputText = '';
      if (textarea) {
        textarea.value = '';
      }

      // Trigger re-render to update button state
      this.requestUpdate();

      // Hide the input overlay after sending
      this.showMobileInput = false;
    } catch (error) {
      console.error('Error sending mobile input:', error);
      // Don't hide the overlay if there was an error
    }
  }

  private async handleSpecialKey(key: string) {
    await this.sendInputText(key);
  }

  private async sendInputText(text: string) {
    if (!this.session) return;

    try {
      const response = await fetch(`/api/sessions/${this.session.id}/input`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ text })
      });

      if (!response.ok) {
        console.error('Failed to send input to session');
      }
    } catch (error) {
      console.error('Error sending input:', error);
    }
  }

  private adjustTerminalForMobileButtons() {
    // Disabled for now to avoid viewport issues
    // The mobile buttons will overlay the terminal
  }

  private startLoading() {
    this.loading = true;
    this.loadingFrame = 0;
    this.loadingInterval = window.setInterval(() => {
      this.loadingFrame = (this.loadingFrame + 1) % 4;
      this.requestUpdate();
    }, 200); // Update every 200ms for smooth animation
  }

  private stopLoading() {
    this.loading = false;
    if (this.loadingInterval) {
      clearInterval(this.loadingInterval);
      this.loadingInterval = null;
    }
  }

  private getLoadingText(): string {
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    return frames[this.loadingFrame % frames.length];
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
      <div class="flex flex-col bg-vs-bg font-mono" style="height: 100vh; outline: none !important; box-shadow: none !important;">
        <!-- Compact Header -->
        <div class="flex items-center justify-between px-3 py-2 border-b border-vs-border bg-vs-bg-secondary text-sm">
          <div class="flex items-center gap-3">
            <button
              class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-2 py-1 border-none rounded transition-colors text-xs"
              @click=${this.handleBack}
            >
              BACK
            </button>
            <div class="text-vs-text">
              <div class="text-vs-accent">${this.session.command}</div>
              <div class="text-vs-muted text-xs">${this.session.workingDir}</div>
            </div>
          </div>
          <div class="flex items-center gap-3 text-xs">
            <span class="${this.session.status === 'running' ? 'text-vs-user' : 'text-vs-warning'}">
              ${this.session.status.toUpperCase()}
            </span>
          </div>
        </div>

        <!-- Terminal Container -->
        <div class="flex-1 bg-black overflow-x-auto overflow-y-hidden min-h-0 relative" id="terminal-container">
          <div id="interactive-terminal" class="w-full h-full"></div>
          
          ${this.loading ? html`
            <!-- Loading overlay -->
            <div class="absolute inset-0 bg-black bg-opacity-80 flex items-center justify-center">
              <div class="text-vs-text font-mono text-center">
                <div class="text-2xl mb-2">${this.getLoadingText()}</div>
                <div class="text-sm text-vs-muted">Connecting to session...</div>
              </div>
            </div>
          ` : ''}
        </div>

        <!-- Mobile Input Controls -->
        ${this.isMobile && !this.showMobileInput ? html`
          <div class="flex-shrink-0 p-4 bg-vs-bg">
              <!-- First row: Arrow keys -->
              <div class="flex gap-2 mb-2">
                <button
                  class="flex-1 bg-vs-muted text-vs-bg hover:bg-vs-accent font-mono px-3 py-2 border-none rounded transition-colors text-sm"
                  @click=${() => this.handleSpecialKey('arrow_up')}
                >
                  ↑
                </button>
                <button
                  class="flex-1 bg-vs-muted text-vs-bg hover:bg-vs-accent font-mono px-3 py-2 border-none rounded transition-colors text-sm"
                  @click=${() => this.handleSpecialKey('arrow_down')}
                >
                  ↓
                </button>
                <button
                  class="flex-1 bg-vs-muted text-vs-bg hover:bg-vs-accent font-mono px-3 py-2 border-none rounded transition-colors text-sm"
                  @click=${() => this.handleSpecialKey('arrow_left')}
                >
                  ←
                </button>
                <button
                  class="flex-1 bg-vs-muted text-vs-bg hover:bg-vs-accent font-mono px-3 py-2 border-none rounded transition-colors text-sm"
                  @click=${() => this.handleSpecialKey('arrow_right')}
                >
                  →
                </button>
              </div>

              <!-- Second row: Special keys -->
              <div class="flex gap-2">
                <button
                  class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-3 py-2 border-none rounded transition-colors text-sm"
                  @click=${() => this.handleSpecialKey('\t')}
                >
                  TAB
                </button>
                <button
                  class="bg-vs-function text-vs-bg hover:bg-vs-highlight font-mono px-3 py-2 border-none rounded transition-colors text-sm"
                  @click=${() => this.handleSpecialKey('enter')}
                >
                  ENTER
                </button>
                <button
                  class="bg-vs-warning text-vs-bg hover:bg-vs-highlight font-mono px-3 py-2 border-none rounded transition-colors text-sm"
                  @click=${() => this.handleSpecialKey('escape')}
                >
                  ESC
                </button>
                <button
                  class="bg-vs-error text-vs-text hover:bg-vs-highlight font-mono px-3 py-2 border-none rounded transition-colors text-sm"
                  @click=${() => this.handleSpecialKey('\x03')}
                >
                  ^C
                </button>
                <button
                  class="flex-1 bg-vs-function text-vs-bg hover:bg-vs-highlight font-mono px-3 py-2 border-none rounded transition-colors text-sm"
                  @click=${this.handleMobileInputToggle}
                >
                  TYPE
                </button>
              </div>
          </div>
        ` : ''}

        <!-- Full-Screen Input Overlay (only when opened) -->
        ${this.isMobile && this.showMobileInput ? html`
            <div class="fixed inset-0 bg-vs-bg-secondary bg-opacity-95 z-50 flex flex-col" style="height: 100vh; height: 100dvh;">
              <!-- Input Header -->
              <div class="flex items-center justify-between p-4 border-b border-vs-border flex-shrink-0">
                <div class="text-vs-text font-mono text-sm">Terminal Input</div>
                <button
                  class="text-vs-muted hover:text-vs-text text-lg leading-none border-none bg-transparent cursor-pointer"
                  @click=${this.handleMobileInputToggle}
                >
                  ×
                </button>
              </div>

              <!-- Input Area with dynamic height -->
              <div class="flex-1 p-4 flex flex-col min-h-0">
                <div class="text-vs-muted text-sm mb-2 flex-shrink-0">
                  Type your command(s) below. Supports multiline input.
                </div>
                <textarea
                  id="mobile-input-textarea"
                  class="flex-1 bg-vs-bg text-vs-text border border-vs-border font-mono text-sm p-4 resize-none outline-none"
                  placeholder="Enter your command here..."
                  .value=${this.mobileInputText}
                  @input=${this.handleMobileInputChange}
                  @keydown=${(e: KeyboardEvent) => {
                    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
                      e.preventDefault();
                      this.handleMobileInputSend();
                    }
                  }}
                  style="min-height: 120px; margin-bottom: 16px;"
                ></textarea>
              </div>

              <!-- Controls - Fixed above keyboard -->
              <div id="mobile-controls" class="fixed bottom-0 left-0 right-0 p-4 border-t border-vs-border bg-vs-bg-secondary z-60" style="padding-bottom: max(1rem, env(safe-area-inset-bottom)); transform: translateY(0px);">
                <!-- Send Buttons Row -->
                <div class="flex gap-2 mb-3">
                  <button
                    class="flex-1 bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-4 py-3 border-none rounded transition-colors text-sm font-bold"
                    @click=${this.handleMobileInputSendOnly}
                    ?disabled=${!this.mobileInputText.trim()}
                  >
                    SEND
                  </button>
                  <button
                    class="flex-1 bg-vs-function text-vs-bg hover:bg-vs-highlight font-mono px-4 py-3 border-none rounded transition-colors text-sm font-bold"
                    @click=${this.handleMobileInputSend}
                    ?disabled=${!this.mobileInputText.trim()}
                  >
                    SEND + ENTER
                  </button>
                </div>

                <div class="text-vs-muted text-xs text-center">
                  SEND: text only • SEND + ENTER: text with enter key
                </div>
              </div>
            </div>
        ` : ''}
      </div>
    `;
  }
}