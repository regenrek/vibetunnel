import { v4 as uuidv4 } from 'uuid';
import * as os from 'os';

export class HQClient {
  private readonly hqUrl: string;
  private readonly remoteId: string;
  private readonly remoteName: string;
  private token: string;
  private heartbeatInterval: NodeJS.Timeout | null = null;
  private registrationRetryTimeout: NodeJS.Timeout | null = null;

  constructor(hqUrl: string, password: string) {
    this.hqUrl = hqUrl;
    this.remoteId = uuidv4();
    this.remoteName = `${os.hostname()}-${process.pid}`;
    this.token = this.generateToken();

    // Store password for future use
    this.password = password;
  }

  private password: string;

  private generateToken(): string {
    return uuidv4();
  }

  async register(): Promise<void> {
    try {
      const response = await fetch(`${this.hqUrl}/api/remotes/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          id: this.remoteId,
          name: this.remoteName,
          url: `http://localhost:${process.env.PORT || 4020}`,
          token: this.token,
          password: this.password,
        }),
      });

      if (!response.ok) {
        throw new Error(`Registration failed: ${response.statusText}`);
      }

      console.log(`Successfully registered with HQ at ${this.hqUrl}`);
      this.startHeartbeat();
    } catch (error) {
      console.error('Failed to register with HQ:', error);
      // Retry registration after 5 seconds
      this.registrationRetryTimeout = setTimeout(() => this.register(), 5000);
    }
  }

  private async sendHeartbeat(): Promise<void> {
    try {
      // Get session count from the session manager
      const sessionCount = await this.getSessionCount();

      const response = await fetch(`${this.hqUrl}/api/remotes/${this.remoteId}/heartbeat`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${this.token}`,
        },
        body: JSON.stringify({
          sessionCount,
        }),
      });

      if (!response.ok) {
        console.error('Heartbeat failed:', response.statusText);
        // Re-register if heartbeat fails
        this.stopHeartbeat();
        await this.register();
      }
    } catch (error) {
      console.error('Failed to send heartbeat:', error);
    }
  }

  private startHeartbeat(): void {
    // Send heartbeat every 15 seconds
    this.heartbeatInterval = setInterval(() => {
      this.sendHeartbeat();
    }, 15000);

    // Send first heartbeat immediately
    this.sendHeartbeat();
  }

  private stopHeartbeat(): void {
    if (this.heartbeatInterval) {
      clearInterval(this.heartbeatInterval);
      this.heartbeatInterval = null;
    }
  }

  private async getSessionCount(): Promise<number> {
    try {
      const response = await fetch(`http://localhost:${process.env.PORT || 4020}/api/sessions`, {
        headers: {
          Authorization: `Basic ${Buffer.from(`user:${this.password}`).toString('base64')}`,
        },
      });

      if (response.ok) {
        const sessions = await response.json();
        return Array.isArray(sessions) ? sessions.length : 0;
      }
    } catch {
      // Ignore errors
    }
    return 0;
  }

  destroy(): void {
    this.stopHeartbeat();
    if (this.registrationRetryTimeout) {
      clearTimeout(this.registrationRetryTimeout);
    }

    // Try to unregister
    fetch(`${this.hqUrl}/api/remotes/${this.remoteId}`, {
      method: 'DELETE',
      headers: {
        Authorization: `Bearer ${this.token}`,
      },
    }).catch(() => {
      // Ignore errors during shutdown
    });
  }

  getRemoteId(): string {
    return this.remoteId;
  }

  getToken(): string {
    return this.token;
  }
}
