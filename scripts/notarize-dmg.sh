#!/bin/bash

set -euo pipefail

# Script to notarize a DMG file
# Usage: ./scripts/notarize-dmg.sh <dmg_path>

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <dmg_path>"
    exit 1
fi

DMG_PATH="$1"

if [[ ! -f "$DMG_PATH" ]]; then
    echo "Error: DMG not found at $DMG_PATH"
    exit 1
fi

echo "Notarizing DMG: $DMG_PATH"

# Check for required environment variables
if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" ]] || 
   [[ -z "${APP_STORE_CONNECT_KEY_ID:-}" ]] || 
   [[ -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
    echo "Error: Missing required environment variables for notarization"
    echo "Please set: APP_STORE_CONNECT_API_KEY_P8, APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID"
    exit 1
fi

# Create a temporary file for the API key
TEMP_KEY=$(mktemp)
echo "$APP_STORE_CONNECT_API_KEY_P8" > "$TEMP_KEY"

# Submit for notarization
echo "Submitting DMG for notarization..."
SUBMISSION_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
    --key "$TEMP_KEY" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait \
    --timeout 30m)

# Clean up temp key
rm -f "$TEMP_KEY"

echo "$SUBMISSION_OUTPUT"

# Check if notarization was successful
if echo "$SUBMISSION_OUTPUT" | grep -q "status: Accepted"; then
    echo "✅ Notarization successful!"
    
    # Staple the notarization ticket
    echo "Stapling notarization ticket to DMG..."
    if xcrun stapler staple "$DMG_PATH"; then
        echo "✅ Successfully stapled notarization ticket"
    else
        echo "❌ Failed to staple notarization ticket"
        exit 1
    fi
else
    echo "❌ Notarization failed!"
    exit 1
fi

echo "✅ DMG notarization complete: $DMG_PATH"