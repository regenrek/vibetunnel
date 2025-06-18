package cmd

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/spf13/cobra"
	"github.com/vibetunnel/benchmark/client"
)

var loadCmd = &cobra.Command{
	Use:   "load",
	Short: "Benchmark concurrent user load",
	Long: `Test server performance under concurrent user load.
Simulates multiple users creating sessions and streaming simultaneously.`,
	RunE: runLoadBenchmark,
}

var (
	loadConcurrent int
	loadDuration   time.Duration
	loadRampUp     time.Duration
	loadOperations []string
)

func init() {
	rootCmd.AddCommand(loadCmd)
	
	loadCmd.Flags().IntVarP(&loadConcurrent, "concurrent", "c", 10, "Number of concurrent users")
	loadCmd.Flags().DurationVarP(&loadDuration, "duration", "d", 60*time.Second, "Load test duration")
	loadCmd.Flags().DurationVar(&loadRampUp, "ramp-up", 10*time.Second, "Ramp-up period to reach full load")
	loadCmd.Flags().StringSliceVar(&loadOperations, "operations", []string{"session", "stream"}, "Operations to test (session, stream, both)")
}

func runLoadBenchmark(cmd *cobra.Command, args []string) error {
	client := client.NewClient(hostname, port)
	
	fmt.Printf("🚀 VibeTunnel Concurrent Load Benchmark\n")
	fmt.Printf("Target: %s:%d\n", hostname, port)
	fmt.Printf("Concurrent Users: %d\n", loadConcurrent)
	fmt.Printf("Duration: %v\n", loadDuration)
	fmt.Printf("Ramp-up: %v\n", loadRampUp)
	fmt.Printf("Operations: %v\n\n", loadOperations)
	
	// Test connectivity
	fmt.Print("Testing connectivity... ")
	if err := client.Ping(); err != nil {
		return fmt.Errorf("server connectivity failed: %w", err)
	}
	fmt.Println("✅ Connected")
	
	return runConcurrentLoad(client)
}

type LoadStats struct {
	SessionsCreated   int64
	SessionsDeleted   int64
	StreamsStarted    int64
	EventsReceived    int64
	BytesReceived     int64
	Errors            int64
	TotalRequests     int64
	ResponseTimes     []time.Duration
	mu                sync.Mutex
}

func (s *LoadStats) AddResponse(duration time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ResponseTimes = append(s.ResponseTimes, duration)
}

func (s *LoadStats) GetStats() (int64, int64, int64, int64, int64, int64, int64, []time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.SessionsCreated, s.SessionsDeleted, s.StreamsStarted, s.EventsReceived, s.BytesReceived, s.Errors, s.TotalRequests, append([]time.Duration(nil), s.ResponseTimes...)
}

func runConcurrentLoad(c *client.VibeTunnelClient) error {
	fmt.Printf("\n📊 Starting Concurrent Load Test\n")
	
	stats := &LoadStats{}
	var wg sync.WaitGroup
	stopChan := make(chan struct{})
	
	// Start statistics reporter
	go reportProgress(stats, stopChan)
	
	startTime := time.Now()
	rampUpInterval := loadRampUp / time.Duration(loadConcurrent)
	
	// Ramp up concurrent users
	for i := 0; i < loadConcurrent; i++ {
		wg.Add(1)
		go simulateUser(c, i, stats, &wg, stopChan)
		
		// Ramp up delay
		if i < loadConcurrent-1 {
			time.Sleep(rampUpInterval)
		}
	}
	
	fmt.Printf("🔥 Full load reached with %d concurrent users\n", loadConcurrent)
	
	// Run for specified duration
	time.Sleep(loadDuration)
	
	// Signal all users to stop
	close(stopChan)
	
	// Wait for all users to finish
	fmt.Printf("🛑 Stopping load test, waiting for users to finish...\n")
	wg.Wait()
	
	totalDuration := time.Since(startTime)
	
	// Final statistics
	return printFinalStats(stats, totalDuration)
}

func simulateUser(c *client.VibeTunnelClient, userID int, stats *LoadStats, wg *sync.WaitGroup, stopChan chan struct{}) {
	defer wg.Done()
	
	userClient := client.NewClient(hostname, port)
	var sessions []string
	
	for {
		select {
		case <-stopChan:
			// Clean up sessions before exiting
			for _, sessionID := range sessions {
				if err := userClient.DeleteSession(sessionID); err == nil {
					atomic.AddInt64(&stats.SessionsDeleted, 1)
				}
			}
			return
			
		default:
			// Simulate user behavior
			if len(sessions) < 3 { // Keep max 3 sessions per user
				// Create new session
				if sessionID, err := createSessionWithTiming(userClient, userID, stats); err == nil {
					sessions = append(sessions, sessionID)
					
					// Sometimes start streaming on the session
					if len(sessions)%2 == 0 {
						go streamSession(userClient, sessionID, stats, stopChan)
					}
				}
			} else {
				// Sometimes delete oldest session
				if len(sessions) > 0 {
					sessionID := sessions[0]
					sessions = sessions[1:]
					
					if err := deleteSessionWithTiming(userClient, sessionID, stats); err != nil {
						atomic.AddInt64(&stats.Errors, 1)
					}
				}
			}
			
			// Random delay between operations
			time.Sleep(time.Duration(500+userID*100) * time.Millisecond)
		}
	}
}

