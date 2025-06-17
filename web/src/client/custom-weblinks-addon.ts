import { Terminal, ITerminalAddon } from '@xterm/xterm';

export class CustomWebLinksAddon implements ITerminalAddon {
  private _terminal?: Terminal;
  private _linkMatcher?: number;

  constructor(private _handler?: (event: MouseEvent, uri: string) => void) {}

  public activate(terminal: Terminal): void {
    this._terminal = terminal;

    // URL regex pattern - matches http/https URLs
    const urlRegex = /(https?:\/\/[^\s]+)/gi;

    this._linkMatcher = this._terminal.registerLinkMatcher(
      urlRegex,
      (event: MouseEvent, uri: string) => {
        console.log('Custom WebLinks click:', uri);
        if (this._handler) {
          this._handler(event, uri);
        } else {
          window.open(uri, '_blank');
        }
      },
      {
        // Custom styling options
        hover: (
          event: MouseEvent,
          uri: string,
          _location: { start: { x: number; y: number }; end: { x: number; y: number } }
        ) => {
          console.log('Custom WebLinks hover:', uri);
          // Style the link on hover
          const linkElement = event.target as HTMLElement;
          if (linkElement) {
            linkElement.style.backgroundColor = 'rgba(59, 142, 234, 0.2)';
            linkElement.style.color = '#ffffff';
            linkElement.style.textDecoration = 'underline';
          }
        },
        leave: (event: MouseEvent, uri: string) => {
          console.log('Custom WebLinks leave:', uri);
          // Remove hover styling
          const linkElement = event.target as HTMLElement;
          if (linkElement) {
            linkElement.style.backgroundColor = '';
            linkElement.style.color = '#3b8eea';
            linkElement.style.textDecoration = 'underline';
          }
        },
        priority: 1,
        willLinkActivate: (event: MouseEvent, uri: string) => {
          console.log('Custom WebLinks will activate:', uri);
          return true;
        },
      }
    );

    console.log('Custom WebLinks addon activated with matcher ID:', this._linkMatcher);
  }

  public dispose(): void {
    if (this._linkMatcher !== undefined && this._terminal) {
      this._terminal.deregisterLinkMatcher(this._linkMatcher);
      this._linkMatcher = undefined;
    }
    this._terminal = undefined;
  }
}
