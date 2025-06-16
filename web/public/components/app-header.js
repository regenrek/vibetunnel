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
    render() {
        return html `
      <div class="p-4">
        <h1 class="text-vs-user font-mono text-sm m-0">VibeTunnel</h1>
      </div>
    `;
    }
};
AppHeader = __decorate([
    customElement('app-header')
], AppHeader);
export { AppHeader };
//# sourceMappingURL=app-header.js.map