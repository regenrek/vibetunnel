# VibeTunnel Release Process

This guide explains how to create and publish releases for VibeTunnel, a macOS menu bar application using Sparkle 2.x for automatic updates.

## 🎯 Release Process Overview

VibeTunnel uses an automated release process that handles all the complexity of:
- Building and code signing
- Notarization with Apple
- Creating DMG disk images
- Publishing to GitHub
- Updating Sparkle appcast files

## 🚀 Creating a Release

### 📋 Pre-Release Checklist (MUST DO FIRST!)

Before running ANY release commands, verify these items:

- [ ] **Version in version.xcconfig is correct**
  ```bash
  grep MARKETING_VERSION VibeTunnel/version.xcconfig
  # For beta.2 should show: MARKETING_VERSION = 1.0.0-beta.2
  # NOT: MARKETING_VERSION = 1.0.0
  ```
  
- [ ] **Build number is incremented**
  ```bash
  grep CURRENT_PROJECT_VERSION VibeTunnel/version.xcconfig
  # Must be higher than the last release
  ```
  
- [ ] **CHANGELOG.md has entry for this version**
  ```bash
  grep "## \[1.0.0-beta.2\]" CHANGELOG.md
  # Must exist with release notes
  ```

- [ ] **Run Tuist generate if build number was changed**
  ```bash
  tuist generate
  git add VibeTunnel.xcodeproj/project.pbxproj
  git commit -m "Update Xcode project for build XXX"
  ```

### Step 1: Pre-flight Check
```bash
./scripts/preflight-check.sh
```
This validates your environment is ready for release.

### Step 2: CRITICAL Pre-Release Version Check
**IMPORTANT**: Before running the release script, ensure your version.xcconfig is set correctly:

1. For beta releases: The MARKETING_VERSION should already include the suffix (e.g., `1.0.0-beta.2`)
2. The release script will NOT add additional suffixes - it uses the version as-is
3. Always verify the version before proceeding:
   ```bash
   grep MARKETING_VERSION VibeTunnel/version.xcconfig
   # Should show: MARKETING_VERSION = 1.0.0-beta.2
   ```

**Common Mistake**: If the version is already `1.0.0-beta.2` and you run `./scripts/release.sh beta 2`, 
it will create `1.0.0-beta.2-beta.2` which is wrong!

### Step 3: Create/Update CHANGELOG.md
Before creating any release, ensure the CHANGELOG.md file exists and contains a proper section for the version being released. If this is your first release, create a CHANGELOG.md file in the project root:

```markdown
# Changelog

All notable changes to VibeTunnel will be documented in this file.

## [1.0.0-beta.2] - 2025-06-19

### 🎨 UI Improvements
- **Enhanced feature** - Description of the improvement
...
```

**CRITICAL**: The appcast generation relies on the local CHANGELOG.md file, NOT the GitHub release description. The changelog must be added to CHANGELOG.md BEFORE running the release script.

### Step 4: Create the Release
```bash
# For stable releases:
./scripts/release.sh stable

# IMPORTANT: The release type parameter is only used for tagging!
# The actual version comes from version.xcconfig
# Example: If version.xcconfig has "1.0.0-beta.2", then:
./scripts/release.sh beta 2    # Creates tag v1.0.0-beta.2 (NOT v1.0.0-beta.2-beta.2!)
```

**IMPORTANT**: The release script does NOT automatically increment build numbers. You must manually update the build number in VibeTunnel.xcodeproj before running the script, or it will fail the pre-flight check.

The script will:
1. Validate build number is unique and incrementing
2. Build, sign, and notarize the app
3. Create a DMG
4. Publish to GitHub
5. Update the appcast files with EdDSA signatures
6. Commit and push all changes

### Step 5: Verify Success
- Check the GitHub releases page
- Verify the appcast was updated correctly with proper changelog content
- Test updating from a previous version
- **Important**: Verify that the Sparkle update dialog shows the formatted changelog, not HTML tags

## ⚠️ Critical Requirements

### 1. Build Numbers MUST Increment
Sparkle uses build numbers (CFBundleVersion) to determine updates, NOT version strings!

| Version | Build | Result |
|---------|-------|--------|
| 1.0.0-beta.1 | 100 | ✅ |
| 1.0.0-beta.2 | 101 | ✅ |
| 1.0.0-beta.3 | 99  | ❌ Build went backwards |
| 1.0.0 | 101 | ❌ Duplicate build number |

### 2. Required Environment Variables
```bash
export APP_STORE_CONNECT_KEY_ID="YOUR_KEY_ID"
export APP_STORE_CONNECT_ISSUER_ID="YOUR_ISSUER_ID"
export APP_STORE_CONNECT_API_KEY_P8="-----BEGIN PRIVATE KEY-----
YOUR_PRIVATE_KEY_CONTENT
-----END PRIVATE KEY-----"
```

### 3. Prerequisites
- Xcode 16.4+ installed
- GitHub CLI authenticated: `gh auth status`
- Apple Developer ID certificate in Keychain
- Sparkle tools in `~/.local/bin/` (sign_update, generate_appcast)

