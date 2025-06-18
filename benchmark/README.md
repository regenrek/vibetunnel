# VibeTunnel Protocol Benchmark Tool

A comprehensive benchmarking tool for testing VibeTunnel server performance and protocol compliance.

## Features

- **Session Management**: Test session creation, retrieval, and deletion performance
- **SSE Streaming**: Benchmark Server-Sent Events streaming latency and throughput  
- **Concurrent Load**: Simulate multiple users for load testing
- **Protocol Compliance**: Full VibeTunnel HTTP API client implementation

## Installation

```bash
cd benchmark
go mod tidy
go build -o vibetunnel-bench .
```

## Usage

### Basic Connectivity Test
```bash
./vibetunnel-bench session --host localhost --port 4031 --count 5
```

### Session Management Benchmark
```bash
# Test session lifecycle with 10 sessions
./vibetunnel-bench session --host localhost --port 4031 --count 10 --verbose

# Custom shell and working directory
./vibetunnel-bench session --host localhost --port 4031 --shell /bin/zsh --cwd /home/user
```

### SSE Streaming Benchmark
```bash
# Test streaming performance with 3 concurrent sessions
./vibetunnel-bench stream --host localhost --port 4031 --sessions 3 --duration 30s

# Sequential streaming test
./vibetunnel-bench stream --host localhost --port 4031 --sessions 5 --concurrent=false

# Custom commands to execute
./vibetunnel-bench stream --host localhost --port 4031 --commands "echo test,ls -la,date"
```

### Concurrent Load Testing
```bash
# Simulate 20 concurrent users for 2 minutes
./vibetunnel-bench load --host localhost --port 4031 --concurrent 20 --duration 2m

# Load test with custom ramp-up period
./vibetunnel-bench load --host localhost --port 4031 --concurrent 50 --duration 5m --ramp-up 30s
```

## Command Reference

### Global Flags
- `--host`: Server hostname (default: localhost)
- `--port`: Server port (default: 4026)
- `--verbose, -v`: Enable detailed output

### Session Command
- `--count, -c`: Number of sessions to create (default: 10)
- `--shell`: Shell to use (default: /bin/bash)
- `--cwd`: Working directory (default: /tmp)
- `--width`: Terminal width (default: 80)
- `--height`: Terminal height (default: 24)

### Stream Command
- `--sessions, -s`: Number of sessions to stream (default: 3)
- `--duration, -d`: Benchmark duration (default: 30s)
- `--commands`: Commands to execute (default: ["echo hello", "ls -la", "date"])
- `--concurrent`: Run streams concurrently (default: true)
- `--input-delay`: Delay between commands (default: 2s)

### Load Command
- `--concurrent, -c`: Number of concurrent users (default: 10)
- `--duration, -d`: Load test duration (default: 60s)
- `--ramp-up`: Ramp-up period (default: 10s)

## Example Output

### Session Benchmark
```
🚀 VibeTunnel Session Benchmark
Target: localhost:4031
Sessions: 10

Testing connectivity... ✅ Connected

📊 Session Lifecycle Benchmark
✅ Created 10 sessions in 0.45s
✅ Retrieved 10 sessions in 0.12s
✅ Listed 47 sessions in 2.34ms
✅ Deleted 10 sessions in 0.23s

📈 Performance Statistics
Overall Duration: 0.81s

Operation Latencies (avg/min/max in ms):
  Create:  45.23 /  38.12 /  67.89
  Get:     12.45 /   8.23 /  18.67
  Delete:  23.78 /  19.45 /  31.23

Throughput:
  Create: 22.3 sessions/sec
  Get:    83.4 requests/sec
  Delete: 43.5 sessions/sec
```

### Stream Benchmark
```
🚀 VibeTunnel SSE Stream Benchmark
Target: localhost:4031
Sessions: 3
Duration: 30s
Concurrent: true

📊 Concurrent SSE Stream Benchmark

📈 Stream Performance Statistics
Total Duration: 30.12s

Overall Results:
  Sessions: 3 total, 3 successful
  Events: 1,247 total
  Data: 45.67 KB
  Errors: 0

Latency (average):
  First Event: 156.3ms
  Last Event: 29.8s

Throughput:
  Events/sec: 41.4
  KB/sec: 1.52
  Success Rate: 100.0%

✅ All streams completed successfully
```

## Protocol Implementation

The benchmark tool implements the complete VibeTunnel HTTP API:

- `POST /api/sessions` - Create session
- `GET /api/sessions` - List sessions  
- `GET /api/sessions/{id}` - Get session details
- `POST /api/sessions/{id}/input` - Send input
- `GET /api/sessions/{id}/stream` - SSE stream events
- `DELETE /api/sessions/{id}` - Delete session

## Performance Testing Tips

1. **Start Small**: Begin with low concurrency and short durations
2. **Monitor Resources**: Watch server CPU, memory, and network usage
3. **Baseline First**: Test single-user performance before load testing
4. **Network Latency**: Account for network latency in benchmarks
5. **Realistic Workloads**: Use commands and data patterns similar to production

## Troubleshooting

### Connection Refused
- Verify server is running: `curl http://localhost:4031/api/sessions`
- Check firewall and port accessibility

### High Error Rates
- Reduce concurrency level
- Increase timeouts
- Check server logs for resource limits

### Inconsistent Results
- Run multiple iterations and average results
- Ensure stable network conditions
- Close other applications using system resources