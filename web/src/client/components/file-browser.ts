import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';

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

@customElement('file-browser')
export class FileBrowser extends LitElement {
  // Disable shadow DOM to use Tailwind
  createRenderRoot() {
    return this;
  }

  @property({ type: String }) currentPath = '~';
  @property({ type: Boolean }) visible = false;

  @state() private files: FileInfo[] = [];
  @state() private loading = false;
  @state() private showCreateFolder = false;
  @state() private newFolderName = '';
  @state() private creating = false;

  async connectedCallback() {
    super.connectedCallback();
    if (this.visible) {
      await this.loadDirectory(this.currentPath);
    }
  }

  async updated(changedProperties: Map<string, any>) {
    if (changedProperties.has('visible') && this.visible) {
      await this.loadDirectory(this.currentPath);
    }
  }

  private async loadDirectory(dirPath: string) {
    this.loading = true;
    try {
      const response = await fetch(`/api/fs/browse?path=${encodeURIComponent(dirPath)}`);
      if (response.ok) {
        const data: DirectoryListing = await response.json();
        this.currentPath = data.absolutePath;
        this.files = data.files;
      } else {
        console.error('Failed to load directory');
      }
    } catch (error) {
      console.error('Error loading directory:', error);
    } finally {
      this.loading = false;
    }
  }

  private handleDirectoryClick(dirName: string) {
    const newPath = this.currentPath + '/' + dirName;
    this.loadDirectory(newPath);
  }

  private handleParentClick() {
    const parentPath = this.currentPath.split('/').slice(0, -1).join('/') || '/';
    this.loadDirectory(parentPath);
  }

  private handleSelect() {
    this.dispatchEvent(new CustomEvent('directory-selected', {
      detail: this.currentPath
    }));
  }

  private handleCancel() {
    this.dispatchEvent(new CustomEvent('browser-cancel'));
  }

  private handleCreateFolder() {
    this.showCreateFolder = true;
    this.newFolderName = '';
  }

  private handleCancelCreateFolder() {
    this.showCreateFolder = false;
    this.newFolderName = '';
  }

  private handleFolderNameInput(e: Event) {
    this.newFolderName = (e.target as HTMLInputElement).value;
  }

  private handleFolderNameKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter') {
      e.preventDefault();
      this.createFolder();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      this.handleCancelCreateFolder();
    }
  }

  private async createFolder() {
    if (!this.newFolderName.trim()) return;

    this.creating = true;
    try {
      const response = await fetch('/api/mkdir', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          path: this.currentPath,
          name: this.newFolderName.trim()
        })
      });

      if (response.ok) {
        // Refresh directory listing
        await this.loadDirectory(this.currentPath);
        this.handleCancelCreateFolder();
      } else {
        const error = await response.json();
        alert(`Failed to create folder: ${error.error}`);
      }
    } catch (error) {
      console.error('Error creating folder:', error);
      alert('Failed to create folder');
    } finally {
      this.creating = false;
    }
  }

  render() {
    if (!this.visible) {
      return html``;
    }

    return html`
      <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center" style="z-index: 9999;">
        <div class="bg-vs-bg-secondary border border-vs-border font-mono text-sm w-96 h-96 flex flex-col">
          <div class="p-4 border-b border-vs-border flex-shrink-0">
            <div class="flex justify-between items-center mb-2">
              <div class="text-vs-assistant text-sm">Select Directory</div>
              <button 
                class="bg-vs-user text-vs-bg hover:bg-vs-accent font-mono px-2 py-1 text-xs border-none rounded"
                @click=${this.handleCreateFolder}
                ?disabled=${this.loading}
                title="Create new folder"
              >
                + folder
              </button>
            </div>
            <div class="text-vs-muted text-sm break-all">${this.currentPath}</div>
          </div>
          
          <div class="p-4 flex-1 overflow-y-auto">
            ${this.loading ? html`
              <div class="text-vs-muted">Loading...</div>
            ` : html`
              ${this.currentPath !== '/' ? html`
                <div 
                  class="flex items-center gap-2 p-2 hover:bg-vs-nav-hover cursor-pointer text-vs-accent"
                  @click=${this.handleParentClick}
                >
                  <span>📁</span>
                  <span>.. (parent directory)</span>
                </div>
              ` : ''}
              
              ${this.files.filter(f => f.isDir).map(file => html`
                <div 
                  class="flex items-center gap-2 p-2 hover:bg-vs-nav-hover cursor-pointer text-vs-accent"
                  @click=${() => this.handleDirectoryClick(file.name)}
                >
                  <span>📁</span>
                  <span>${file.name}</span>
                </div>
              `)}
              
              ${this.files.filter(f => !f.isDir).map(file => html`
                <div class="flex items-center gap-2 p-2 text-vs-muted">
                  <span>📄</span>
                  <span>${file.name}</span>
                </div>
              `)}
            `}
          </div>

          <!-- Create folder dialog -->
          ${this.showCreateFolder ? html`
            <div class="p-4 border-t border-vs-border flex-shrink-0">
              <div class="text-vs-assistant text-sm mb-2">Create New Folder</div>
              <div class="flex gap-2">
                <input 
                  type="text" 
                  class="flex-1 bg-vs-bg border border-vs-border text-vs-text px-2 py-1 text-sm font-mono"
                  placeholder="Folder name"
                  .value=${this.newFolderName}
                  @input=${this.handleFolderNameInput}
                  @keydown=${this.handleFolderNameKeydown}
                  ?disabled=${this.creating}
                />
                <button 
                  class="bg-vs-user text-vs-bg hover:bg-vs-accent font-mono px-2 py-1 text-xs border-none"
                  @click=${this.createFolder}
                  ?disabled=${this.creating || !this.newFolderName.trim()}
                >
                  ${this.creating ? '...' : 'create'}
                </button>
                <button 
                  class="bg-vs-muted text-vs-bg hover:bg-vs-text font-mono px-2 py-1 text-xs border-none"
                  @click=${this.handleCancelCreateFolder}
                  ?disabled=${this.creating}
                >
                  cancel
                </button>
              </div>
            </div>
          ` : ''}
          
          <div class="p-4 border-t border-vs-border flex gap-4 justify-end flex-shrink-0">
            <button 
              class="bg-vs-muted text-vs-bg hover:bg-vs-text font-mono px-4 py-2 border-none"
              @click=${this.handleCancel}
            >
              cancel
            </button>
            <button 
              class="bg-vs-user text-vs-bg hover:bg-vs-accent font-mono px-4 py-2 border-none"
              @click=${this.handleSelect}
            >
              select
            </button>
          </div>
        </div>
      </div>
    `;
  }
}