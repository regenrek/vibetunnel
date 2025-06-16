# Keychain Access Dialog Investigation Results

## Problem Summary
The keychain access dialog appears on every restart because:
1. Password is accessed immediately when the server starts (both TunnelServer and RustServer)
2. NgrokService's auth token is accessed when checking status
3. No in-memory caching of credentials after first access

## Where Keychain Access is Triggered

### 1. Server Startup (Every time the app launches)
- **TunnelServer.swift:146**: `if let password = DashboardKeychain.shared.getPassword()`
- **RustServer.swift:162**: `if let password = DashboardKeychain.shared.getPassword()`
- Both servers check for password on startup to configure basic auth middleware

### 2. Settings View
- **DashboardSettingsView.swift:114**: Checks if password exists on view appear
- **DashboardSettingsView.swift:259**: When revealing ngrok token
- **WelcomeView.swift:342**: When setting password during onboarding

### 3. NgrokService
- **NgrokService.swift:85-87**: Getting auth token (triggers keychain)
- **NgrokService.swift:117-121**: When starting ngrok tunnel

## Recommended Solutions

### 1. Implement In-Memory Caching
Create a secure in-memory cache for credentials that survives the app session:

```swift
@MainActor
final class CredentialCache {
    static let shared = CredentialCache()
    
    private var dashboardPassword: String?
    private var ngrokAuthToken: String?
    private var lastAccessTime: Date?
    
    private init() {}
    
    func getDashboardPassword() -> String? {
        if let password = dashboardPassword {
            return password
        }
        // Fall back to keychain only if not cached
        dashboardPassword = DashboardKeychain.shared.getPassword()
        return dashboardPassword
    }
    
    func clearCache() {
        dashboardPassword = nil
        ngrokAuthToken = nil
    }
}
```

### 2. Defer Keychain Access Until Needed
- Don't access keychain on server startup unless password protection is enabled
- Check `UserDefaults.standard.bool(forKey: "dashboardPasswordEnabled")` first
- Only access keychain when actually authenticating a request

### 3. Use Keychain Access Groups
Configure the app to use a shared keychain access group to reduce prompts:
- Add keychain access group to entitlements
- Update keychain queries to include the access group

### 4. Batch Keychain Operations
When multiple keychain accesses are needed, batch them together to minimize prompts.

### 5. Add "hasPassword" Check Without Retrieval
Both DashboardKeychain and NgrokService already have this implemented:
- `DashboardKeychain.hasPassword()` (line 45-59)
- `NgrokService.hasAuthToken` (line 100-102)

Use these checks before attempting to retrieve values.

## Immediate Fix Implementation

The quickest fix is to defer password retrieval until an authenticated request arrives:

1. Modify server implementations to not retrieve password on startup
2. Add lazy initialization for basic auth middleware
3. Cache credentials after first successful retrieval
4. Only check if password exists (using `hasPassword()`) on startup

This will reduce keychain prompts from every startup to only when:
- First authenticated request arrives
- User explicitly accesses credentials in settings
- Credentials are changed/updated