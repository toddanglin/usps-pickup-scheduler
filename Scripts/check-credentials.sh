#!/bin/sh
# Diagnose USPS API credentials for Pickup.
#
# Usage (run in Terminal; it prompts, so it needs an interactive shell):
#   sh Scripts/check-credentials.sh
# or non-interactively:
#   USPS_KEY=... USPS_SECRET=... sh Scripts/check-credentials.sh
# or put USPS_KEY=... and USPS_SECRET=... in a .env file at the repo root (gitignored).
#   USPS_TEM=1 ... to hit the USPS test environment instead of production.
#
# It fetches a token, prints the scopes/products USPS granted, and then calls
# the Carrier Pickup eligibility endpoint so you can see the real status and body.

set -u
# Load a local .env (gitignored) if present: USPS_KEY=..., USPS_SECRET=..., optional USPS_TEM=1
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi
BASE="https://apis.usps.com"
[ "${USPS_TEM:-0}" = "1" ] && BASE="https://apis-tem.usps.com"

if [ -z "${USPS_KEY:-}" ]; then printf "Consumer Key: "; read -r USPS_KEY; fi
if [ -z "${USPS_SECRET:-}" ]; then
  printf "Consumer Secret (hidden): "; stty -echo 2>/dev/null; read -r USPS_SECRET; stty echo 2>/dev/null; echo
fi

echo
echo "== 1. Token request ($BASE/oauth2/v3/token)"
TOKEN_JSON=$(curl -sS -X POST "$BASE/oauth2/v3/token" \
  -H 'Content-Type: application/json' \
  -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"$USPS_KEY\",\"client_secret\":\"$USPS_SECRET\"}")

TOKEN=$(printf '%s' "$TOKEN_JSON" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("", end=""); sys.exit(0)
print("   scope:        ", d.get("scope"), file=sys.stderr)
print("   api_products: ", d.get("api_products"), file=sys.stderr)
print("   expires_in:   ", d.get("expires_in"), file=sys.stderr)
if "error" in d: print("   error:        ", d.get("error"), d.get("error_description",""), file=sys.stderr)
print(d.get("access_token",""), end="")')

if [ -z "$TOKEN" ]; then
  echo "   No access token returned. Raw response:"; echo "$TOKEN_JSON"; exit 1
fi

case " $(printf '%s' "$TOKEN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("scope",""))') " in
  *" carrier-pickup "*|*" pickup "*) echo "   OK: the token includes the 'carrier-pickup' scope." ;;
  *) echo "   PROBLEM: the token does NOT include the 'carrier-pickup' scope."
     echo "   In the USPS developer portal, add the Carrier Pickup API product to this app"
     echo "   (or ask USPS API Support to enable it), then retry." ;;
esac

echo
echo "== 2. Eligibility request ($BASE/pickup/v3/carrier-pickup/eligibility)"
curl -sS -i "$BASE/pickup/v3/carrier-pickup/eligibility?streetAddress=1600%20Pennsylvania%20Ave%20NW&city=Washington&state=DC&ZIPCode=20500" \
  -H 'Accept: application/json' -H "Authorization: Bearer $TOKEN" | sed -n '1p;/^{/,$p' | head -40
echo
