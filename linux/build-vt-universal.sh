#!/bin/bash
set -e

# Build universal vt binary for macOS

echo "Building vt universal binary..."

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Build for x86_64
echo "Building vt for x86_64..."
GOOS=darwin GOARCH=amd64 go build -o vt-x86_64 ./cmd/vt

# Build for arm64 
echo "Building vt for arm64..."
GOOS=darwin GOARCH=arm64 go build -o vt-arm64 ./cmd/vt

# Create universal binary
echo "Creating universal binary..."
lipo -create -output vt vt-x86_64 vt-arm64

# Clean up architecture-specific binaries
rm vt-x86_64 vt-arm64

# Make it executable
chmod +x vt

echo "vt universal binary built successfully at: $SCRIPT_DIR/vt"

# Copy to target location if provided
if [ -n "$1" ]; then
    echo "Copying vt to $1"
    cp vt "$1"
fi