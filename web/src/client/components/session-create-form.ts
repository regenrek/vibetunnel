import { LitElement, html, PropertyValues } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import './file-browser.js';

export interface SessionCreateData {
  command: string[];
  workingDir: string;
  name?: string;
  spawn_terminal?: boolean;
  cols?: number;
  rows?: number;
}

@customElement('session-create-form')
export class SessionCreateForm extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @property({ type: String }) workingDir = '~/';
  @property({ type: String }) command = 'zsh';
  @property({ type: String }) sessionName = '';
  @property({ type: Boolean }) disabled = false;
  @property({ type: Boolean }) visible = false;

  @state() private isCreating = false;
  @state() private showFileBrowser = false;
  @state() private selectedQuickStart = 'zsh';

  private quickStartCommands = [
    { label: 'claude', command: 'claude' },
    { label: 'zsh', command: 'zsh' },
    { label: 'bash', command: 'bash' },
    { label: 'python3', command: 'python3' },
    { label: 'node', command: 'node' },
    { label: 'npm run dev', command: 'npm run dev' },
  ];

  private readonly STORAGE_KEY_WORKING_DIR = 'vibetunnel_last_working_dir';
  private readonly STORAGE_KEY_COMMAND = 'vibetunnel_last_command';

  connectedCallback() {
    super.connectedCallback();
    // Load from localStorage when component is first created
    this.loadFromLocalStorage();
  }

  private loadFromLocalStorage() {
    try {
      const savedWorkingDir = localStorage.getItem(this.STORAGE_KEY_WORKING_DIR);
      const savedCommand = localStorage.getItem(this.STORAGE_KEY_COMMAND);

      console.log('Loading from localStorage:', { savedWorkingDir, savedCommand });

      if (savedWorkingDir) {
        this.workingDir = savedWorkingDir;
      }
      if (savedCommand) {
        this.command = savedCommand;
      }

      // Force re-render to update the input values
      this.requestUpdate();
    } catch (error) {
      console.warn('Failed to load from localStorage:', error);
    }
  }

  private saveToLocalStorage() {
    try {
      const workingDir = this.workingDir.trim();
      const command = this.command.trim();

      console.log('Saving to localStorage:', { workingDir, command });

      // Only save non-empty values
      if (workingDir) {
        localStorage.setItem(this.STORAGE_KEY_WORKING_DIR, workingDir);
      }
      if (command) {
        localStorage.setItem(this.STORAGE_KEY_COMMAND, command);
      }
    } catch (error) {
      console.warn('Failed to save to localStorage:', error);
    }
  }

  updated(changedProperties: PropertyValues) {
    super.updated(changedProperties);

    // Load from localStorage when form becomes visible
    if (changedProperties.has('visible') && this.visible) {
      this.loadFromLocalStorage();
    }
  }

  private handleWorkingDirChange(e: Event) {
    const input = e.target as HTMLInputElement;
    this.workingDir = input.value;
    this.dispatchEvent(
      new CustomEvent('working-dir-change', {
        detail: this.workingDir,
      })
    );
  }

  private handleCommandChange(e: Event) {
    const input = e.target as HTMLInputElement;
    this.command = input.value;
  }

  private handleSessionNameChange(e: Event) {
    const input = e.target as HTMLInputElement;
    this.sessionName = input.value;
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
      this.dispatchEvent(
        new CustomEvent('error', {
          detail: 'Please fill in both working directory and command',
        })
      );
      return;
    }

    this.isCreating = true;

    // Use conservative defaults that work well across devices
    // The terminal will auto-resize to fit the actual container after creation
    const terminalCols = 120;
    const terminalRows = 30;

    const sessionData: SessionCreateData = {
      command: this.parseCommand(this.command.trim()),
      workingDir: this.workingDir.trim(),
      spawn_terminal: true,
      cols: terminalCols,
      rows: terminalRows,
    };

    // Add session name if provided
    if (this.sessionName.trim()) {
      sessionData.name = this.sessionName.trim();
    }

    try {
      const response = await fetch('/api/sessions', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(sessionData),
      });

      if (response.ok) {
        const result = await response.json();

        // Save to localStorage before clearing the fields
        this.saveToLocalStorage();

        this.command = ''; // Clear command on success
        this.sessionName = ''; // Clear session name on success
        this.dispatchEvent(
          new CustomEvent('session-created', {
            detail: result,
          })
        );
      } else {
        const error = await response.json();
        this.dispatchEvent(
          new CustomEvent('error', {
            detail: `Failed to create session: ${error.error}`,
          })
        );
      }
    } catch (error) {
      console.error('Error creating session:', error);
      this.dispatchEvent(
        new CustomEvent('error', {
          detail: 'Failed to create session',
        })
      );
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

  private handleQuickStart(command: string) {
    this.command = command;
    this.selectedQuickStart = command;
  }

  render() {
    if (!this.visible) {
      return html``;
    }

    return html`
      <div class="modal-backdrop flex items-center justify-center">
        <div class="modal-content font-mono text-sm w-96 lg:w-[576px] max-w-full mx-4">
          <div class="pb-6 mb-6 border-b border-dark-border">
            <h2 class="text-accent-green text-lg font-bold">New Session</h2>
          </div>

          <div class="p-4 lg:p-8">
            <!-- Session Name -->
            <div class="mb-6">
              <label class="form-label">Session Name (Optional):</label>
              <input
                type="text"
                class="input-field"
                .value=${this.sessionName}
                @input=${this.handleSessionNameChange}
                placeholder="My Session"
                ?disabled=${this.disabled || this.isCreating}
              />
            </div>

            <!-- Command -->
            <div class="mb-6">
              <label class="form-label">Command:</label>
              <input
                type="text"
                class="input-field"
                .value=${this.command}
                @input=${this.handleCommandChange}
                @keydown=${(e: KeyboardEvent) => e.key === 'Enter' && this.handleCreate()}
                placeholder="zsh"
                ?disabled=${this.disabled || this.isCreating}
              />
            </div>

            <!-- Working Directory -->
            <div class="mb-6">
              <label class="form-label">Working Directory:</label>
              <div class="flex gap-4">
                <input
                  type="text"
                  class="input-field"
                  .value=${this.workingDir}
                  @input=${this.handleWorkingDirChange}
                  placeholder="~/"
                  ?disabled=${this.disabled || this.isCreating}
                />
                <button
                  class="btn-secondary font-mono px-4"
                  @click=${this.handleBrowse}
                  ?disabled=${this.disabled || this.isCreating}
                >
                  📁
                </button>
              </div>
            </div>

            <!-- Quick Start Section -->
            <div class="mb-6">
              <label class="form-label text-dark-text-secondary uppercase text-xs tracking-wider"
                >Quick Start</label
              >
              <div class="grid grid-cols-2 gap-3 mt-3">
                ${this.quickStartCommands.map(
                  ({ label, command }) => html`
                    <button
                      @click=${() => this.handleQuickStart(command)}
                      class="px-4 py-3 rounded border text-left transition-all
                        ${this.command === command
                        ? 'bg-accent-green bg-opacity-20 border-accent-green text-accent-green'
                        : 'bg-dark-border bg-opacity-10 border-dark-border text-dark-text hover:bg-opacity-20 hover:border-dark-text-secondary'}"
                      ?disabled=${this.disabled || this.isCreating}
                    >
                      ${label === 'claude' ? '✨ ' : ''}${label === 'npm run dev'
                        ? '▶️ '
                        : ''}${label}
                    </button>
                  `
                )}
              </div>
            </div>

            <div class="flex gap-4 mt-8">
              <button
                class="btn-ghost font-mono flex-1 py-3"
                @click=${this.handleCancel}
                ?disabled=${this.isCreating}
              >
                Cancel
              </button>
              <button
                class="btn-primary font-mono flex-1 py-3 disabled:opacity-50 disabled:cursor-not-allowed"
                @click=${this.handleCreate}
                ?disabled=${this.disabled ||
                this.isCreating ||
                !this.workingDir.trim() ||
                !this.command.trim()}
              >
                ${this.isCreating ? 'Creating...' : 'Create'}
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
