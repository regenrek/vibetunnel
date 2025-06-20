package cmd

import (
	"fmt"
	"time"

	"github.com/spf13/cobra"
	"github.com/vibetunnel/benchmark/client"
)

var sessionCmd = &cobra.Command{
	Use:   "session",
	Short: "Benchmark session management operations",
	Long: `Test session creation, retrieval, and deletion performance.
Measures latency and success rates for session lifecycle operations.`,
	RunE: runSessionBenchmark,
}

var (
	sessionCount  int
	sessionShell  string
	sessionCwd    string
	sessionWidth  int
	sessionHeight int
)

func init() {
	rootCmd.AddCommand(sessionCmd)

	sessionCmd.Flags().IntVarP(&sessionCount, "count", "c", 10, "Number of sessions to create/test")
	sessionCmd.Flags().StringVar(&sessionShell, "shell", "/bin/bash", "Shell to use for sessions")
	sessionCmd.Flags().StringVar(&sessionCwd, "cwd", "/tmp", "Working directory for sessions")
	sessionCmd.Flags().IntVar(&sessionWidth, "width", 80, "Terminal width")
	sessionCmd.Flags().IntVar(&sessionHeight, "height", 24, "Terminal height")
}

func runSessionBenchmark(cmd *cobra.Command, args []string) error {
	client := client.NewClient(hostname, port)

	fmt.Printf("🚀 VibeTunnel Session Benchmark\n")
	fmt.Printf("Target: %s:%d\n", hostname, port)
	fmt.Printf("Sessions: %d\n\n", sessionCount)

	// Test connectivity
	fmt.Print("Testing connectivity... ")
	if err := client.Ping(); err != nil {
		return fmt.Errorf("server connectivity failed: %w", err)
	}
	fmt.Println("✅ Connected")

	// Run session lifecycle benchmark
	return benchmarkSessionLifecycle(client)
}

func benchmarkSessionLifecycle(c *client.VibeTunnelClient) error {
	fmt.Printf("\n📊 Session Lifecycle Benchmark\n")
	fmt.Printf("Creating %d sessions...\n", sessionCount)

	var sessionIDs []string
	createLatencies := make([]time.Duration, 0, sessionCount)
	getLatencies := make([]time.Duration, 0, sessionCount)
	deleteLatencies := make([]time.Duration, 0, sessionCount)

	startTime := time.Now()

	// 1. Create sessions
	for i := 0; i < sessionCount; i++ {
		config := client.SessionConfig{
			Name:       fmt.Sprintf("bench-session-%d", i),
			Command:    []string{sessionShell, "-i"},
			WorkingDir: sessionCwd,
			Width:      sessionWidth,
			Height:     sessionHeight,
			Term:       "xterm-256color",
			Env:        map[string]string{"BENCH": "true"},
		}

		createStart := time.Now()
		session, err := c.CreateSession(config)
		createDuration := time.Since(createStart)

		if err != nil {
			return fmt.Errorf("failed to create session %d: %w", i, err)
		}

		sessionIDs = append(sessionIDs, session.ID)
		createLatencies = append(createLatencies, createDuration)

		if verbose {
			fmt.Printf("  Session %d created: %s (%.2fms)\n", i+1, session.ID, float64(createDuration.Nanoseconds())/1e6)
		}
	}

	createTotalTime := time.Since(startTime)
	fmt.Printf("✅ Created %d sessions in %.2fs\n", sessionCount, createTotalTime.Seconds())

	// 2. Get session details
	fmt.Printf("Retrieving session details...\n")
	getStart := time.Now()
	for i, sessionID := range sessionIDs {
		start := time.Now()
		session, err := c.GetSession(sessionID)
		duration := time.Since(start)

		if err != nil {
			return fmt.Errorf("failed to get session %s: %w", sessionID, err)
		}

		getLatencies = append(getLatencies, duration)

		if verbose {
			fmt.Printf("  Session %d retrieved: %s status=%s (%.2fms)\n",
				i+1, session.ID, session.Status, float64(duration.Nanoseconds())/1e6)
		}
	}

	getTotalTime := time.Since(getStart)
	fmt.Printf("✅ Retrieved %d sessions in %.2fs\n", sessionCount, getTotalTime.Seconds())

	// 3. List all sessions
	fmt.Printf("Listing all sessions...\n")
	listStart := time.Now()
	sessions, err := c.ListSessions()
	listDuration := time.Since(listStart)

	if err != nil {
		return fmt.Errorf("failed to list sessions: %w", err)
	}

	fmt.Printf("✅ Listed %d sessions in %.2fms\n", len(sessions), float64(listDuration.Nanoseconds())/1e6)

	// 4. Delete sessions
	fmt.Printf("Deleting sessions...\n")
	deleteStart := time.Now()
	for i, sessionID := range sessionIDs {
		start := time.Now()
		err := c.DeleteSession(sessionID)
		duration := time.Since(start)

		if err != nil {
			return fmt.Errorf("failed to delete session %s: %w", sessionID, err)
		}

		deleteLatencies = append(deleteLatencies, duration)

		if verbose {
			fmt.Printf("  Session %d deleted: %s (%.2fms)\n",
				i+1, sessionID, float64(duration.Nanoseconds())/1e6)
		}
	}

	deleteTotalTime := time.Since(deleteStart)
	fmt.Printf("✅ Deleted %d sessions in %.2fs\n", sessionCount, deleteTotalTime.Seconds())

	// Calculate and display statistics
	fmt.Printf("\n📈 Performance Statistics\n")
	fmt.Printf("Overall Duration: %.2fs\n", time.Since(startTime).Seconds())
	fmt.Printf("\nOperation Latencies (avg/min/max in ms):\n")

	printLatencyStats("Create", createLatencies)
	printLatencyStats("Get", getLatencies)
	printLatencyStats("Delete", deleteLatencies)

	fmt.Printf("\nThroughput:\n")
	fmt.Printf("  Create: %.1f sessions/sec\n", float64(sessionCount)/createTotalTime.Seconds())
	fmt.Printf("  Get:    %.1f requests/sec\n", float64(sessionCount)/getTotalTime.Seconds())
	fmt.Printf("  Delete: %.1f sessions/sec\n", float64(sessionCount)/deleteTotalTime.Seconds())

	return nil
}

func printLatencyStats(operation string, latencies []time.Duration) {
	if len(latencies) == 0 {
		return
	}

	var total time.Duration
	min := latencies[0]
	max := latencies[0]

	for _, latency := range latencies {
		total += latency
		if latency < min {
			min = latency
		}
		if latency > max {
			max = latency
		}
	}

	avg := total / time.Duration(len(latencies))

	fmt.Printf("  %-6s: %6.2f / %6.2f / %6.2f\n",
		operation,
		float64(avg.Nanoseconds())/1e6,
		float64(min.Nanoseconds())/1e6,
		float64(max.Nanoseconds())/1e6)
}
