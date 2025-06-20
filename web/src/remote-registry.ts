export interface RemoteServer {
  id: string;
  name: string;
  url: string;
  token: string;
  registeredAt: Date;
  lastHeartbeat: Date;
  sessionCount: number;
  status: 'online' | 'offline';
}

export class RemoteRegistry {
  private remotes: Map<string, RemoteServer> = new Map();
  private healthCheckInterval: NodeJS.Timeout | null = null;
  private readonly HEALTH_CHECK_INTERVAL = 15000; // Check every 15 seconds
  private readonly HEALTH_CHECK_TIMEOUT = 5000; // 5 second timeout per check

  constructor() {
    this.startHealthChecker();
  }

  register(remote: Omit<RemoteServer, 'registeredAt' | 'lastHeartbeat' | 'status'>): RemoteServer {
    const now = new Date();
    const registeredRemote: RemoteServer = {
      ...remote,
      registeredAt: now,
      lastHeartbeat: now,
      status: 'online',
    };

    this.remotes.set(remote.id, registeredRemote);
    console.log(`Remote registered: ${remote.name} (${remote.id}) from ${remote.url}`);

    // Immediately check health of new remote
    this.checkRemoteHealth(registeredRemote);

    return registeredRemote;
  }

  unregister(remoteId: string): boolean {
    const remote = this.remotes.get(remoteId);
    if (remote) {
      console.log(`Remote unregistered: ${remote.name} (${remoteId})`);
      return this.remotes.delete(remoteId);
    }
    return false;
  }

  getRemote(remoteId: string): RemoteServer | undefined {
    return this.remotes.get(remoteId);
  }

  getRemoteByUrl(url: string): RemoteServer | undefined {
    return Array.from(this.remotes.values()).find((r) => r.url === url);
  }

  getAllRemotes(): RemoteServer[] {
    return Array.from(this.remotes.values());
  }

  getOnlineRemotes(): RemoteServer[] {
    return this.getAllRemotes().filter((r) => r.status === 'online');
  }

  private async checkRemoteHealth(remote: RemoteServer): Promise<void> {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), this.HEALTH_CHECK_TIMEOUT);

      // Use the token provided by the remote for authentication
      const headers: Record<string, string> = {
        Authorization: `Bearer ${remote.token}`,
      };

      const response = await fetch(`${remote.url}/api/sessions`, {
        headers,
        signal: controller.signal,
      });

      clearTimeout(timeoutId);

      if (response.ok) {
        const sessions = await response.json();
        remote.lastHeartbeat = new Date();
        remote.sessionCount = Array.isArray(sessions) ? sessions.length : 0;

        if (remote.status !== 'online') {
          remote.status = 'online';
          console.log(`Remote came online: ${remote.name} (${remote.id})`);
        }
      } else {
        throw new Error(`HTTP ${response.status}`);
      }
    } catch (error) {
      if (remote.status !== 'offline') {
        remote.status = 'offline';
        console.log(`Remote went offline: ${remote.name} (${remote.id}) - ${error}`);
      }
    }
  }

  private startHealthChecker() {
    this.healthCheckInterval = setInterval(() => {
      // Check all remotes in parallel
      const healthChecks = Array.from(this.remotes.values()).map((remote) =>
        this.checkRemoteHealth(remote)
      );

      Promise.all(healthChecks).catch((err) => {
        console.error('Error in health checks:', err);
      });
    }, this.HEALTH_CHECK_INTERVAL);
  }

  destroy() {
    if (this.healthCheckInterval) {
      clearInterval(this.healthCheckInterval);
    }
  }
}
