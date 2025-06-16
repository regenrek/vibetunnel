#!/bin/bash

echo "Testing /sessions endpoint..."
echo ""

# Test if the server is running and call the sessions endpoint
response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" http://localhost:8080/sessions)

# Extract the body and status
body=$(echo "$response" | sed -n '1,/^HTTP_STATUS:/p' | sed '$d')
status=$(echo "$response" | grep "HTTP_STATUS:" | cut -d: -f2)

echo "HTTP Status: $status"
echo "Response Body:"
echo "$body" | jq . 2>/dev/null || echo "$body"