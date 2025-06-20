package cmd

import (
	"fmt"
	"time"

	"github.com/spf13/cobra"
	"github.com/vibetunnel/benchmark/client"
)

var compareCmd = &cobra.Command{
	Use:   "compare",
	Short: "Compare Go vs Rust VibeTunnel server performance",
	Long: `Run benchmarks against both Go and Rust servers and compare results.
Tests session management, streaming, and provides performance comparison.`,
	RunE: runCompareBenchmark,
}

var (
	goPort   int
	rustPort int
	runs     int
	testType string
)

func init() {
	rootCmd.AddCommand(compareCmd)

	compareCmd.Flags().IntVar(&goPort, "go-port", 4031, "Go server port")
	compareCmd.Flags().IntVar(&rustPort, "rust-port", 4044, "Rust server port")
	compareCmd.Flags().IntVarP(&runs, "runs", "r", 10, "Number of test runs (10-1000)")
	compareCmd.Flags().StringVarP(&testType, "test", "t", "session", "Test type: session, stream, or both")
}

type BenchmarkResult struct {
	ServerType    string
	TestType      string
	Runs          int
	TotalDuration time.Duration
	AvgLatency    time.Duration
	MinLatency    time.Duration
	MaxLatency    time.Duration
	Throughput    float64
	SuccessRate   float64
	ErrorCount    int
}

func runCompareBenchmark(cmd *cobra.Command, args []string) error {
	if runs < 10 || runs > 1000 {
		return fmt.Errorf("runs must be between 10 and 1000")
	}

	fmt.Printf("🚀 VibeTunnel Server Comparison Benchmark\n")
	fmt.Printf("==========================================\n")
	fmt.Printf("Runs: %d | Test: %s\n", runs, testType)
	fmt.Printf("Go Server: %s:%d\n", hostname, goPort)
	fmt.Printf("Rust Server: %s:%d\n\n", hostname, rustPort)

	var goResults, rustResults []BenchmarkResult

	// Test Go server
	fmt.Printf("📊 Testing Go Server (port %d)\n", goPort)
	fmt.Printf("-----------------------------\n")
	goClient := client.NewClient(hostname, goPort)

	if err := goClient.Ping(); err != nil {
		fmt.Printf("❌ Go server not accessible: %v\n\n", err)
	} else {
		if testType == "session" || testType == "both" {
			result, err := runSessionBenchmarkRuns(goClient, "Go", runs)
			if err != nil {
				fmt.Printf("❌ Go session benchmark failed: %v\n", err)
			} else {
				goResults = append(goResults, result)
			}
		}

		if testType == "stream" || testType == "both" {
			result, err := runStreamBenchmarkRuns(goClient, "Go", runs)
			if err != nil {
				fmt.Printf("❌ Go stream benchmark failed: %v\n", err)
			} else {
				goResults = append(goResults, result)
			}
		}
	}

	fmt.Printf("\n📊 Testing Rust Server (port %d)\n", rustPort)
	fmt.Printf("-------------------------------\n")
	rustClient := client.NewClient(hostname, rustPort)

	if err := rustClient.Ping(); err != nil {
		fmt.Printf("❌ Rust server not accessible: %v\n\n", err)
	} else {
		if testType == "session" || testType == "both" {
			result, err := runSessionBenchmarkRuns(rustClient, "Rust", runs)
			if err != nil {
				fmt.Printf("❌ Rust session benchmark failed: %v\n", err)
			} else {
				rustResults = append(rustResults, result)
			}
		}

		if testType == "stream" || testType == "both" {
			result, err := runStreamBenchmarkRuns(rustClient, "Rust", runs)
			if err != nil {
				fmt.Printf("❌ Rust stream benchmark failed: %v\n", err)
			} else {
				rustResults = append(rustResults, result)
			}
		}
	}

	// Display comparison
	fmt.Printf("\n🏁 Performance Comparison\n")
	fmt.Printf("========================\n")
	displayComparison(goResults, rustResults)

	return nil
}

