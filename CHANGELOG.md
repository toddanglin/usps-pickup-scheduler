# Changelog

## 1.0.3

- Fixed: a newly scheduled pickup could get a red dot as if changed on
  usps.com when nothing had changed. USPS rounds the weight up to a whole
  pound, upper-cases the instructions, names and address, and leaves out "no
  dog"; Pickup now stores USPS's copy when it schedules or saves a pickup,
  compares the pickup rather than the exact text, and never flags a pickup
  the first time it checks it.
- Scheduled pickups re-checks with USPS at most every five minutes on its
  own. A Refresh button at the bottom of the list checks right away (at most
  once every ten seconds).

## 1.0.2

- Opening Scheduled pickups quietly re-checks upcoming pickups with USPS in
  the background and updates them from what USPS has. A pickup that changed
  on usps.com gets a small red dot until the next time the list is opened (or
  until you modify or cancel it in Pickup). A pickup cancelled on usps.com
  cannot be detected: USPS reads it back unchanged.

## 1.0.1

- Renamed from PickupBar to **Pickup** (bundle id `com.toddanglin.Pickup`).
- If you built PickupBar from source: your USPS credentials migrate
  automatically on first launch (macOS asks for permission to read the ones
  PickupBar stored in the Keychain; choose Always Allow). Re-enter your
  address once; defaults and pickup history do not carry over.

## 1.0.0

- Initial release.
