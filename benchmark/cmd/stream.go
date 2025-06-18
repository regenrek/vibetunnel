package cmd

import (
	"fmt"
	"sync"
	"time"

	"github.com/spf13/cobra"
	"github.com/vibetunnel/benchmark/client"
)

var streamCmd = &cobra.Command{
	Use:   "stream",
	Short: "Benchmark SSE streaming performance",
	Long: `Test Server-Sent Events (SSE) streaming latency and throughput.
Measures event delivery times and handles concurrent streams.`,
	RunE: runStreamBenchmark,
}

var (
	streamSessions    int
	streamDuration    time.Duration
	streamCommands    []string
	streamConcurrent  bool
	streamInputDelay  time.Duration
)

func init() {
	rootCmd.AddCommand(streamCmd)
	
	streamCmd.Flags().IntVarP(&streamSessions, "sessions", "s", 3, "Number of sessions to stream")
	streamCmd.Flags().DurationVarP(&streamDuration, "duration", "d", 30*time.Second, "Benchmark duration")
	streamCmd.Flags().StringSliceVar(&streamCommands, "commands", []string{"echo hello", "ls -la", "date"}, "Commands to execute")
	streamCmd.Flags().BoolVar(&streamConcurrent, "concurrent", true, "Run streams concurrently")
	streamCmd.Flags().DurationVar(&streamInputDelay, "input-delay", 2*time.Second, "Delay between command inputs")
}

func runStreamBenchmark(cmd *cobra.Command, args []string) error {
	client := client.NewClient(hostname, port)
	
	fmt.Printf("🚀 VibeTunnel SSE Stream Benchmark\n")
	fmt.Printf("Target: %s:%d\n", hostname, port)
	fmt.Printf("Sessions: %d\n", streamSessions)
	fmt.Printf("Duration: %v\n", streamDuration)
	fmt.Printf("Concurrent: %v\n\n", streamConcurrent)
	
	// Test connectivity
	fmt.Print("Testing connectivity... ")
	if err := client.Ping(); err != nil {
		return fmt.Errorf("server connectivity failed: %w", err)
	}
	fmt.Println("✅ Connected")
	
	if streamConcurrent {
		return benchmarkConcurrentStreams(client)
	} else {
		return benchmarkSequentialStreams(client)
	}
}

func benchmarkConcurrentStreams(c *client.VibeTunnelClient) error {
	fmt.Printf("\n📊 Concurrent SSE Stream Benchmark\n")
	
	var wg sync.WaitGroup
	results := make(chan *StreamResult, streamSessions)
	
	startTime := time.Now()
	
	// Start concurrent stream benchmarks
	for i := 0; i < streamSessions; i++ {
		wg.Add(1)
		go func(sessionNum int) {
			defer wg.Done()
			result := benchmarkSingleStream(c, sessionNum)
			results <- result
		}(i)
	}
	
	// Wait for all streams to complete
	wg.Wait()
	close(results)
	
	totalDuration := time.Since(startTime)
	
	// Collect and analyze results
	var allResults []*StreamResult
	for result := range results {
		allResults = append(allResults, result)
	}
	
	return analyzeStreamResults(allResults, totalDuration)
}

func benchmarkSequentialStreams(c *client.VibeTunnelClient) error {
	fmt.Printf("\n📊 Sequential SSE Stream Benchmark\n")
	
	var allResults []*StreamResult
	startTime := time.Now()
	
	for i := 0; i < streamSessions; i++ {
		result := benchmarkSingleStream(c, i)
		allResults = append(allResults, result)
	}
	
	totalDuration := time.Since(startTime)
	return analyzeStreamResults(allResults, totalDuration)
}

type StreamResult struct {
	SessionNum      int
	SessionID       string
	EventsReceived  int
	BytesReceived   int64
	FirstEventTime  time.Duration
	LastEventTime   time.Duration
	TotalDuration   time.Duration
	Errors          []error
	EventLatencies  []time.Duration
}

