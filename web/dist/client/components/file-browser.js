"use strict";
var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
var __metadata = (this && this.__metadata) || function (k, v) {
    if (typeof Reflect === "object" && typeof Reflect.metadata === "function") return Reflect.metadata(k, v);
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.FileBrowser = void 0;
const lit_1 = require("lit");
const decorators_js_1 = require("lit/decorators.js");
let FileBrowser = class FileBrowser extends lit_1.LitElement {
    constructor() {
        super(...arguments);
        this.currentPath = '~';
        this.visible = false;
        this.files = [];
        this.loading = false;
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
    render() {
        if (!this.visible) {
            return (0, lit_1.html) ``;
        }
        return (0, lit_1.html) `
      <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center" style="z-index: 9999;">
        <div class="bg-vs-bg-secondary border border-vs-border font-mono text-sm w-96 h-96 flex flex-col">
          <div class="p-4 border-b border-vs-border flex-shrink-0">
            <div class="text-vs-assistant text-sm mb-2">Select Directory</div>
            <div class="text-vs-muted text-sm break-all">${this.currentPath}</div>
          </div>
          
          <div class="p-4 flex-1 overflow-y-auto">
            ${this.loading ? (0, lit_1.html) `
              <div class="text-vs-muted">Loading...</div>
            ` : (0, lit_1.html) `
              ${this.currentPath !== '/' ? (0, lit_1.html) `
                <div 
                  class="flex items-center gap-2 p-2 hover:bg-vs-nav-hover cursor-pointer text-vs-accent"
                  @click=${this.handleParentClick}
                >
                  <span>📁</span>
                  <span>.. (parent directory)</span>
                </div>
              ` : ''}
              
              ${this.files.filter(f => f.isDir).map(file => (0, lit_1.html) `
                <div 
                  class="flex items-center gap-2 p-2 hover:bg-vs-nav-hover cursor-pointer text-vs-accent"
                  @click=${() => this.handleDirectoryClick(file.name)}
                >
                  <span>📁</span>
                  <span>${file.name}</span>
                </div>
              `)}
              
              ${this.files.filter(f => !f.isDir).map(file => (0, lit_1.html) `
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
};
exports.FileBrowser = FileBrowser;
__decorate([
    (0, decorators_js_1.property)({ type: String }),
    __metadata("design:type", Object)
], FileBrowser.prototype, "currentPath", void 0);
__decorate([
    (0, decorators_js_1.property)({ type: Boolean }),
    __metadata("design:type", Object)
], FileBrowser.prototype, "visible", void 0);
__decorate([
    (0, decorators_js_1.state)(),
    __metadata("design:type", Array)
], FileBrowser.prototype, "files", void 0);
__decorate([
    (0, decorators_js_1.state)(),
    __metadata("design:type", Object)
], FileBrowser.prototype, "loading", void 0);
exports.FileBrowser = FileBrowser = __decorate([
    (0, decorators_js_1.customElement)('file-browser')
], FileBrowser);
//# sourceMappingURL=file-browser.js.map