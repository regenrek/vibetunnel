import { RemoteRegistry } from './remote-registry.js';
import { Request, Response, NextFunction } from 'express';

export interface SessionIdInfo {
  remoteId: string;
  sessionId: string;
  isLocal: boolean;
}

/**
 * Parse a potentially namespaced session ID
 * Format: "remoteId:sessionId" or just "sessionId" for local
 */
export function parseSessionId(namespacedId: string): SessionIdInfo {
  const parts = namespacedId.split(':');

  if (parts.length === 2) {
    return {
      remoteId: parts[0],
      sessionId: parts[1],
      isLocal: false,
    };
  }

  return {
    remoteId: 'local',
    sessionId: namespacedId,
    isLocal: true,
  };
}

/**
 * Create a namespaced session ID
 */
export function createNamespacedId(remoteId: string, sessionId: string): string {
  if (remoteId === 'local') {
    return sessionId;
  }
  return `${remoteId}:${sessionId}`;
}

/**
 * Proxy middleware for forwarding session operations to remote servers
 */
export function createSessionProxyMiddleware(
  isHQMode: boolean,
  remoteRegistry: RemoteRegistry | null
) {
  return async (req: Request, res: Response, next: NextFunction) => {
    // Only proxy in HQ mode
    if (!isHQMode || !remoteRegistry) {
      return next();
    }

    // Extract session ID from various possible locations
    const sessionId = req.params.sessionId || (req.query.sessionId as string);
    if (!sessionId) {
      return next();
    }

    const { remoteId, sessionId: actualSessionId, isLocal } = parseSessionId(sessionId);

    // If it's a local session, continue with normal processing
    if (isLocal) {
      // Replace the session ID with the actual ID for local processing
      if (req.params.sessionId) {
        req.params.sessionId = actualSessionId;
      }
      return next();
    }

    // Get the remote server
    const remote = remoteRegistry.getRemote(remoteId);
    if (!remote) {
      return res.status(404).json({ error: 'Remote server not found' });
    }

    if (remote.status !== 'online') {
      return res.status(503).json({ error: 'Remote server is offline' });
    }

    // Build the target URL
    const targetPath = req.originalUrl.replace(sessionId, actualSessionId);
    const targetUrl = `${remote.url}${targetPath}`;

    try {
      // Forward the request
      const headers: Record<string, string> = {
        'Content-Type': req.get('Content-Type') || 'application/json',
      };

      // Use the remote's token for authentication
      headers['Authorization'] = `Bearer ${remote.token}`;

      const response = await fetch(targetUrl, {
        method: req.method,
        headers,
        body: req.method !== 'GET' && req.method !== 'HEAD' ? JSON.stringify(req.body) : undefined,
        signal: AbortSignal.timeout(30000), // 30 second timeout
      });

      // Forward the response
      const data = await response.text();
      res.status(response.status);

      // Copy headers
      response.headers.forEach((value, key) => {
        if (key.toLowerCase() !== 'content-encoding') {
          res.setHeader(key, value);
        }
      });

      // Send response
      try {
        // Try to parse as JSON
        const jsonData = JSON.parse(data);
        res.json(jsonData);
      } catch {
        // Send as text if not JSON
        res.send(data);
      }
    } catch (error) {
      console.error(`Failed to proxy request to remote ${remote.name}:`, error);
      res.status(503).json({ error: 'Failed to communicate with remote server' });
    }
  };
}
