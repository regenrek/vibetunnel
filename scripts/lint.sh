#!/bin/bash

# Swift linting and formatting script
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

cd "$PROJECT_ROOT"

echo "Running SwiftFormat..."
if command -v swiftformat &> /dev/null; then
    swiftformat . --verbose
else
    echo "SwiftFormat not installed. Install with: brew install swiftformat"
    exit 1
fi

echo "Running SwiftLint..."
if command -v swiftlint &> /dev/null; then
    swiftlint --fix
    swiftlint
else
    echo "SwiftLint not installed. Install with: brew install swiftlint"
    exit 1
fi

echo "✅ Linting complete!"