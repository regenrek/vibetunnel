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

  render() {
    if (!this.visible) {
      return html``;
    }

    return html`
      <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center" style="z-index: 9999;">
        <div class="bg-vs-bg-secondary border border-vs-border font-mono text-sm w-96 h-96 flex flex-col">
          <div class="p-4 border-b border-vs-border flex-shrink-0">
            <div class="text-vs-assistant text-sm mb-2">Select Directory</div>
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