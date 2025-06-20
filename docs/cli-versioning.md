# CLI Versioning Guide

This document explains how versioning works for the VibeTunnel CLI tools and where version numbers need to be updated.

## Overview

VibeTunnel has two CLI components that work together:
- **vt** - A bash wrapper script that provides convenient access to vibetunnel
- **vibetunnel** - The Go binary that implements the actual terminal forwarding

## Version Locations

### 1. VT Script Version

**File:** `/linux/cmd/vt/vt`  
**Line:** ~5  
**Format:** `VERSION="1.0.6"`

The vt script has its own version number stored as a bash variable. This version is displayed when running:
```bash
vt --version
# Output: vt version 1.0.6
```

### 2. VibeTunnel Binary Version

**File:** `/linux/cmd/vibetunnel/version.go`  
**Format:** Go constants
```go
const (
    Version = "1.0.3"
    AppName = "VibeTunnel Linux"
)
```

This version is displayed when running:
```bash
vibetunnel version
# Output: VibeTunnel Linux v1.0.3
```

## Version Checking in macOS App

The macOS VibeTunnel app's CLI installer (`/mac/VibeTunnel/Utilities/CLIInstaller.swift`) checks both tools:

1. **Installation Check**: Both `/usr/local/bin/vt` and `/usr/local/bin/vibetunnel` must exist
2. **Version Comparison**: Takes the **lowest** version between vt and vibetunnel
3. **Update Detection**: If either tool is outdated, prompts for update

## How to Update Versions

### Raising VT Version
1. Edit `/linux/cmd/vt/vt`
2. Update the `VERSION` variable (e.g., `VERSION="1.0.7"`)
3. The macOS build process automatically copies this during build

### Raising VibeTunnel Version
1. Edit `/linux/cmd/vibetunnel/version.go`
2. Update the `Version` constant
3. Rebuild the Go binary with `./build-universal.sh`

## Build Process

### macOS App Build
The macOS build process (`/mac/scripts/build.sh`) automatically:
1. Runs `/linux/build-universal.sh` to build vibetunnel binary
2. Runs `/linux/build-vt-universal.sh` to prepare the vt script
3. Copies both to the app bundle's Resources directory

### Manual CLI Build
For development or Linux installations:
```bash
cd /linux
./build-universal.sh  # Builds vibetunnel binary
./build-vt-universal.sh  # Prepares vt script
```

## Version Synchronization

While the two tools can have different version numbers, it's recommended to keep them in sync for major releases to avoid confusion. The macOS installer will use the lower version number when checking for updates, ensuring both tools are updated together.

## Best Practices

1. **Patch Versions**: Increment when fixing bugs (1.0.3 → 1.0.4)
2. **Minor Versions**: Increment when adding features (1.0.x → 1.1.0)
3. **Major Versions**: Increment for breaking changes (1.x.x → 2.0.0)
4. **Sync on Release**: Consider syncing version numbers for official releases
5. **Document Changes**: Update CHANGELOG when changing versions