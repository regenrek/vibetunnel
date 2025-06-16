import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import './file-browser.js';

export interface SessionCreateData {
  command: string[];
  workingDir: string;
}

@customElement('session-create-form')
export class SessionCreateForm extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @property({ type: String }) workingDir = '~/';
  @property({ type: String }) command = '';
  @property({ type: Boolean }) disabled = false;
  @property({ type: Boolean }) visible = false;

  @state() private isCreating = false;
  @state() private showFileBrowser = false;

  private handleWorkingDirChange(e: Event) {
    const input = e.target as HTMLInputElement;
    this.workingDir = input.value;
    this.dispatchEvent(new CustomEvent('working-dir-change', {
      detail: this.workingDir
    }));
  }

  private handleCommandChange(e: Event) {
    const input = e.target as HTMLInputElement;
    this.command = input.value;
  }

  private handleBrowse() {
    this.showFileBrowser = true;
  }

  private handleDirectorySelected(e: CustomEvent) {
    this.workingDir = e.detail;
    this.showFileBrowser = false;
  }

  private handleBrowserCancel() {
    this.showFileBrowser = false;
  }

  private async handleCreate() {
    if (!this.workingDir.trim() || !this.command.trim()) {
      this.dispatchEvent(new CustomEvent('error', {
        detail: 'Please fill in both working directory and command'
      }));
      return;
    }

    this.isCreating = true;

    const sessionData: SessionCreateData = {
      command: this.parseCommand(this.command.trim()),
      workingDir: this.workingDir.trim()
    };

    try {
      const response = await fetch('/api/sessions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(sessionData)
      });

      if (response.ok) {
        const result = await response.json();
        this.command = ''; // Clear command on success
        this.dispatchEvent(new CustomEvent('session-created', {
          detail: result
        }));
      } else {
        const error = await response.json();
        this.dispatchEvent(new CustomEvent('error', {
          detail: `Failed to create session: ${error.error}`
        }));
      }
    } catch (error) {
      console.error('Error creating session:', error);
      this.dispatchEvent(new CustomEvent('error', {
        detail: 'Failed to create session'
      }));
    } finally {
      this.isCreating = false;
    }
  }

  private parseCommand(commandStr: string): string[] {
    // Simple command parsing - split by spaces but respect quotes
    const args: string[] = [];
    let current = '';
    let inQuotes = false;
    let quoteChar = '';

    for (let i = 0; i < commandStr.length; i++) {
      const char = commandStr[i];
      
      if ((char === '"' || char === "'") && !inQuotes) {
        inQuotes = true;
        quoteChar = char;
      } else if (char === quoteChar && inQuotes) {
        inQuotes = false;
        quoteChar = '';
      } else if (char === ' ' && !inQuotes) {
        if (current) {
          args.push(current);
          current = '';
        }
      } else {
        current += char;
      }
    }
    
    if (current) {
      args.push(current);
    }
    
    return args;
  }

  private handleCancel() {
    this.dispatchEvent(new CustomEvent('cancel'));
  }

  render() {
    if (!this.visible) {
      return html``;
    }

    return html`
      <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center" style="z-index: 9999;">
        <div class="bg-vs-bg-secondary border border-vs-border font-mono text-sm w-96 max-w-full mx-4">
          <div class="p-4 border-b border-vs-border flex justify-between items-center">
            <div class="text-vs-assistant text-sm">Create New Session</div>
            <button 
              class="text-vs-muted hover:text-vs-text text-lg leading-none border-none bg-transparent cursor-pointer"
              @click=${this.handleCancel}
            >×</button>
          </div>
          
          <div class="p-4">
        
        <div class="mb-4">
          <div class="text-vs-muted mb-2">Working Directory:</div>
          <div class="flex gap-4">
            <input
              type="text"
              class="flex-1 bg-vs-bg text-vs-text border border-vs-border outline-none font-mono px-4 py-2"
              .value=${this.workingDir}
              @input=${this.handleWorkingDirChange}
              placeholder="~/"
              ?disabled=${this.disabled || this.isCreating}
            />
            <button 
              class="bg-vs-function text-vs-bg hover:bg-vs-highlight font-mono px-4 py-2 border-none"
              @click=${this.handleBrowse}
              ?disabled=${this.disabled || this.isCreating}
            >
              browse
            </button>
          </div>
        </div>

        <div class="mb-4">
          <div class="text-vs-muted mb-2">Command:</div>
          <input
            type="text"
            class="w-full bg-vs-bg text-vs-text border border-vs-border outline-none font-mono px-4 py-2"
            .value=${this.command}
            @input=${this.handleCommandChange}
            @keydown=${(e: KeyboardEvent) => e.key === 'Enter' && this.handleCreate()}
            placeholder="zsh"
            ?disabled=${this.disabled || this.isCreating}
          />
        </div>

            <div class="flex gap-4 justify-end">
              <button 
                class="bg-vs-muted text-vs-bg hover:bg-vs-text font-mono px-4 py-2 border-none"
                @click=${this.handleCancel}
                ?disabled=${this.isCreating}
              >
                cancel
              </button>
              <button 
                class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-4 py-2 border-none disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:bg-vs-user"
                @click=${this.handleCreate}
                ?disabled=${this.disabled || this.isCreating || !this.workingDir.trim() || !this.command.trim()}
              >
                ${this.isCreating ? 'creating...' : 'create'}
              </button>
            </div>
          </div>
        </div>
      </div>
      
      <file-browser
        .visible=${this.showFileBrowser}
        .currentPath=${this.workingDir}
        @directory-selected=${this.handleDirectorySelected}
        @browser-cancel=${this.handleBrowserCancel}
      ></file-browser>
    `;
  }
}