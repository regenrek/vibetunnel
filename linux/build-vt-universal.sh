#!/bin/bash
set -e

# Copy vt bash script for macOS app bundle

echo "Preparing vt bash script..."

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Copy the bash script
echo "Copying vt bash script..."
cp cmd/vt/vt vt

# Make it executable
chmod +x vt

# Sign it for macOS if codesign is available
if command -v codesign >/dev/null 2>&1; then
    echo "Signing vt script..."
    codesign --force --sign - vt
fi

echo "vt script prepared successfully at: $SCRIPT_DIR/vt"

# Copy to target location if provided
if [ -n "$1" ]; then
    echo "Copying vt to $1"
    cp vt "$1"
fi