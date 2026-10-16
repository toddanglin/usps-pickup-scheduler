# Contributing to Pickup

Thanks for helping. Pickup is small on purpose: a menu bar app that does
one thing against one API. Bug fixes and polish are very welcome; for bigger
features, open an issue first so we can agree on the shape.

## Setup

- macOS 14+ and Xcode 16 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

The Xcode project is generated and gitignored; run `make generate` after
pulling or after adding files.

```sh
make generate   # Pickup.xcodeproj from project.yml
make build      # debug build, should be warning-free
make test       # unit tests (what CI runs)
make uitest     # end-to-end UI walk against the mock server, with screenshots
```

`make uitest` drives the real menu bar, so run it from a normal terminal with
accessibility permission; it is not run in CI.

## Screenshots and the explainer video

`make uitest CLEAN=1` hides the footer's orange mock-host label
("127.0.0.1:8799"), so the captures can go in the README. The popover is
translucent, so put a plain light window behind the menu bar area first, and
capture on a Retina display for 2x images.

The README's explainer (`docs/explainer.mp4` and `docs/explainer.gif`) is
rendered from those captures by `Scripts/make-explainer.py` (Pillow frames,
ffmpeg encoding, macOS `say` used only to pace the scenes; pass `--narrate` to keep the voice track). Scene text, narration and timing live in
its `storyboard()` function. To re-render:

```sh
make uitest CLEAN=1 UISCREENS=.build/explainer-screens
make explainer
```

## The mock server

`Scripts/mock-server.py` (stdlib only) imitates the USPS endpoints and
enforces the vendored OpenAPI contract in `docs/usps/carrier-pickup-v3.yaml`.
Run it and point a debug build at it with `PICKUP_BASE_URL` — see the
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

USPS changes its API behavior from time to time. If Pickup shows an error
you did not expect, open an issue and paste the text from the error screen's
**Copy details** button (status code and USPS error body), plus whether you
were on production or TEM. Redact confirmation numbers if you like.
**Never paste your Consumer Key or Secret** into an issue.