func createSessionWithTiming(c *client.VibeTunnelClient, userID int, stats *LoadStats) (string, error) {
	start := time.Now()
	atomic.AddInt64(&stats.TotalRequests, 1)
	
	config := client.SessionConfig{
		Name:       fmt.Sprintf("load-user-%d-%d", userID, time.Now().Unix()),
		Command:    []string{"/bin/bash", "-i"},
		WorkingDir: "/tmp",
		Width:      80,
		Height:     24,
		Term:       "xterm-256color",
		Env:        map[string]string{"LOAD_TEST": "true"},
	}
	
	session, err := c.CreateSession(config)
	duration := time.Since(start)
	stats.AddResponse(duration)
	
	if err != nil {
		atomic.AddInt64(&stats.Errors, 1)
		return "", err
	}
	
	atomic.AddInt64(&stats.SessionsCreated, 1)
	return session.ID, nil
}

func deleteSessionWithTiming(c *client.VibeTunnelClient, sessionID string, stats *LoadStats) error {
	start := time.Now()
	atomic.AddInt64(&stats.TotalRequests, 1)
	
	err := c.DeleteSession(sessionID)
	duration := time.Since(start)
	stats.AddResponse(duration)
	
	if err != nil {
		atomic.AddInt64(&stats.Errors, 1)
		return err
	}
	
	atomic.AddInt64(&stats.SessionsDeleted, 1)
	return nil
}

func streamSession(c *client.VibeTunnelClient, sessionID string, stats *LoadStats, stopChan chan struct{}) {
	atomic.AddInt64(&stats.StreamsStarted, 1)
	
	stream, err := c.StreamSession(sessionID)
	if err != nil {
		atomic.AddInt64(&stats.Errors, 1)
		return
	}
	defer stream.Close()
	
	// Send some commands
	commands := []string{"echo 'Load test active'", "date", "pwd"}
	go func() {
		for i, cmd := range commands {
			select {
			case <-stopChan:
				return
			default:
				time.Sleep(time.Duration(i+1) * time.Second)
				c.SendInput(sessionID, cmd+"\n")
			}
		}
	}()
	
	// Monitor events
	for {
		select {
		case <-stopChan:
			return
		case event, ok := <-stream.Events:
			if !ok {
				return
			}
			atomic.AddInt64(&stats.EventsReceived, 1)
			if event.Event != nil {
				atomic.AddInt64(&stats.BytesReceived, int64(len(event.Event.Data)))
			}
		case <-stream.Errors:
			atomic.AddInt64(&stats.Errors, 1)
			return
		case <-time.After(30 * time.Second):
			// Stop streaming after 30 seconds
			return
		}
	}
}

func reportProgress(stats *LoadStats, stopChan chan struct{}) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	
	for {
		select {
		case <-stopChan:
			return
		case <-ticker.C:
			created, deleted, streams, events, bytes, errors, requests, _ := stats.GetStats()
			fmt.Printf("📊 Progress: Sessions %d/%d, Streams %d, Events %d, Bytes %dKB, Errors %d, Requests %d\n",
				created, deleted, streams, events, bytes/1024, errors, requests)
		}
	}
}

func printFinalStats(stats *LoadStats, totalDuration time.Duration) error {
	created, deleted, streams, events, bytes, errors, requests, responseTimes := stats.GetStats()
	
	fmt.Printf("\n📈 Load Test Results\n")
	fmt.Printf("Duration: %.2fs\n", totalDuration.Seconds())
	fmt.Printf("Concurrent Users: %d\n", loadConcurrent)
	
	fmt.Printf("\nOperations:\n")
	fmt.Printf("  Sessions Created: %d\n", created)
	fmt.Printf("  Sessions Deleted: %d\n", deleted)
	fmt.Printf("  Streams Started: %d\n", streams)
	fmt.Printf("  Events Received: %d\n", events)
	fmt.Printf("  Data Transferred: %.2f KB\n", float64(bytes)/1024)
	fmt.Printf("  Total Requests: %d\n", requests)
	fmt.Printf("  Errors: %d\n", errors)
	
	if len(responseTimes) > 0 {
		var total time.Duration
		min := responseTimes[0]
		max := responseTimes[0]
		
		for _, rt := range responseTimes {
			total += rt
			if rt < min {
				min = rt
			}
			if rt > max {
				max = rt
			}
		}
		
		avg := total / time.Duration(len(responseTimes))
		
		fmt.Printf("\nResponse Times:\n")
		fmt.Printf("  Average: %.2fms\n", float64(avg.Nanoseconds())/1e6)
		fmt.Printf("  Min: %.2fms\n", float64(min.Nanoseconds())/1e6)
		fmt.Printf("  Max: %.2fms\n", float64(max.Nanoseconds())/1e6)
	}
	
	fmt.Printf("\nThroughput:\n")
	fmt.Printf("  Requests/sec: %.1f\n", float64(requests)/totalDuration.Seconds())
	fmt.Printf("  Events/sec: %.1f\n", float64(events)/totalDuration.Seconds())
	fmt.Printf("  KB/sec: %.2f\n", float64(bytes)/1024/totalDuration.Seconds())
	
	successRate := float64(requests-errors) / float64(requests) * 100
	fmt.Printf("  Success Rate: %.1f%%\n", successRate)
	
	if errors > 0 {
		fmt.Printf("\n⚠️  %d errors encountered during load test\n", errors)
	} else {
		fmt.Printf("\n✅ Load test completed without errors\n")
	}
	
	return nil
}