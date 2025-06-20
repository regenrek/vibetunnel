# VibeTunnel Project Structure

After reorganization, the VibeTunnel project now has a clearer structure:

## Directory Layout

```
vibetunnel/
├── mac/                    # macOS app
│   ├── VibeTunnel/        # Source code
│   ├── VibeTunnelTests/   # Tests
│   ├── VibeTunnel.xcodeproj
│   ├── VibeTunnel.xcworkspace
│   ├── Package.swift
│   ├── scripts/           # Build and release scripts
│   ├── docs/              # macOS-specific documentation
│   └── private/           # Signing keys
│
├── ios/                   # iOS app
│   ├── VibeTunnel/       # Source code
│   ├── VibeTunnel.xcodeproj
│   └── Package.swift
│
├── web/                   # Web frontend
│   ├── src/
│   ├── public/
│   └── package.json
│
├── linux/                 # Go backend server
│   ├── cmd/
│   ├── pkg/
│   └── go.mod
│
├── tty-fwd/              # Rust terminal forwarder
│   ├── src/
│   └── Cargo.toml
│
└── docs/                 # General documentation
```

## Build Instructions

### macOS App
```bash
cd mac
xcodebuild -workspace VibeTunnel.xcworkspace -scheme VibeTunnel build
# or use the build script:
./scripts/build.sh
```

### iOS App
```bash
cd ios
xcodebuild -project VibeTunnel.xcodeproj -scheme VibeTunnel build
```

## CI/CD Updates

The GitHub Actions workflows have been updated to use the new paths:
- **Swift CI** (`swift.yml`) - Now uses `cd mac` before building, linting, and testing
- **iOS CI** (`ios.yml`) - Continues to use `cd ios`
- **Release** (`release.yml`) - NEW! Automated release workflow for both platforms
- **Build Scripts** - Now located at `mac/scripts/`
- **Monitor Script** - CI monitoring at `mac/scripts/monitor-ci.sh`

### Workflow Changes Made
1. Swift CI workflow updated with:
   - `cd mac` before dependency resolution
   - `cd mac` for all build commands
   - `cd mac` for linting (SwiftFormat and SwiftLint)
   - Updated test result paths to `mac/TestResults`

2. New Release workflow created:
   - Builds both macOS and iOS apps
   - Creates DMG for macOS distribution
   - Uploads artifacts to GitHub releases
   - Supports both tag-based and manual releases

### Running CI Monitor
```bash
cd mac
./scripts/monitor-ci.sh
```

## Important Notes

- The Xcode project build phases need to be updated to reference paths relative to the project root, not SRCROOT
- For example, web directory should be referenced as `${SRCROOT}/../web` instead of `${SRCROOT}/web`
- All macOS-specific scripts are now in `mac/scripts/`
- Documentation split between `docs/` (general) and `mac/docs/` (macOS-specific)