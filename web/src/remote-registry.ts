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
  private heartbeatInterval: NodeJS.Timeout | null = null;
  private readonly HEARTBEAT_TIMEOUT = 30000; // 30 seconds

  constructor() {
    this.startHeartbeatChecker();
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

  updateHeartbeat(remoteId: string, sessionCount: number): boolean {
    const remote = this.remotes.get(remoteId);
    if (remote) {
      remote.lastHeartbeat = new Date();
      remote.sessionCount = sessionCount;
      remote.status = 'online';
      return true;
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

  private startHeartbeatChecker() {
    this.heartbeatInterval = setInterval(() => {
      const now = Date.now();

      for (const remote of this.remotes.values()) {
        const timeSinceLastHeartbeat = now - remote.lastHeartbeat.getTime();

        if (timeSinceLastHeartbeat > this.HEARTBEAT_TIMEOUT && remote.status === 'online') {
          remote.status = 'offline';
          console.log(`Remote went offline: ${remote.name} (${remote.id})`);
        }
      }
    }, 10000); // Check every 10 seconds
  }

  destroy() {
    if (this.heartbeatInterval) {
      clearInterval(this.heartbeatInterval);
    }
  }
}
