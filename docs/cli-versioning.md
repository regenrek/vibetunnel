# CLI Versioning Guide

This document explains how versioning works for the VibeTunnel CLI tools and where version numbers need to be updated.

## Overview

VibeTunnel uses a unified CLI binary approach:
- **vibetunnel** - The main Go binary that implements terminal forwarding
- **vt** - A symlink to vibetunnel that provides simplified command execution

## Version Locations

### 1. VibeTunnel Binary Version

**File:** `/linux/Makefile`  
**Line:** 8  
**Format:** `VERSION := 1.0.6`

This version is injected into the binary at build time and displayed when running:
```bash
vibetunnel version
# Output: VibeTunnel Linux v1.0.6

vt --version  
# Output: VibeTunnel Linux v1.0.6 (same as vibetunnel)
```

### 2. macOS App Version

**File:** `/mac/VibeTunnel/version.xcconfig`  
**Format:** 
```
MARKETING_VERSION = 1.0.6
CURRENT_PROJECT_VERSION = 108
```

## Version Checking in macOS App

The macOS VibeTunnel app's CLI installer (`/mac/VibeTunnel/Utilities/CLIInstaller.swift`):

1. **Installation Check**: Both `/usr/local/bin/vt` and `/usr/local/bin/vibetunnel` must exist
2. **Symlink Check**: Verifies that `vt` is a symlink to `vibetunnel` 
3. **Version Comparison**: Only checks the vibetunnel binary version
4. **Update Detection**: Prompts for update if version mismatch or vt needs migration

## How to Update Versions

### Updating Version Numbers
1. Edit `/linux/Makefile` and update `VERSION`
2. Edit `/mac/VibeTunnel/version.xcconfig` and update both:
   - `MARKETING_VERSION` (should match Makefile version)
   - `CURRENT_PROJECT_VERSION` (increment by 1)
3. Rebuild with `make build` or `./build-universal.sh`

## Build Process

### macOS App Build
The macOS build process automatically:
1. Runs `/linux/build-universal.sh` to build vibetunnel binary
2. Copies vibetunnel to the app bundle's Resources directory
3. The installer creates the vt symlink during installation

### Manual CLI Build
For development or Linux installations:
```bash
cd /linux
make build          # Builds vibetunnel binary
# or
./build-universal.sh  # Builds universal binary for macOS
```

## Installation Process

When installing CLI tools:
1. vibetunnel binary is copied to `/usr/local/bin/vibetunnel`
2. A symlink is created: `/usr/local/bin/vt` → `/usr/local/bin/vibetunnel`
3. When executed as `vt`, the binary detects this and runs in simplified mode

## Migration from Old VT Script

For users with the old bash vt script:
1. The installer detects that vt is not a symlink
2. Backs up the old script to `/usr/local/bin/vt.bak`
3. Creates the new symlink structure

## Best Practices

1. **Patch Versions**: Increment when fixing bugs (1.0.6 → 1.0.7)
2. **Minor Versions**: Increment when adding features (1.0.x → 1.1.0)
3. **Major Versions**: Increment for breaking changes (1.x.x → 2.0.0)
4. **Keep Versions in Sync**: Always update both Makefile and version.xcconfig together
5. **Document Changes**: Update CHANGELOG when changing versions