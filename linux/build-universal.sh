#!/bin/bash

set -e

# Determine build mode based on Xcode configuration
BUILD_MODE="release"
GO_FLAGS=""
TARGET_DIR="build"

if [ "$CONFIGURATION" = "Debug" ]; then
    BUILD_MODE="debug"
    TARGET_DIR="build"
fi

echo "Building universal binary for vibetunnel in $BUILD_MODE mode..."
echo "Xcode Configuration: $CONFIGURATION"

# Change to the linux directory
cd "$(dirname "$0")"

# Create build directory if it doesn't exist
mkdir -p $TARGET_DIR

# Set CGO flags to suppress GNU folding constant warning
export CGO_CFLAGS="-Wno-gnu-folding-constant"

# Build for x86_64
echo "Building x86_64 target..."
GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -o $TARGET_DIR/vibetunnel-x86_64 ./cmd/vibetunnel

# Build for aarch64 (Apple Silicon)
echo "Building aarch64 target..."
GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o $TARGET_DIR/vibetunnel-arm64 ./cmd/vibetunnel

# Create universal binary
echo "Creating universal binary..."
lipo -create -output $TARGET_DIR/vibetunnel-universal \
    $TARGET_DIR/vibetunnel-x86_64 \
    $TARGET_DIR/vibetunnel-arm64

echo "Universal binary created: $TARGET_DIR/vibetunnel-universal"
echo "Verifying architecture support:"
lipo -info $TARGET_DIR/vibetunnel-universal

# Sign the universal binary
echo "Signing universal binary..."
codesign --force --sign - $TARGET_DIR/vibetunnel-universal
echo "Code signing complete"