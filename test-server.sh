#!/bin/bash

echo "Testing VibeTunnel HTTP Server..."
echo

# Test root endpoint
echo "Testing root endpoint (/):"
curl -s http://localhost:8080/ | head -20
echo

# Test health endpoint
echo "Testing health endpoint (/health):"
curl -s -w "\nHTTP Status: %{http_code}\n" http://localhost:8080/health
echo

# Test info endpoint
echo "Testing info endpoint (/info):"
curl -s http://localhost:8080/info | jq .
echo