func runSessionBenchmarkRuns(c *client.VibeTunnelClient, serverType string, numRuns int) (BenchmarkResult, error) {
	fmt.Printf("Running %d session lifecycle tests...\n", numRuns)

	var totalLatencies []time.Duration
	var errors int
	startTime := time.Now()

	for run := 1; run <= numRuns; run++ {
		if verbose {
			fmt.Printf("  Run %d/%d... ", run, numRuns)
		}

		runStart := time.Now()

		// Create session using unified API format
		config := client.SessionConfig{
			Name:       fmt.Sprintf("bench-run-%d", run),
			Command:    []string{"/bin/bash", "-i"},
			WorkingDir: "/tmp",
			Width:      80,
			Height:     24,
			Term:       "xterm-256color",
		}

		session, err := c.CreateSession(config)
		if err != nil {
			errors++
			if verbose {
				fmt.Printf("❌ Create failed: %v\n", err)
			}
			continue
		}

		// Get session
		_, err = c.GetSession(session.ID)
		if err != nil {
			errors++
			if verbose {
				fmt.Printf("❌ Get failed: %v\n", err)
			}
			// Still try to delete
		}

		// Delete session
		err = c.DeleteSession(session.ID)
		if err != nil {
			errors++
			if verbose {
				fmt.Printf("❌ Delete failed: %v\n", err)
			}
		}

		runDuration := time.Since(runStart)
		totalLatencies = append(totalLatencies, runDuration)

		if verbose {
			fmt.Printf("✅ %.2fms\n", float64(runDuration.Nanoseconds())/1e6)
		}
	}

	totalDuration := time.Since(startTime)

	// Calculate statistics
	var min, max, total time.Duration
	if len(totalLatencies) > 0 {
		min = totalLatencies[0]
		max = totalLatencies[0]
		for _, lat := range totalLatencies {
			total += lat
			if lat < min {
				min = lat
			}
			if lat > max {
				max = lat
			}
		}
	}

	var avgLatency time.Duration
	if len(totalLatencies) > 0 {
		avgLatency = total / time.Duration(len(totalLatencies))
	}

	successRate := float64(len(totalLatencies)) / float64(numRuns) * 100
	throughput := float64(len(totalLatencies)) / totalDuration.Seconds()

	fmt.Printf("✅ Completed %d/%d runs (%.1f%% success rate)\n", len(totalLatencies), numRuns, successRate)

	return BenchmarkResult{
		ServerType:    serverType,
		TestType:      "session",
		Runs:          numRuns,
		TotalDuration: totalDuration,
		AvgLatency:    avgLatency,
		MinLatency:    min,
		MaxLatency:    max,
		Throughput:    throughput,
		SuccessRate:   successRate,
		ErrorCount:    errors,
	}, nil
}

func runStreamBenchmarkRuns(c *client.VibeTunnelClient, serverType string, numRuns int) (BenchmarkResult, error) {
	fmt.Printf("Running %d stream tests...\n", numRuns)

	var totalLatencies []time.Duration
	var errors int
	startTime := time.Now()

	for run := 1; run <= numRuns; run++ {
		if verbose {
			fmt.Printf("  Stream run %d/%d... ", run, numRuns)
		}

		runStart := time.Now()

		// Create session for streaming using unified API format
		config := client.SessionConfig{
			Name:       fmt.Sprintf("stream-run-%d", run),
			Command:    []string{"/bin/bash", "-i"},
			WorkingDir: "/tmp",
			Width:      80,
			Height:     24,
			Term:       "xterm-256color",
		}

		session, err := c.CreateSession(config)
		if err != nil {
			errors++
			if verbose {
				fmt.Printf("❌ Create failed: %v\n", err)
			}
			continue
		}

		// Stream for 2 seconds
		stream, err := c.StreamSession(session.ID)
		if err != nil {
			errors++
			c.DeleteSession(session.ID)
			if verbose {
				fmt.Printf("❌ Stream failed: %v\n", err)
			}
			continue
		}

		// Collect events for 2 seconds
		timeout := time.After(2 * time.Second)
		eventCount := 0
		streamOk := true

	StreamLoop:
		for {
			select {
			case <-stream.Events:
				eventCount++
			case err := <-stream.Errors:
				if verbose {
					fmt.Printf("❌ Stream error: %v\n", err)
				}
				errors++
				streamOk = false
				break StreamLoop
			case <-timeout:
				break StreamLoop
			}
		}

		stream.Close()
		c.DeleteSession(session.ID)

		runDuration := time.Since(runStart)
		if streamOk {
			totalLatencies = append(totalLatencies, runDuration)
		}

		if verbose {
			if streamOk {
				fmt.Printf("✅ %d events, %.2fms\n", eventCount, float64(runDuration.Nanoseconds())/1e6)
			}
		}
	}

	totalDuration := time.Since(startTime)

	// Calculate statistics
	var min, max, total time.Duration
	if len(totalLatencies) > 0 {
		min = totalLatencies[0]
		max = totalLatencies[0]
		for _, lat := range totalLatencies {
			total += lat
			if lat < min {
				min = lat
			}
			if lat > max {
				max = lat
			}
		}
	}

	var avgLatency time.Duration
	if len(totalLatencies) > 0 {
		avgLatency = total / time.Duration(len(totalLatencies))
	}

	successRate := float64(len(totalLatencies)) / float64(numRuns) * 100
	throughput := float64(len(totalLatencies)) / totalDuration.Seconds()

	fmt.Printf("✅ Completed %d/%d stream runs (%.1f%% success rate)\n", len(totalLatencies), numRuns, successRate)

	return BenchmarkResult{
		ServerType:    serverType,
		TestType:      "stream",
		Runs:          numRuns,
		TotalDuration: totalDuration,
		AvgLatency:    avgLatency,
		MinLatency:    min,
		MaxLatency:    max,
		Throughput:    throughput,
		SuccessRate:   successRate,
		ErrorCount:    errors,
	}, nil
}

