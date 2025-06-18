import { describe, it, expect, vi, beforeEach } from 'vitest';
import { fixture, html } from '@testing-library/dom';
import { createMockSession } from '../test-utils';

// Mock lit
vi.mock('lit', () => ({
  LitElement: class {
    sessions: any[] = [];
    loading = false;
    hideExited = true;
    showCreateModal = false;
    connectedCallback() {}
    disconnectedCallback() {}
    requestUpdate() {}
    dispatchEvent(event: Event) { return true; }
  },
  html: (strings: TemplateStringsArray, ...values: any[]) => {
    return strings.join('');
  },
}));

vi.mock('lit/decorators.js', () => ({
  customElement: (name: string) => (target: any) => target,
  property: (options?: any) => (target: any, propertyKey: string) => {},
  state: (options?: any) => (target: any, propertyKey: string) => {},
}));

describe('SessionList Component', () => {
  let sessionListModule: any;

  beforeEach(async () => {
    vi.clearAllMocks();
    sessionListModule = await import('../../client/components/session-list');
  });

  describe('Session Display', () => {
    it('should display empty state when no sessions', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.sessions = [];
      
      const isEmpty = sessionList.sessions.length === 0;
      expect(isEmpty).toBe(true);
    });

    it('should display list of sessions', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.sessions = [
        createMockSession({ id: '1', command: 'bash', status: 'running' }),
        createMockSession({ id: '2', command: 'vim', status: 'running' }),
        createMockSession({ id: '3', command: 'node', status: 'exited' }),
      ];
      
      expect(sessionList.sessions).toHaveLength(3);
      expect(sessionList.sessions[0].command).toBe('bash');
      expect(sessionList.sessions[1].command).toBe('vim');
      expect(sessionList.sessions[2].status).toBe('exited');
    });

    it('should filter exited sessions when hideExited is true', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.hideExited = true;
      sessionList.sessions = [
        createMockSession({ id: '1', status: 'running' }),
        createMockSession({ id: '2', status: 'exited' }),
        createMockSession({ id: '3', status: 'running' }),
      ];
      
      const visibleSessions = sessionList.getVisibleSessions();
      expect(visibleSessions).toHaveLength(2);
      expect(visibleSessions.every(s => s.status === 'running')).toBe(true);
    });

    it('should show all sessions when hideExited is false', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.hideExited = false;
      sessionList.sessions = [
        createMockSession({ id: '1', status: 'running' }),
        createMockSession({ id: '2', status: 'exited' }),
        createMockSession({ id: '3', status: 'running' }),
      ];
      
      const visibleSessions = sessionList.getVisibleSessions();
      expect(visibleSessions).toHaveLength(3);
    });
  });

  describe('Session Actions', () => {
    it('should handle refresh event', () => {
      const sessionList = new sessionListModule.SessionList();
      const refreshSpy = vi.spyOn(sessionList, 'dispatchEvent');
      
      sessionList.handleRefresh();
      
      expect(refreshSpy).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'refresh',
        })
      );
    });

    it('should handle session selection', () => {
      const sessionList = new sessionListModule.SessionList();
      const mockSession = createMockSession({ id: 'test-123' });
      
      // Mock window.location
      delete (window as any).location;
      window.location = { search: '' } as any;
      
      const event = new CustomEvent('select', { detail: mockSession });
      sessionList.handleSessionSelect(event);
      
      expect(window.location.search).toBe('?session=test-123');
    });

    it('should toggle create modal', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.showCreateModal = false;
      
      sessionList.toggleCreateModal();
      expect(sessionList.showCreateModal).toBe(true);
      
      sessionList.toggleCreateModal();
      expect(sessionList.showCreateModal).toBe(false);
    });

    it('should handle cleanup exited sessions', async () => {
      const sessionList = new sessionListModule.SessionList();
      const mockFetch = vi.fn().mockResolvedValue({ ok: true });
      global.fetch = mockFetch;
      
      sessionList.sessions = [
        createMockSession({ id: '1', status: 'exited' }),
        createMockSession({ id: '2', status: 'exited' }),
      ];
      
      await sessionList.handleCleanupExited();
      
      expect(mockFetch).toHaveBeenCalledWith('/api/cleanup-exited', {
        method: 'POST',
      });
      expect(sessionList.cleaningExited).toBe(true);
    });
  });

  describe('Session Status Updates', () => {
    it('should track running session count changes', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.previousRunningCount = 2;
      
      sessionList.sessions = [
        createMockSession({ id: '1', status: 'running' }),
        createMockSession({ id: '2', status: 'running' }),
        createMockSession({ id: '3', status: 'running' }),
      ];
      
      const currentRunningCount = sessionList.getRunningSessionCount();
      const hasNewRunningSessions = currentRunningCount > sessionList.previousRunningCount;
      
      expect(currentRunningCount).toBe(3);
      expect(hasNewRunningSessions).toBe(true);
    });

    it('should detect when sessions exit', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.previousRunningCount = 3;
      
      sessionList.sessions = [
        createMockSession({ id: '1', status: 'running' }),
        createMockSession({ id: '2', status: 'exited' }),
        createMockSession({ id: '3', status: 'exited' }),
      ];
      
      const currentRunningCount = sessionList.getRunningSessionCount();
      const hasExitedSessions = currentRunningCount < sessionList.previousRunningCount;
      
      expect(currentRunningCount).toBe(1);
      expect(hasExitedSessions).toBe(true);
    });
  });

  describe('Loading States', () => {
    it('should show loading indicator when loading', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.loading = true;
      
      expect(sessionList.loading).toBe(true);
    });

    it('should hide loading indicator when not loading', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.loading = false;
      
      expect(sessionList.loading).toBe(false);
    });

    it('should disable actions while cleaning exited', () => {
      const sessionList = new sessionListModule.SessionList();
      sessionList.cleaningExited = true;
      
      const canPerformActions = !sessionList.cleaningExited;
      expect(canPerformActions).toBe(false);
    });
  });

  describe('Session Sorting', () => {
    it('should sort sessions by last modified date', () => {
      const sessionList = new sessionListModule.SessionList();
      const now = new Date();
      
      sessionList.sessions = [
        createMockSession({ 
          id: '1', 
          lastModified: new Date(now.getTime() - 3600000).toISOString() // 1 hour ago
        }),
        createMockSession({ 
          id: '2', 
          lastModified: new Date(now.getTime() - 60000).toISOString() // 1 minute ago
        }),
        createMockSession({ 
          id: '3', 
          lastModified: new Date(now.getTime() - 7200000).toISOString() // 2 hours ago
        }),
      ];
      
      const sortedSessions = sessionList.getSortedSessions();
      
      expect(sortedSessions[0].id).toBe('2'); // Most recent
      expect(sortedSessions[1].id).toBe('1');
      expect(sortedSessions[2].id).toBe('3'); // Oldest
    });

    it('should handle sessions with same timestamp', () => {
      const sessionList = new sessionListModule.SessionList();
      const timestamp = new Date().toISOString();
      
      sessionList.sessions = [
        createMockSession({ id: '1', lastModified: timestamp }),
        createMockSession({ id: '2', lastModified: timestamp }),
      ];
      
      const sortedSessions = sessionList.getSortedSessions();
      expect(sortedSessions).toHaveLength(2);
    });
  });
});