## 🔐 Sparkle Configuration

### Sparkle Requirements for Non-Sandboxed Apps

VibeTunnel is not sandboxed, which simplifies Sparkle configuration:

#### 1. Entitlements (VibeTunnel.entitlements)
```xml
<!-- App is NOT sandboxed -->
<key>com.apple.security.app-sandbox</key>
<false/>

<!-- Required for code injection/library validation -->
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

#### 2. Info.plist Configuration
```swift
"SUEnableInstallerLauncherService": false,  // Not needed for non-sandboxed apps
"SUEnableDownloaderService": false,         // Not needed for non-sandboxed apps
```

#### 3. Code Signing Requirements

The notarization script handles all signing correctly:
1. **Do NOT use --deep flag** when signing the app
2. Sign the app with hardened runtime and entitlements

The `notarize-app.sh` script should sign the app:
```bash
# Sign the app WITHOUT --deep flag
codesign --force --sign "Developer ID Application" --entitlements VibeTunnel.entitlements --options runtime VibeTunnel.app
```

### Common Sparkle Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| "You're up to date!" when update exists | Build number not incrementing | Check build numbers in appcast are correct |
| "Update installation failed" | Signing or permission issues | Verify app signature and entitlements |
| "Cannot verify update signature" | EdDSA key mismatch | Ensure sparkle-public-ed-key.txt matches private key |

## 📋 Update Channels

VibeTunnel supports two update channels:

1. **Stable Channel** (`appcast.xml`)
   - Production releases only
   - Default for all users

2. **Pre-release Channel** (`appcast-prerelease.xml`)
   - Includes beta, alpha, and RC versions
   - Users opt-in via Settings

## 🐛 Common Issues and Solutions

### Appcast Shows HTML Tags Instead of Formatted Text
**Problem**: Sparkle update dialog shows escaped HTML like `&lt;h2&gt;` instead of formatted text.

**Root Cause**: The generate-appcast.sh script is escaping HTML content from GitHub release descriptions.

**Solution**: 
1. Ensure CHANGELOG.md has the proper section for the release version BEFORE running release script
2. The appcast should use local CHANGELOG.md, not GitHub release body
3. If the appcast is wrong, manually fix the generate-appcast.sh script to use local changelog content

### Build Numbers Not Incrementing
**Problem**: Sparkle doesn't detect new version as an update.

**Solution**: Always increment the build number in the Xcode project before releasing.

## 🛠️ Manual Process (If Needed)

If the automated script fails, here's the manual process:

### 1. Update Build Number
Edit the project build settings in Xcode:
- Open VibeTunnel.xcodeproj
- Select the project
- Update CURRENT_PROJECT_VERSION (build number)

### 2. Clean and Build
```bash
rm -rf build DerivedData .build
./scripts/build.sh --configuration Release
```

### 3. Sign and Notarize
```bash
./scripts/notarize-app.sh build/Build/Products/Release/VibeTunnel.app
```

### 4. Create DMG
```bash
./scripts/create-dmg.sh
```

### 5. Sign DMG for Sparkle
```bash
export PATH="$HOME/.local/bin:$PATH"
sign_update build/VibeTunnel-X.X.X.dmg
# Copy the sparkle:edSignature value
```

### 6. Create GitHub Release
```bash
gh release create "v1.0.0-beta.1" \
  --title "VibeTunnel 1.0.0-beta.1" \
  --notes "Beta release 1" \
  --prerelease \
  build/VibeTunnel-1.0.0-beta.1.dmg
```

### 7. Update Appcast
```bash
./scripts/update-appcast.sh
git add appcast*.xml
git commit -m "Update appcast for v1.0.0-beta.1"
git push
```

## 🔍 Troubleshooting

### Debug Sparkle Updates
```bash
# Monitor VibeTunnel logs
log stream --predicate 'process == "VibeTunnel"' --level debug

# Check XPC errors
log stream --predicate 'process == "VibeTunnel"' | grep -i -E "(sparkle|xpc|installer)"

# Verify XPC services
codesign -dvv "VibeTunnel.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
```

### Verify Signing and Notarization
```bash
# Check app signature
./scripts/verify-app.sh build/VibeTunnel-1.0.0.dmg

# Verify XPC bundle IDs (should be org.sparkle-project.*)
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
  "VibeTunnel.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/Info.plist"
```

### Appcast Issues
```bash
# Verify appcast has correct build numbers
./scripts/verify-appcast.sh

# Check if build number is "1" (common bug)
grep '<sparkle:version>' appcast-prerelease.xml
```

## 📚 Important Links

- [Sparkle Sandboxing Guide](https://sparkle-project.org/documentation/sandboxing/)
- [Sparkle Code Signing](https://sparkle-project.org/documentation/sandboxing/#code-signing)
- [Apple Notarization](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)

---

**Remember**: Always use the automated release script, ensure build numbers increment, and test updates before announcing!