func displayComparison(goResults, rustResults []BenchmarkResult) {
	if len(goResults) == 0 && len(rustResults) == 0 {
		fmt.Println("No results to compare")
		return
	}

	fmt.Printf("%-12s %-8s %-6s %-12s %-12s %-12s %-10s %-8s\n",
		"Server", "Test", "Runs", "Avg Latency", "Min Latency", "Max Latency", "Throughput", "Success%")
	fmt.Printf("%-12s %-8s %-6s %-12s %-12s %-12s %-10s %-8s\n",
		"------", "----", "----", "-----------", "-----------", "-----------", "----------", "--------")

	for _, result := range goResults {
		fmt.Printf("%-12s %-8s %-6d %-12s %-12s %-12s %-10.1f %-8.1f\n",
			result.ServerType,
			result.TestType,
			result.Runs,
			formatDuration(result.AvgLatency),
			formatDuration(result.MinLatency),
			formatDuration(result.MaxLatency),
			result.Throughput,
			result.SuccessRate)
	}

	for _, result := range rustResults {
		fmt.Printf("%-12s %-8s %-6d %-12s %-12s %-12s %-10.1f %-8.1f\n",
			result.ServerType,
			result.TestType,
			result.Runs,
			formatDuration(result.AvgLatency),
			formatDuration(result.MinLatency),
			formatDuration(result.MaxLatency),
			result.Throughput,
			result.SuccessRate)
	}

	// Show winner analysis
	fmt.Printf("\n🏆 Performance Analysis:\n")
	analyzeResults(goResults, rustResults)
}

func analyzeResults(goResults, rustResults []BenchmarkResult) {
	for i := 0; i < len(goResults) && i < len(rustResults); i++ {
		goResult := goResults[i]
		rustResult := rustResults[i]

		if goResult.TestType != rustResult.TestType {
			continue
		}

		fmt.Printf("\n%s Test:\n", goResult.TestType)

		// Compare latency
		if goResult.AvgLatency < rustResult.AvgLatency {
			improvement := float64(rustResult.AvgLatency-goResult.AvgLatency) / float64(rustResult.AvgLatency) * 100
			fmt.Printf("  🥇 Go is %.1f%% faster (avg latency)\n", improvement)
		} else if rustResult.AvgLatency < goResult.AvgLatency {
			improvement := float64(goResult.AvgLatency-rustResult.AvgLatency) / float64(goResult.AvgLatency) * 100
			fmt.Printf("  🥇 Rust is %.1f%% faster (avg latency)\n", improvement)
		} else {
			fmt.Printf("  🤝 Similar average latency\n")
		}

		// Compare throughput
		if goResult.Throughput > rustResult.Throughput {
			improvement := (goResult.Throughput - rustResult.Throughput) / rustResult.Throughput * 100
			fmt.Printf("  🥇 Go has %.1f%% higher throughput\n", improvement)
		} else if rustResult.Throughput > goResult.Throughput {
			improvement := (rustResult.Throughput - goResult.Throughput) / goResult.Throughput * 100
			fmt.Printf("  🥇 Rust has %.1f%% higher throughput\n", improvement)
		} else {
			fmt.Printf("  🤝 Similar throughput\n")
		}

		// Compare success rate
		if goResult.SuccessRate > rustResult.SuccessRate {
			fmt.Printf("  🥇 Go has higher success rate (%.1f%% vs %.1f%%)\n", goResult.SuccessRate, rustResult.SuccessRate)
		} else if rustResult.SuccessRate > goResult.SuccessRate {
			fmt.Printf("  🥇 Rust has higher success rate (%.1f%% vs %.1f%%)\n", rustResult.SuccessRate, goResult.SuccessRate)
		} else {
			fmt.Printf("  🤝 Similar success rates\n")
		}
	}
}

func formatDuration(d time.Duration) string {
	ms := float64(d.Nanoseconds()) / 1e6
	if ms < 1 {
		return fmt.Sprintf("%.2fμs", float64(d.Nanoseconds())/1e3)
	}
	return fmt.Sprintf("%.2fms", ms)
}
