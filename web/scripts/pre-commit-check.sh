#!/bin/bash

# VibeTunnel Pre-commit Check Script
# Can be run manually: npm run pre-commit

set -e

echo "🔍 Running pre-commit checks..."

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not in a git repository"
    exit 1
fi

# Get staged files or all TypeScript files if not in a commit
if git diff --cached --quiet; then
    echo "📁 No staged files, checking all TypeScript files..."
    TS_FILES=$(find src -name "*.ts" -o -name "*.tsx" | tr '\n' ' ')
else
    echo "📁 Checking staged TypeScript files..."
    TS_FILES=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(ts|tsx)$' | tr '\n' ' ')
fi

if [ -z "$TS_FILES" ]; then
    echo "✅ No TypeScript files to check"
    exit 0
fi

echo "Files to check: $TS_FILES"

# Run ESLint
echo "🔧 Running ESLint..."
npm run lint

if [ $? -ne 0 ]; then
    echo "❌ ESLint failed. Run 'npm run lint:fix' to auto-fix issues."
    exit 1
fi

# Run Prettier check
echo "✨ Checking Prettier formatting..."
npm run format:check

if [ $? -ne 0 ]; then
    echo "❌ Prettier formatting issues found. Run 'npm run format' to fix."
    exit 1
fi

echo "✅ All checks passed!"