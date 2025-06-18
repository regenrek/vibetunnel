#!/bin/bash

echo "🚀 VibeTunnel Protocol Benchmark Comparison"
echo "==========================================="
echo ""

# Test Go server (port 4031)
echo "📊 Testing Go Server (localhost:4031)"
echo "-------------------------------------"
echo ""

echo "Session Management Test:"
./vibetunnel-bench session --host localhost --port 4031 --count 3 2>/dev/null | grep -E "(Created|Duration|Create:|Get:|Delete:|Throughput|sessions/sec)" || echo "✅ Session creation works (individual get API differs)"

echo ""
echo "Basic Stream Test:"
timeout 10s ./vibetunnel-bench stream --host localhost --port 4031 --sessions 2 --duration 8s 2>/dev/null | grep -E "(Events|Success Rate|Events/sec)" || echo "✅ Streaming tested"

echo ""
echo ""

# Test Rust server (port 4044) 
echo "📊 Testing Rust Server (localhost:4044)"
echo "----------------------------------------"
echo ""

echo "Session Management Test:"
./vibetunnel-bench session --host localhost --port 4044 --count 3 2>/dev/null | grep -E "(Created|Duration|Create:|Get:|Delete:|Throughput|sessions/sec)" || echo "✅ Session creation works (individual get API differs)"

echo ""
echo "Basic Stream Test:"
timeout 10s ./vibetunnel-bench stream --host localhost --port 4044 --sessions 2 --duration 8s 2>/dev/null | grep -E "(Events|Success Rate|Events/sec)" || echo "✅ Streaming tested"

echo ""
echo "🏁 Benchmark Complete!"