func benchmarkSingleStream(c *client.VibeTunnelClient, sessionNum int) *StreamResult {
	result := &StreamResult{
		SessionNum:     sessionNum,
		EventLatencies: make([]time.Duration, 0),
	}
	
	startTime := time.Now()
	
	// Create session
	config := client.SessionConfig{
		Name:       fmt.Sprintf("stream-bench-%d", sessionNum),
		Command:    []string{"/bin/bash", "-i"},
		WorkingDir: "/tmp",
		Width:      80,
		Height:     24,
		Term:       "xterm-256color",
		Env:        map[string]string{"BENCH": "true"},
	}
	
	session, err := c.CreateSession(config)
	if err != nil {
		result.Errors = append(result.Errors, fmt.Errorf("create session: %w", err))
		return result
	}
	
	result.SessionID = session.ID
	defer c.DeleteSession(session.ID)
	
	if verbose {
		fmt.Printf("  Session %d: Created %s\n", sessionNum+1, session.ID)
	}
	
	// Start streaming
	stream, err := c.StreamSession(session.ID)
	if err != nil {
		result.Errors = append(result.Errors, fmt.Errorf("start stream: %w", err))
		return result
	}
	defer stream.Close()
	
	// Send commands and monitor stream
	go func() {
		time.Sleep(500 * time.Millisecond) // Wait for stream to establish
		
		for i, command := range streamCommands {
			if err := c.SendInput(session.ID, command+"\n"); err != nil {
				result.Errors = append(result.Errors, fmt.Errorf("send command %d: %w", i, err))
				continue
			}
			
			if verbose {
				fmt.Printf("  Session %d: Sent command '%s'\n", sessionNum+1, command)
			}
			
			if i < len(streamCommands)-1 {
				time.Sleep(streamInputDelay)
			}
		}
	}()
	
	// Monitor events
	timeout := time.NewTimer(streamDuration)
	defer timeout.Stop()
	
	for {
		select {
		case event, ok := <-stream.Events:
			if !ok {
				result.TotalDuration = time.Since(startTime)
				return result
			}
			
			eventTime := time.Since(startTime)
			result.EventsReceived++
			
			if result.EventsReceived == 1 {
				result.FirstEventTime = eventTime
			}
			result.LastEventTime = eventTime
			
			// Calculate event data size
			if event.Event != nil {
				result.BytesReceived += int64(len(event.Event.Data))
			}
			
			if verbose && result.EventsReceived <= 5 {
				fmt.Printf("  Session %d: Event %d received at +%.1fms\n", 
					sessionNum+1, result.EventsReceived, float64(eventTime.Nanoseconds())/1e6)
			}
			
		case err, ok := <-stream.Errors:
			if !ok {
				result.TotalDuration = time.Since(startTime)
				return result
			}
			result.Errors = append(result.Errors, err)
			
		case <-timeout.C:
			result.TotalDuration = time.Since(startTime)
			return result
		}
	}
}

func analyzeStreamResults(results []*StreamResult, totalDuration time.Duration) error {
	fmt.Printf("\n📈 Stream Performance Statistics\n")
	fmt.Printf("Total Duration: %.2fs\n", totalDuration.Seconds())
	
	var (
		totalEvents     int
		totalBytes      int64
		totalErrors     int
		totalSessions   int
		avgFirstEvent   time.Duration
		avgLastEvent    time.Duration
	)
	
	successfulSessions := 0
	
	for _, result := range results {
		totalSessions++
		totalEvents += result.EventsReceived
		totalBytes += result.BytesReceived
		totalErrors += len(result.Errors)
		
		if len(result.Errors) == 0 && result.EventsReceived > 0 {
			successfulSessions++
			avgFirstEvent += result.FirstEventTime
			avgLastEvent += result.LastEventTime
		}
		
		if verbose {
			fmt.Printf("\nSession %d (%s):\n", result.SessionNum+1, result.SessionID)
			fmt.Printf("  Events: %d\n", result.EventsReceived)
			fmt.Printf("  Bytes: %d\n", result.BytesReceived)
			fmt.Printf("  First Event: %.1fms\n", float64(result.FirstEventTime.Nanoseconds())/1e6)
			fmt.Printf("  Last Event: %.1fms\n", float64(result.LastEventTime.Nanoseconds())/1e6)
			fmt.Printf("  Duration: %.2fs\n", result.TotalDuration.Seconds())
			fmt.Printf("  Errors: %d\n", len(result.Errors))
			
			for i, err := range result.Errors {
				fmt.Printf("    Error %d: %v\n", i+1, err)
			}
		}
	}
	
	if successfulSessions > 0 {
		avgFirstEvent /= time.Duration(successfulSessions)
		avgLastEvent /= time.Duration(successfulSessions)
	}
	
	fmt.Printf("\nOverall Results:\n")
	fmt.Printf("  Sessions: %d total, %d successful\n", totalSessions, successfulSessions)
	fmt.Printf("  Events: %d total\n", totalEvents)
	fmt.Printf("  Data: %.2f KB\n", float64(totalBytes)/1024)
	fmt.Printf("  Errors: %d\n", totalErrors)
	
	if successfulSessions > 0 {
		fmt.Printf("\nLatency (average):\n")
		fmt.Printf("  First Event: %.1fms\n", float64(avgFirstEvent.Nanoseconds())/1e6)
		fmt.Printf("  Last Event: %.1fms\n", float64(avgLastEvent.Nanoseconds())/1e6)
		
		fmt.Printf("\nThroughput:\n")
		fmt.Printf("  Events/sec: %.1f\n", float64(totalEvents)/totalDuration.Seconds())
		fmt.Printf("  KB/sec: %.2f\n", float64(totalBytes)/1024/totalDuration.Seconds())
		fmt.Printf("  Success Rate: %.1f%%\n", float64(successfulSessions)/float64(totalSessions)*100)
	}
	
	if totalErrors > 0 {
		fmt.Printf("\n⚠️  %d errors encountered during benchmark\n", totalErrors)
	} else {
		fmt.Printf("\n✅ All streams completed successfully\n")
	}
	
	return nil
}