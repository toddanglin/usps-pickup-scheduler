# PickupBar

Schedule a USPS carrier pickup from your Mac's menu bar in a few clicks.

usps.com makes you re-login and re-enter your address practically every time
you want a package picked up. PickupBar lives in your menu bar, remembers your
verified pickup address, and schedules a pickup against the official USPS API
using your own USPS developer credentials — no browser, no re-login.

## Screenshots

<!-- TODO: add screenshots -->

Images go in `docs/images/`.

## Features

- Lives only in the menu bar — no Dock icon, no main window
- One-time USPS credential setup, stored securely in the Keychain
- Verified default pickup address (checked against USPS eligibility)
- Next-6-days date picker that skips Sundays and USPS holidays, and honors
  the 2 AM Central same-day cutoff
- Package counts per service type, estimated weight, pickup location, special
  instructions, and a "dog on premises" flag
- Required hazmat attestation before scheduling
- Progress indicator and a confirmation screen with a copyable confirmation
  number
- Friendly, specific error messages with a "Copy details" button for bug
  reports
- Menu bar badge and a notification if your credentials stop working
- Launch at login
- Optional USPS test environment (TEM) for safe experimentation

## How it authenticates

USPS's APIs authenticate *apps*, not individual consumers — there is no
"Sign in with USPS" flow available to a desktop tool like this one. Instead,
you create a free USPS developer account and register an app, and PickupBar
uses that app's Consumer Key and Secret to request an OAuth access token
directly from USPS.

Tokens last about 8 hours and PickupBar refreshes them automatically in the
background, so you never see a login screen after the initial setup. Nothing
leaves your Mac except calls to `apis.usps.com` (or `apis-tem.usps.com` in
test mode) — your credentials are stored in the Keychain, and PickupBar sends
no telemetry or analytics anywhere.

## USPS setup

1. Go to <https://developers.usps.com> and sign up. This creates a free USPS
   business/developer account.
2. Click "Add App" to register a new application.
3. Copy the app's **Consumer Key** and **Consumer Secret** — you'll paste
   both into PickupBar's onboarding screen.
4. Make sure the app has access to the **Carrier Pickup API** product. If
   PickupBar later shows "Your USPS app can't access Carrier Pickup" (a 403
   from USPS), go back into the developer portal and add that product to
   your app, or contact USPS API Support.

Keep in mind USPS only allows same-day pickup requests until **2:00 AM
Central time** — after that, the earliest available day moves to the next
one.

## Install / build

**Requirements:** macOS 14+, Xcode 15+ (this repo is built and tested with
Xcode 26). [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates the
Xcode project: `brew install xcodegen`.

```sh
make generate   # generate PickupBar.xcodeproj with XcodeGen
make build      # debug build
make run        # build and launch
make release    # release build; app lands in .build/dd/Build/Products/Release/PickupBar.app
make test       # run the unit test suite
make icon       # regenerate AppIcon.icns from Scripts/make-icon.swift
```

Release builds are ad-hoc signed, not notarized. On first launch, macOS
Gatekeeper may block the app — right-click the app and choose **Open**, or
remove the quarantine flag from Terminal:

```sh
xattr -d com.apple.quarantine /path/to/PickupBar.app
```

Then drag `PickupBar.app` to `/Applications`.

## Using it

**First run:**
- Open the USPS Developer Portal, create an app, and paste its Consumer Key
  and Secret into PickupBar — it verifies them by requesting a token
- Enter your pickup contact and address; PickupBar validates it against
  USPS's eligibility check and stores the standardized version
- You land on the pickup form, ready to schedule

**Scheduling a pickup:**
- Pick one of the next six available pickup days
- Set your package counts by service type, pickup location, weight, and any
  special instructions, then confirm the hazmat attestation
- Tap **Schedule Pickup** and get a confirmation number you can copy

**Settings tabs:**
- **Account** — masked credentials, connection status, replace/remove, and
  the USPS test environment (TEM) toggle
- **Address** — edit and re-validate your pickup contact and address
- **Defaults** — default pickup location, special instructions, dog-present
  flag, and default package weight
- **General** — launch at login, app version, link to this repo

## When something goes wrong

| Error title | What it means | What to do |
|---|---|---|
| You're offline | PickupBar couldn't reach USPS | Check your connection and try again |
| USPS rejected your API credentials | Your Consumer Key or Secret is wrong, expired, or was revoked | Open Settings › Account to update them |
| Your USPS app can't access Carrier Pickup | USPS returned 403 Forbidden | In the USPS developer portal, add the Carrier Pickup (pickup) product to your app, or contact USPS API Support |
| Slow down a little | USPS is rate-limiting requests from this app | Wait a minute and try again |
| USPS is having trouble | The USPS API is temporarily unavailable | Try again in a few minutes |
| USPS couldn't schedule this pickup | USPS rejected the request (bad address, invalid package data, etc.) | Review the listed details and adjust the form |
| This address isn't eligible for pickup | USPS won't pick up at this address as entered | Double-check the address, or schedule at usps.com to see alternatives |
| Something unexpected happened | An unrecognized response or a response PickupBar couldn't parse | Copy the details; if this followed a schedule attempt, check usps.com before retrying — the pickup may already have been created |

Every error screen has a **Copy details** button that copies the technical
diagnostics (status code and USPS error body) for a bug report.

## Development

```
PickupBar/App/          app entry point, AppState, flow state, launch-at-login, notifications
PickupBar/Models/       Codable wire models (address, package, pickup)
PickupBar/Services/     USPS client, token manager, Keychain, settings store, date calculator
PickupBar/Views/        SwiftUI views (onboarding, address setup, form, scheduling, confirmation, errors, settings)
PickupBarTests/         XCTest unit tests
Scripts/                make-icon.swift, mock-server.py
docs/superpowers/       design spec and implementation plans for this project
```

For manual QA without hitting production USPS, run the stdlib-only mock
server and point the app at it:

```sh
python3 Scripts/mock-server.py
# in another terminal
PICKUPBAR_BASE_URL=http://127.0.0.1:8787 .build/dd/Build/Products/Debug/PickupBar.app/Contents/MacOS/PickupBar
```

Force specific failure modes to exercise error handling:

```sh
MOCK_FAIL=403 python3 Scripts/mock-server.py       # forces a schedule-pickup failure
MOCK_TOKEN_FAIL=1 python3 Scripts/mock-server.py   # forces the token request to fail
```

`PICKUPBAR_BASE_URL` takes precedence over the "Use USPS test environment"
(TEM) toggle in Settings › Account, which itself takes precedence over
production — see `PickupBar/Services/BaseURL.swift`.

The design spec and implementation plans for this project live in
`docs/superpowers/specs` and `docs/superpowers/plans`.

## Limitations / roadmap

Not supported in v1:

- Viewing or cancelling existing pickups
- Multiple saved addresses
- Notarized release builds

## License

MIT — see [LICENSE](LICENSE).
