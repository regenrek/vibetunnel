# Development Code Signing Setup

## Avoiding Keychain Dialogs During Development

When developing VibeTunnel, you may encounter repeated keychain access dialogs every time you start the app. This is because the app stores the dashboard password in the keychain for security. 

### How Debug Mode Works

In DEBUG builds, VibeTunnel automatically skips reading passwords from the keychain to avoid authorization dialogs:

1. **Password Setting**: You can still set a password during your current app session
2. **Session Persistence**: The password works normally during the current app run
3. **No Persistence**: When you restart the app, the password is "forgotten" (not read from keychain)
4. **No Dialogs**: This prevents the keychain authorization dialog from appearing on every app start

When you set a password in debug mode, you'll see this log message:
```
Debug mode: Password saved to keychain but will not persist across app restarts. The password will only be available during this session to avoid keychain authorization dialogs during development.
```

### Production Behavior

In release builds, the app works normally:
- Passwords are saved to and read from the keychain
- Passwords persist across app restarts
- Standard keychain authorization may be required

## Code Signing Configuration

VibeTunnel uses automatic code signing for development:

1. **Configure your development team:**
   - Copy `Local.xcconfig.template` to `Local.xcconfig`
   - Set your `DEVELOPMENT_TEAM` ID

2. **Build configurations:**
   - Debug builds use your personal development certificate
   - Release builds use Developer ID for distribution
   - CI builds use ad-hoc signing

## Testing Password Protection

If you need to test password persistence in development:

1. **Build in Release mode**: Product → Scheme → Edit Scheme → Run → Build Configuration → Release
2. **Use Archive build**: Product → Archive (this always uses Release configuration)

## Implementation Details

The debug behavior is implemented in `DashboardKeychain.swift`:
- `getPassword()` returns `nil` in DEBUG builds without accessing keychain
- `setPassword()` still saves to keychain but logs that it won't persist
- `hasPassword()` works normally to check if a password exists

This approach provides a good development experience while maintaining security in production.