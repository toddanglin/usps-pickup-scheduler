# Security

## How Pickup handles your data

- Your USPS Consumer Key and Secret are stored in the macOS login Keychain,
  never in preferences or files. OAuth access tokens are kept in memory.
- The app talks only to `apis.usps.com` (or `apis-tem.usps.com` when the
  USPS test environment is on). A `PICKUP_BASE_URL` environment variable
  can point a debug build at a local mock server.
- There is no telemetry, analytics, or crash reporting.
- Your pickup address, defaults and the list of pickups you scheduled are
  stored locally in the app's sandboxed preferences.
- The app was called PickupBar before 1.0.1. To carry existing settings
  over, its sandbox has one read-only exception: PickupBar's own preferences
  file (`~/Library/Containers/com.toddanglin.PickupBar/.../com.toddanglin.PickupBar.plist`),
  read once at first launch. Credentials move from the
  `com.toddanglin.PickupBar` Keychain service to `com.toddanglin.Pickup` and
  the old items are deleted.

## Reporting a vulnerability

Please do not open a public issue for security problems. Instead, open a
private security advisory on GitHub: on this repository, go to
**Security › Advisories › Report a vulnerability**. Include steps to
reproduce and the Pickup and macOS versions. Never include real USPS
credentials.
