import { RemoteRegistry } from './remote-registry.js';
import { Request, Response, NextFunction } from 'express';

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

    // Extract session ID from params
    const sessionId = req.params.sessionId;
    if (!sessionId) {
      return next();
    }

    // Check if this session belongs to a remote
    const remote = remoteRegistry.getRemoteBySessionId(sessionId);
    if (!remote) {
      // It's a local session, continue with normal processing
      return next();
    }

    // Build the target URL - keep the same path
    const targetUrl = `${remote.url}${req.originalUrl}`;

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

      // Set status code
      res.status(response.status);

      // Copy headers
      response.headers.forEach((value, key) => {
        if (key.toLowerCase() !== 'content-encoding') {
          res.setHeader(key, value);
        }
      });

      // Check content type to determine how to forward response
      const contentType = response.headers.get('content-type') || '';
      if (contentType.includes('application/octet-stream')) {
        // Binary data - forward as buffer
        const buffer = await response.arrayBuffer();
        res.send(Buffer.from(buffer));
      } else if (contentType.includes('text/event-stream')) {
        // SSE - forward as stream
        const reader = response.body?.getReader();
        if (reader) {
          const decoder = new TextDecoder();
          try {
            while (true) {
              const { done, value } = await reader.read();
              if (done) break;
              res.write(decoder.decode(value, { stream: true }));
            }
          } finally {
            reader.releaseLock();
          }
        }
        res.end();
      } else {
        // Text or JSON - forward as before
        const data = await response.text();
        try {
          const jsonData = JSON.parse(data);
          res.json(jsonData);
        } catch {
          res.send(data);
        }
      }
    } catch (error) {
      console.error(`Failed to proxy request to remote ${remote.name}:`, error);
      res.status(503).json({ error: 'Failed to communicate with remote server' });
    }
  };
}
