#!/bin/bash

set -e

# Set up Cargo environment
if [ -z "$CARGO_HOME" ]; then
    export CARGO_HOME="$HOME/.cargo"
fi
export CARGO="$CARGO_HOME/bin/cargo"

# Determine build mode based on Xcode configuration
BUILD_MODE="release"
CARGO_FLAGS="--release"
TARGET_DIR="release"

if [ "$CONFIGURATION" = "Debug" ]; then
    BUILD_MODE="debug"
    CARGO_FLAGS=""
    TARGET_DIR="debug"
fi

echo "Building universal binary for tty-fwd in $BUILD_MODE mode..."
echo "Xcode Configuration: $CONFIGURATION"

# Build for x86_64
echo "Building x86_64 target..."
$CARGO build $CARGO_FLAGS --target x86_64-apple-darwin

# Build for aarch64 (Apple Silicon)
echo "Building aarch64 target..."
$CARGO build $CARGO_FLAGS --target aarch64-apple-darwin

# Create target directory if it doesn't exist
mkdir -p target/$TARGET_DIR

# Create universal binary
echo "Creating universal binary..."
lipo -create -output target/$TARGET_DIR/tty-fwd-universal \
    target/x86_64-apple-darwin/$TARGET_DIR/tty-fwd \
    target/aarch64-apple-darwin/$TARGET_DIR/tty-fwd

echo "Universal binary created: target/$TARGET_DIR/tty-fwd-universal"
echo "Verifying architecture support:"
lipo -info target/$TARGET_DIR/tty-fwd-universal

# Sign the universal binary
echo "Signing universal binary..."
codesign --force --sign - target/$TARGET_DIR/tty-fwd-universal
echo "Code signing complete"