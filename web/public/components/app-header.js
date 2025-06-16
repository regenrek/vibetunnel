var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};
import { LitElement, html } from 'lit';
import { customElement } from 'lit/decorators.js';
let AppHeader = class AppHeader extends LitElement {
    createRenderRoot() {
        return this;
    }
    handleCreateSession() {
        this.dispatchEvent(new CustomEvent('create-session'));
    }
    render() {
        return html `
      <div class="p-4 border-b border-vs-border">
        <div class="flex items-center justify-between">
          <div class="text-vs-user font-mono text-sm">VibeTunnel</div>
          <button
            class="bg-vs-user text-vs-text hover:bg-vs-accent font-mono px-4 py-2 border-none rounded transition-colors text-sm"
            @click=${this.handleCreateSession}
          >
            CREATE SESSION
          </button>
        </div>
      </div>
    `;
    }
};
AppHeader = __decorate([
    customElement('app-header')
], AppHeader);
export { AppHeader };
//# sourceMappingURL=app-header.js.map