#!/bin/bash
# Script to properly sign tty-fwd binary during build

set -e

# Get the signing identity from the parent app
PARENT_SIGN_IDENTITY=$(codesign -dv "$CODESIGNING_FOLDER_PATH" 2>&1 | grep "^Authority=" | head -1 | cut -d "=" -f2)

# Path to tty-fwd in the app bundle
TTY_FWD_PATH="$CODESIGNING_FOLDER_PATH/Contents/Resources/tty-fwd"

if [ -f "$TTY_FWD_PATH" ]; then
    echo "Signing tty-fwd binary..."
    
    if [ -z "$PARENT_SIGN_IDENTITY" ] || [ "$PARENT_SIGN_IDENTITY" == "adhoc" ]; then
        # For debug builds, use ad-hoc signing but with runtime hardening disabled
        codesign --force --sign - --timestamp=none --options=runtime "$TTY_FWD_PATH"
    else
        # For release builds, use the same identity as the parent app
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp --options=runtime "$TTY_FWD_PATH"
    fi
    
    echo "tty-fwd signed successfully"
else
    echo "Warning: tty-fwd not found at $TTY_FWD_PATH"
fi