import { v4 as uuidv4 } from 'uuid';

export class HQClient {
  private readonly hqUrl: string;
  private readonly remoteId: string;
  private readonly remoteName: string;
  private readonly token: string;
  private readonly hqUsername: string;
  private readonly hqPassword: string;
  private registrationRetryTimeout: NodeJS.Timeout | null = null;

  constructor(hqUrl: string, hqUsername: string, hqPassword: string, remoteName: string) {
    this.hqUrl = hqUrl;
    this.remoteId = uuidv4();
    this.remoteName = remoteName;
    this.token = uuidv4();
    this.hqUsername = hqUsername;
    this.hqPassword = hqPassword;
  }

  async register(): Promise<void> {
    try {
      const response = await fetch(`${this.hqUrl}/api/remotes/register`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Basic ${Buffer.from(`${this.hqUsername}:${this.hqPassword}`).toString('base64')}`,
        },
        body: JSON.stringify({
          id: this.remoteId,
          name: this.remoteName,
          url: `http://localhost:${process.env.PORT || 4020}`,
          token: this.token, // Token for HQ to authenticate with this remote
        }),
      });

      if (!response.ok) {
        const errorBody = await response.json().catch(() => ({ error: response.statusText }));
        throw new Error(`Registration failed: ${errorBody.error || response.statusText}`);
      }

      console.log(`Successfully registered with HQ at ${this.hqUrl}`);
      console.log(`Remote ID: ${this.remoteId}`);
      console.log(`Remote name: ${this.remoteName}`);
      console.log(`Token: ${this.token}`);
    } catch (error) {
      console.error('Failed to register with HQ:', error);
      // Retry registration after 5 seconds
      this.registrationRetryTimeout = setTimeout(() => this.register(), 5000);
    }
  }

  destroy(): void {
    if (this.registrationRetryTimeout) {
      clearTimeout(this.registrationRetryTimeout);
    }

    // Try to unregister
    fetch(`${this.hqUrl}/api/remotes/${this.remoteId}`, {
      method: 'DELETE',
      headers: {
        Authorization: `Basic ${Buffer.from(`${this.hqUsername}:${this.hqPassword}`).toString('base64')}`,
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
