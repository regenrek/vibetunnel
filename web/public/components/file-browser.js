var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
import { LitElement, html } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
let FileBrowser = class FileBrowser extends LitElement {
    constructor() {
        super(...arguments);
        this.currentPath = '~';
        this.visible = false;
        this.files = [];
        this.loading = false;
        this.showCreateFolder = false;
        this.newFolderName = '';
        this.creating = false;
    }
    // Disable shadow DOM to use Tailwind
    createRenderRoot() {
        return this;
    }
    async connectedCallback() {
        super.connectedCallback();
        if (this.visible) {
            await this.loadDirectory(this.currentPath);
        }
    }
    async updated(changedProperties) {
        if (changedProperties.has('visible') && this.visible) {
            await this.loadDirectory(this.currentPath);
        }
    }
    async loadDirectory(dirPath) {
        this.loading = true;
        try {
            const response = await fetch(`/api/fs/browse?path=${encodeURIComponent(dirPath)}`);
            if (response.ok) {
                const data = await response.json();
                this.currentPath = data.absolutePath;
                this.files = data.files;
            }
            else {
                console.error('Failed to load directory');
            }
        }
        catch (error) {
            console.error('Error loading directory:', error);
        }
        finally {
            this.loading = false;
        }
    }
    handleDirectoryClick(dirName) {
        const newPath = this.currentPath + '/' + dirName;
        this.loadDirectory(newPath);
    }
    handleParentClick() {
        const parentPath = this.currentPath.split('/').slice(0, -1).join('/') || '/';
        this.loadDirectory(parentPath);
    }
    handleSelect() {
        this.dispatchEvent(new CustomEvent('directory-selected', {
            detail: this.currentPath
        }));
    }
    handleCancel() {
        this.dispatchEvent(new CustomEvent('browser-cancel'));
    }
    handleCreateFolder() {
        this.showCreateFolder = true;
        this.newFolderName = '';
    }
    handleCancelCreateFolder() {
        this.showCreateFolder = false;
        this.newFolderName = '';
    }
    handleFolderNameInput(e) {
        this.newFolderName = e.target.value;
    }
    handleFolderNameKeydown(e) {
        if (e.key === 'Enter') {
            e.preventDefault();
            this.createFolder();
        }
        else if (e.key === 'Escape') {
            e.preventDefault();
            this.handleCancelCreateFolder();
        }
    }
    async createFolder() {
        if (!this.newFolderName.trim())
            return;
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
            }
            else {
                const error = await response.json();
                alert(`Failed to create folder: ${error.error}`);
            }
        }
        catch (error) {
            console.error('Error creating folder:', error);
            alert('Failed to create folder');
        }
        finally {
            this.creating = false;
        }
    }
    render() {
        if (!this.visible) {
            return html ``;
        }
        return html `
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
            ${this.loading ? html `
              <div class="text-vs-muted">Loading...</div>
            ` : html `
              ${this.currentPath !== '/' ? html `
                <div 
                  class="flex items-center gap-2 p-2 hover:bg-vs-nav-hover cursor-pointer text-vs-accent"
                  @click=${this.handleParentClick}
                >
                  <span>📁</span>
                  <span>.. (parent directory)</span>
                </div>
              ` : ''}
              
              ${this.files.filter(f => f.isDir).map(file => html `
                <div 
                  class="flex items-center gap-2 p-2 hover:bg-vs-nav-hover cursor-pointer text-vs-accent"
                  @click=${() => this.handleDirectoryClick(file.name)}
                >
                  <span>📁</span>
                  <span>${file.name}</span>
                </div>
              `)}
              
              ${this.files.filter(f => !f.isDir).map(file => html `
                <div class="flex items-center gap-2 p-2 text-vs-muted">
                  <span>📄</span>
                  <span>${file.name}</span>
                </div>
              `)}
            `}
          </div>

          <!-- Create folder dialog -->
          ${this.showCreateFolder ? html `
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
};
__decorate([
    property({ type: String })
], FileBrowser.prototype, "currentPath", void 0);
__decorate([
    property({ type: Boolean })
], FileBrowser.prototype, "visible", void 0);
__decorate([
    state()
], FileBrowser.prototype, "files", void 0);
__decorate([
    state()
], FileBrowser.prototype, "loading", void 0);
__decorate([
    state()
], FileBrowser.prototype, "showCreateFolder", void 0);
__decorate([
    state()
], FileBrowser.prototype, "newFolderName", void 0);
__decorate([
    state()
], FileBrowser.prototype, "creating", void 0);
FileBrowser = __decorate([
    customElement('file-browser')
], FileBrowser);
export { FileBrowser };
//# sourceMappingURL=file-browser.js.map