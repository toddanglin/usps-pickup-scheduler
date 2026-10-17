<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Pickup app icon: a white envelope on a blue rounded square">
</p>

# Pickup

[![CI](https://github.com/toddanglin/usps-pickup-scheduler/actions/workflows/ci.yml/badge.svg)](https://github.com/toddanglin/usps-pickup-scheduler/actions/workflows/ci.yml)

A simple and easy-to-use macOS menu bar utility for quickly scheduling USPS pickups.

Scheduling a pickup on usps.com means signing in again and re-entering your
address almost every time. Pickup lives in your menu bar, remembers your
verified pickup address, and schedules pickups through the official USPS API
with your own USPS developer credentials. No browser, no login screen.

**Status:** in daily use by the author. API coverage is verified against the
USPS test environment. See [CHANGELOG.md](CHANGELOG.md).

## Quick look

![Pickup in under a minute: connect once with a USPS API key, verify your address, pick a day and count packages, get a confirmation number, and modify or cancel pickups from the menu bar](docs/explainer.gif)

Prefer a sharper version? [Watch the 55-second explainer (MP4)](docs/explainer.mp4)

## Screenshots

| Onboarding | Schedule a pickup | Confirmation | Scheduled pickups |
|---|---|---|---|
| ![Onboarding](docs/images/01-onboarding.png) | ![Pickup form](docs/images/03-form.png) | ![Confirmation](docs/images/05-confirmation.png) | ![Scheduled pickups](docs/images/08-history.png) |

## Features

- Lives in the menu bar only. No Dock icon, no main window.
- One-time USPS credential setup, stored in the Keychain.
- A default pickup address, verified against USPS's eligibility check.
- A date picker for the next six pickup days. It skips Sundays and USPS
  holidays and follows the 2 AM Central same-day cutoff.
- Package counts per service type (Ground Advantage, Priority Mail, Priority
  Mail Express, International, Returns, Other). Type a number or use the
  stepper. Plus estimated weight, special instructions, and a "dog on
  premises" flag.
- Pickup locations: Front Door, Back Door, Side Door, Knock on Door / Ring
  Bell, Mail Room, Office, Porch, Reception, Mailbox, or Other. Other requires
  special instructions.
- A hazmat confirmation before scheduling, with a link to USPS Publication 52.
- A progress indicator, then a confirmation screen with a copyable
  confirmation number.
- Scheduled pickups: a list of the pickups you scheduled with Pickup, split
  into upcoming and past, with copyable confirmation numbers. The USPS API has
  no way to list pickups, so this is Pickup's own local record. Pickups made
  on usps.com do not appear.
- Modify or cancel an upcoming pickup from that list. Modify reopens the form
  filled in with the pickup as USPS has it and saves it back. Cancel asks
  first, then cancels it with USPS. Cancelled pickups move to Past with a
  Cancelled badge.
- When you open Scheduled pickups, Pickup quietly re-checks upcoming pickups
  with USPS and marks any that changed on usps.com with a red dot. Pickup
  re-checks at most every five minutes on its own; a Refresh button at the
  bottom of the list checks immediately.
- Clear error messages with a Copy details button for bug reports.
- A menu bar badge and a notification if your credentials stop working.
- Launch at login.
- An optional switch to the USPS test environment (TEM).

## How it authenticates

USPS's APIs authenticate apps, not individual consumers, so there is no
"Sign in with USPS" flow for a desktop tool. Instead, you create a free USPS
developer account and register an app. Pickup uses that app's Consumer Key
and Secret to request an OAuth access token directly from USPS.

Tokens last about 8 hours and Pickup refreshes them in the background, so you
never see a login screen after setup. Nothing leaves your Mac except calls to
`apis.usps.com` (or `apis-tem.usps.com` in test mode). Your credentials stay
in the Keychain, and Pickup sends no telemetry.

## USPS setup

1. Go to <https://developers.usps.com> and sign up. This creates a free USPS
   business account.
2. Click "Add App" to register an application.
3. Copy the app's Consumer Key and Consumer Secret. You will paste both into
   Pickup's onboarding screen.
4. Add the Carrier Pickup API product to the app. This step is easy to miss:
   a new app starts with only "Default Access", which does not include Carrier
   Pickup. Open the app in the portal and add the Carrier Pickup product
   (OAuth scope `carrier-pickup`). If the portal does not let you, ask USPS to
   enable it through the API service request form at
   <https://emailus.usps.com/s/usps-APIs>.

   Without that product the credentials still work and the token call
   succeeds, but every pickup call returns `401 Insufficient OAuth scope` and
   Pickup shows "Your USPS app can't access Carrier Pickup". Settings › Account
   shows whether your token carries the `carrier-pickup` scope under API
   access.

USPS accepts same-day pickup requests until 2:00 AM Central time. After that,
the earliest available day is the next one.

## Install / build

Requirements: macOS 14 or later and Xcode 16 or later. This repo is developed
with Xcode 26 and CI uses Xcode 16. The Xcode project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

```sh
make generate   # generate Pickup.xcodeproj with XcodeGen
make build      # debug build
make run        # build and launch
make release    # release build; the app lands in .build/dd/Build/Products/Release/Pickup.app
make test       # run the unit tests
make icon       # regenerate the app icon from Scripts/make-icon.swift
make explainer  # re-render docs/explainer.mp4 and .gif (run `make uitest CLEAN=1 UISCREENS=.build/explainer-screens` first)
```

Builds are ad-hoc signed and not notarized. On first launch, Gatekeeper may
block the app. Right-click the app and choose Open, or remove the quarantine
flag from Terminal:

```sh
xattr -d com.apple.quarantine /path/to/Pickup.app
```

Then drag `Pickup.app` to `/Applications`.

## Using it

First run:

- Open the USPS Developer Portal, create an app, and paste its Consumer Key
  and Secret into Pickup. Pickup verifies them by requesting a token.
- Enter your pickup contact and address. Give an email, a 10-digit cell
  number, or both. Email is recommended because USPS sends the pickup
  confirmation there. Pickup validates the address with USPS and stores the
  standardized version.
- You land on the pickup form, ready to schedule.

Scheduling a pickup:

- Pick one of the next six available pickup days.
- Set your package counts by service type, the pickup location, the weight,
  and any special instructions, then confirm the hazmat checkbox.
- Click Schedule Pickup and copy the confirmation number.
- Open Scheduled pickups (the clock in the footer, the "View scheduled
  pickups" link on the confirmation, or the "Last pickup" line on the form) to
  see every pickup the app has scheduled.

Changing or cancelling a pickup:

- In Scheduled pickups, open an upcoming pickup's menu (the three dots, or
  right-click the row).
- Modify loads the pickup from USPS into the form. Change what you need,
  confirm the hazmat checkbox again, and click Save Changes, or Discard. USPS
  keeps the same confirmation number.
- Cancel pickup asks for confirmation, then cancels it with USPS. If USPS says
  it was already cancelled, Pickup marks it cancelled.
- Past and cancelled pickups can only be copied or removed from the list.

What Pickup does not check for you: the hazmat checkbox is a reminder. The
USPS API has no hazmat, terms-acceptance, or business-address fields, so those
acknowledgements are your responsibility, the same as on usps.com. The paid,
timed Pickup On Demand service is only available on the website.

Settings tabs:

- Account: masked credentials, connection status, replace or remove, and the
  USPS test environment (TEM) switch.
- Address: edit and re-validate your pickup contact and address.
- Defaults: default pickup location, special instructions, dog-present flag,
  and default package weight.
- General: launch at login, app version, and a link to this repo.

## When something goes wrong

| Error title | What it means | What to do |
|---|---|---|
| You're offline | Pickup couldn't reach USPS | Check your connection and try again |
| USPS rejected your API credentials | Your Consumer Key or Secret is wrong, expired, or was revoked | Open Settings › Account to update them |
| Your USPS app can't access Carrier Pickup (401, "Insufficient OAuth scope") | Your key and secret are valid, but the USPS app they belong to has no Carrier Pickup API product, so the token has no `carrier-pickup` scope | In the USPS Developer Portal, open your app and add the Carrier Pickup product, or ask USPS API Support to enable it. Then quit and reopen Pickup |
| Your USPS app can't access Carrier Pickup (403) | USPS returned 403 Forbidden | Add the Carrier Pickup product to your app in the USPS developer portal, or contact USPS API Support |
| Slow down a little | USPS is rate-limiting requests from this app | Wait a minute and try again |
| USPS is having trouble | The USPS API is temporarily unavailable | Try again in a few minutes |
| USPS couldn't schedule this pickup | USPS rejected the request, for example a bad address or invalid package data | Review the listed details and adjust the form |
| This address isn't eligible for pickup | USPS won't pick up at this address as entered | Double-check the address, or schedule at usps.com to see alternatives |
| Something unexpected happened | An unrecognized response, or one the app couldn't read | Copy the details. If this followed a schedule attempt, check usps.com before retrying, because the pickup may already exist |

Every error screen has a Copy details button that copies the status code and
USPS error body for a bug report.

## Development

```
Pickup/App/             app entry point, AppState, flow state, launch at login, notifications
Pickup/Models/          Codable wire models (address, package, pickup)
Pickup/Services/        USPS client, token manager, Keychain, settings store, date calculator
Pickup/Views/           SwiftUI views (onboarding, address setup, form, scheduling, confirmation, errors, settings)
PickupTests/            XCTest unit tests
PickupUITests/          XCUITest end-to-end walk against the mock server
Scripts/                icon generator, mock USPS server, credential diagnostic, explainer renderer
docs/usps/              vendored USPS Carrier Pickup OpenAPI spec (the API contract)
docs/superpowers/       design spec and implementation plans
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and
[SECURITY.md](SECURITY.md) for how credentials are handled and how to report
a vulnerability.

The USPS contract is `docs/usps/carrier-pickup-v3.yaml`, the official Carrier
Pickup 3.1.10 OpenAPI spec. Build request models from its `components.schemas`,
not from the examples in USPS's GitHub README. Those are stale: their
`{"phone": ...}` contact entry is rejected by the live API.
`PickupTests/RequestContractTests.swift` checks the app's requests against the
spec, and the mock server enforces it. An unknown key, a bad enum value, a
JSON `null`, a contact entry other than `email` or `cellNumber`, or `OTHER`
without special instructions gets a USPS-style `400 OASValidation` error.

For manual testing without touching production USPS, run the mock server
(Python standard library only) and point the app at it:

```sh
python3 Scripts/mock-server.py
# in another terminal
PICKUP_BASE_URL=http://127.0.0.1:8787 .build/dd/Build/Products/Debug/Pickup.app/Contents/MacOS/Pickup
```

To exercise error handling, force specific failures:

```sh
MOCK_FAIL=403 python3 Scripts/mock-server.py       # schedule-pickup calls fail with 403
MOCK_TOKEN_FAIL=1 python3 Scripts/mock-server.py   # the token request fails
```

`PICKUP_BASE_URL` takes precedence over the test environment switch in
Settings › Account, which takes precedence over production. See
`Pickup/Services/BaseURL.swift`.

To check a set of USPS credentials from the command line, including whether
the token carries the `carrier-pickup` scope, run `sh Scripts/check-credentials.sh`.

### UI test

`make uitest` runs an XCUITest that opens the real menu bar popover and walks
the whole flow against the mock server: onboarding, address, form,
confirmation, scheduled pickups, modify, cancel, and back to a fresh form. It
also opens Settings and saves a screenshot of every screen to
`.build/uitest-screens` (override with `UISCREENS=...`). Run it from a normal
terminal rather than a sandboxed shell, because macOS UI automation has to
attach to the app. The app is launched with `PICKUP_UITEST=1`, which swaps in
a throwaway defaults suite and credential store, so your real settings are
never touched. The first run may show a notification permission prompt for
Pickup; either answer is fine. `make uitest CLEAN=1` also hides the footer's
orange mock-host label, for screenshots meant for the README.

## Limitations

- Pickups made elsewhere. Pickup lists, modifies, and cancels the pickups it
  scheduled, and that history is local to this Mac. The USPS API cannot list
  pickups, so pickups made on usps.com or on another Mac never show up.
  Removing a pickup from the list does not cancel it; use Cancel pickup.
- Pickup status. Pickup detects pickups modified on usps.com, but not ones
  cancelled there. USPS reports no status, and a cancelled pickup reads back
  exactly as it did before (same details, same ETag), so it still shows as
  scheduled in Pickup. Cancelling it in Pickup then marks it cancelled.
- Pickup On Demand (timed, paid pickups) is only available on usps.com.
- There is no business-address flag. The API has none. The optional company
  field is the only business signal sent.
- One saved address.
- Builds are not notarized.

## License

MIT. See [LICENSE](LICENSE).
