#!/bin/bash

set -e

# Set up Cargo environment
if [ -z "$CARGO_HOME" ]; then
    export CARGO_HOME="$HOME/.cargo"
fi
export CARGO="$CARGO_HOME/bin/cargo"

echo "Building universal binary for tty-fwd..."

# Build for x86_64
echo "Building x86_64 target..."
$CARGO build --release --target x86_64-apple-darwin

# Build for aarch64 (Apple Silicon)
echo "Building aarch64 target..."
$CARGO build --release --target aarch64-apple-darwin

# Create target/release directory if it doesn't exist
mkdir -p target/release

# Create universal binary
echo "Creating universal binary..."
lipo -create -output target/release/tty-fwd-universal \
    target/x86_64-apple-darwin/release/tty-fwd \
    target/aarch64-apple-darwin/release/tty-fwd

echo "Universal binary created: target/release/tty-fwd-universal"
echo "Verifying architecture support:"
lipo -info target/release/tty-fwd-universal

# Sign the universal binary
echo "Signing universal binary..."
codesign --force --sign - target/release/tty-fwd-universal
echo "Code signing complete"