package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var (
	hostname string
	port     int
	verbose  bool
)

var rootCmd = &cobra.Command{
	Use:   "vibetunnel-bench",
	Short: "VibeTunnel Protocol Performance Benchmark Tool",
	Long: `A comprehensive benchmarking tool for VibeTunnel server-client protocol.
Tests session management, SSE streaming, and concurrent user performance.

Examples:
  vibetunnel-bench session --host localhost --port 4026
  vibetunnel-bench stream --host localhost --port 4026 --sessions 5
  vibetunnel-bench load --host localhost --port 4026 --concurrent 50`,
}

func init() {
	rootCmd.PersistentFlags().StringVar(&hostname, "host", "localhost", "VibeTunnel server hostname")
	rootCmd.PersistentFlags().IntVar(&port, "port", 4026, "VibeTunnel server port")
	rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "Enable verbose output")
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}