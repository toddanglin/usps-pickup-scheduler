# Contributing to PickupBar

Thanks for helping. PickupBar is small on purpose: a menu bar app that does
one thing against one API. Bug fixes and polish are very welcome; for bigger
features, open an issue first so we can agree on the shape.

## Setup

- macOS 14+ and Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The Xcode project is generated and gitignored; run `make generate` after
pulling or after adding files.

```sh
make generate   # PickupBar.xcodeproj from project.yml
make build      # debug build, should be warning-free
make test       # unit tests (what CI runs)
make uitest     # end-to-end UI walk against the mock server, with screenshots
```

`make uitest` drives the real menu bar, so run it from a normal terminal with
accessibility permission; it is not run in CI.

## The mock server

`Scripts/mock-server.py` (stdlib only) imitates the USPS endpoints and
enforces the vendored OpenAPI contract in `docs/usps/carrier-pickup-v3.yaml`.
Run it and point a debug build at it with `PICKUPBAR_BASE_URL` — see the
README's Development section. Please exercise new API behavior against it
before trying production or the USPS test environment (TEM).

## Code style

- Swift 5 language mode, SwiftUI, no third-party dependencies
- Build request models from the OpenAPI spec's schemas, not USPS's README
  examples, and keep `RequestContractTests` passing
- Add or update unit tests with behavior changes

## Signing

Builds are ad-hoc signed by default, so macOS asks for Keychain access again
after every rebuild. To sign with your own identity, copy
`Local.xcconfig.example` to `Local.xcconfig` and fill it in. `Local.xcconfig`,
`.env` and `.env.*` are gitignored — keep credentials and team IDs there,
never in tracked files.

## Reporting USPS API problems

USPS changes its API behavior from time to time. If PickupBar shows an error
you did not expect, open an issue and paste the text from the error screen's
**Copy details** button (status code and USPS error body), plus whether you
were on production or TEM. Redact confirmation numbers if you like.
**Never paste your Consumer Key or Secret** into an issue.
