//go:build !linux && !darwin && !freebsd && !openbsd && !netbsd
// +build !linux,!darwin,!freebsd,!openbsd,!netbsd

package session

import (
	"fmt"
	"sync"
	"time"
)

// selectEventLoop implements EventLoop using select() as a fallback
type selectEventLoop struct {
	mu       sync.Mutex
	running  bool
	stopChan chan struct{}
	fds      map[int]*fdInfo
}

type fdInfo struct {
	fd     int
	events EventType
	data   interface{}
}

func newPlatformEventLoop() (EventLoop, error) {
	return &selectEventLoop{
		stopChan: make(chan struct{}),
		fds:      make(map[int]*fdInfo),
	}, nil
}

func (e *selectEventLoop) Add(fd int, events EventType, data interface{}) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	
	e.fds[fd] = &fdInfo{
		fd:     fd,
		events: events,
		data:   data,
	}
	
	return nil
}

func (e *selectEventLoop) Remove(fd int) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	
	delete(e.fds, fd)
	return nil
}

func (e *selectEventLoop) Modify(fd int, events EventType) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	
	if info, ok := e.fds[fd]; ok {
		info.events = events
	}
	
	return nil
}

func (e *selectEventLoop) Run(handler EventHandler) error {
	e.mu.Lock()
	if e.running {
		e.mu.Unlock()
		return fmt.Errorf("event loop already running")
	}
	e.running = true
	e.mu.Unlock()
	
	defer func() {
		e.mu.Lock()
		e.running = false
		e.mu.Unlock()
	}()
	
	for {
		select {
		case <-e.stopChan:
			return nil
		default:
		}
		
		// Use existing select-based polling as fallback
		// This is not as efficient as epoll/kqueue but works everywhere
		if err := e.RunOnce(handler, 10); err != nil {
			return err
		}
	}
}

func (e *selectEventLoop) RunOnce(handler EventHandler, timeoutMs int) error {
	e.mu.Lock()
	fdList := make([]int, 0, len(e.fds))
	for fd := range e.fds {
		fdList = append(fdList, fd)
	}
	e.mu.Unlock()
	
	if len(fdList) == 0 {
		time.Sleep(time.Duration(timeoutMs) * time.Millisecond)
		return nil
	}
	
	// Use the existing selectRead function
	ready, err := selectRead(fdList, time.Duration(timeoutMs)*time.Millisecond)
	if err != nil {
		return err
	}
	
	// Process ready file descriptors
	for _, fd := range ready {
		e.mu.Lock()
		info, ok := e.fds[fd]
		e.mu.Unlock()
		
		if ok {
			handler(Event{
				FD:     fd,
				Events: EventRead, // select only supports read events
				Data:   info.data,
			})
		}
	}
	
	return nil
}

func (e *selectEventLoop) Stop() error {
	close(e.stopChan)
	e.stopChan = make(chan struct{})
	return nil
}

func (e *selectEventLoop) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	
	if e.running {
		e.Stop()
		time.Sleep(10 * time.Millisecond)
	}
	
	return nil
}