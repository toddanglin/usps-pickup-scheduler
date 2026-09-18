#!/usr/bin/env python3
"""
mock-server.py -- local mock of the USPS API for manual QA of PickupBar.

PickupBar is a macOS menu bar app that schedules USPS carrier pickups. This
script stands in for the real USPS OAuth + Carrier Pickup APIs so you can
exercise the app's happy paths and error paths without hitting production.

Python 3 standard library only -- no pip dependencies.

Usage:

    # 1. Start the mock server (default port 8787):
    python3 Scripts/mock-server.py

    # 2. Point PickupBar at it and launch the app:
    PICKUPBAR_BASE_URL=http://127.0.0.1:8787 open .build/dd/Build/Products/Debug/PickupBar.app

    # Force the schedule-pickup endpoint to fail with a specific status,
    # to test the app's error handling:
    MOCK_FAIL=403 python3 Scripts/mock-server.py

    # Force the token endpoint to fail (e.g. to test the app's "credentials
    # invalid" path after credentials were previously valid):
    MOCK_TOKEN_FAIL=1 python3 Scripts/mock-server.py

    # Use a different port:
    PORT=9000 python3 Scripts/mock-server.py

Endpoints emulated:
    POST /oauth2/v3/token
    GET  /pickup/v3/carrier-pickup/eligibility
    POST /pickup/v3/carrier-pickup

Environment variables:
    PORT            Port to listen on (default: 8787)
    MOCK_FAIL       One of 400, 403, 429, 503, 500 -- forces that status
                    for POST /pickup/v3/carrier-pickup
    MOCK_TOKEN_FAIL If set to a truthy value, forces POST /oauth2/v3/token
                    to always return 401
"""

import json
import os
import random
import string
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8787"))
MOCK_FAIL = os.environ.get("MOCK_FAIL", "").strip()
MOCK_TOKEN_FAIL = os.environ.get("MOCK_TOKEN_FAIL", "").strip() not in ("", "0", "false", "False")


def random_digits(n):
    return "".join(random.choice(string.digits) for _ in range(n))


def random_token_suffix(n=24):
    alphabet = string.ascii_lowercase + string.digits
    return "".join(random.choice(alphabet) for _ in range(n))


SCHEDULE_ERROR_BODIES = {
    "400": (
        400,
        {
            "apiVersion": "3.1.10",
            "error": {
                "code": "400",
                "message": "Invalid pickup request.",
                "errors": [
                    {"code": "E-2001", "message": "pickupDate must be a future date."}
                ],
            },
        },
    ),
    "403": (
        403,
        {
            "error": {
                "code": "403",
                "message": "Access denied. Client not entitled to Carrier Pickup product.",
            }
        },
    ),
    "429": (
        429,
        {"error": {"code": "429", "message": "Too many requests."}},
    ),
    "503": (
        503,
        {"error": {"code": "503", "message": "Service unavailable."}},
    ),
    # 500 is handled specially below: plain text, not JSON.
}


class MockHandler(BaseHTTPRequestHandler):
    server_version = "PickupBarMockUSPS/1.0"

    # -- helpers ---------------------------------------------------------

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return b""
        return self.rfile.read(length)

    def _parsed_body(self):
        """Parse the request body as JSON or form-encoded, returning a dict."""
        raw = self._read_body()
        if not raw:
            return {}
        content_type = self.headers.get("Content-Type", "")
        text = raw.decode("utf-8", errors="replace")
        if "application/json" in content_type:
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return {}
        # application/x-www-form-urlencoded or unspecified -- try form first.
        try:
            parsed = urllib.parse.parse_qs(text, keep_blank_values=True)
            if parsed:
                return {k: v[0] for k, v in parsed.items()}
        except Exception:
            pass
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return {}

    def _send_json(self, status, payload):
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self._log(status, payload)

    def _send_text(self, status, text):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self._log(status, text)

    def _log(self, status, payload):
        print(f"[{self.log_date_time_string()}] {self.command} {self.path} -> {status}")
        if payload is not None and payload != "":
            if isinstance(payload, (dict, list)):
                print(json.dumps(payload, indent=2))
            else:
                print(payload)
        sys.stdout.flush()

    def _bearer_ok(self):
        auth = self.headers.get("Authorization", "")
        return auth.startswith("Bearer ") and len(auth) > len("Bearer ")

    def _unauthorized(self):
        self._send_json(401, {"error": {"code": "401", "message": "Unauthorized"}})

    def log_message(self, fmt, *args):
        # Suppress default BaseHTTPRequestHandler stderr access logging;
        # we do our own structured logging in _log().
        pass

    # -- routes -----------------------------------------------------------

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/oauth2/v3/token":
            return self._handle_token()
        if path == "/pickup/v3/carrier-pickup":
            return self._handle_schedule_pickup()

        self._not_found()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/pickup/v3/carrier-pickup/eligibility":
            return self._handle_eligibility(parsed)

        self._not_found()

    def _not_found(self):
        self._send_json(
            404,
            {"error": {"code": "404", "message": f"No route for {self.command} {self.path}"}},
        )

    # -- endpoint 1: oauth token -------------------------------------------

    def _handle_token(self):
        body = self._parsed_body()

        if MOCK_TOKEN_FAIL:
            self._send_json(
                401,
                {
                    "error": "invalid_client",
                    "error_description": "Client authentication failed.",
                },
            )
            return

        client_id = body.get("client_id")
        client_secret = body.get("client_secret")

        if client_id == "bad" or client_secret == "bad":
            self._send_json(
                401,
                {
                    "error": "invalid_client",
                    "error_description": "Client authentication failed.",
                },
            )
            return

        token = f"mock-token-{random_token_suffix()}"
        self._send_json(
            200,
            {
                "access_token": token,
                "token_type": "Bearer",
                "issued_at": int(time.time() * 1000),
                "expires_in": 28799,
                "scope": "pickup addresses",
                "status": "approved",
            },
        )

    # -- endpoint 2: eligibility --------------------------------------------

    def _handle_eligibility(self, parsed):
        if not self._bearer_ok():
            self._unauthorized()
            return

        qs = urllib.parse.parse_qs(parsed.query)

        def qget(key, default=""):
            values = qs.get(key)
            return values[0] if values else default

        street = qget("streetAddress")
        secondary = qget("secondaryAddress", "")
        city = qget("city")
        state = qget("state")
        zip_code = qget("ZIPCode")

        if zip_code == "00000":
            self._send_json(
                400,
                {
                    "apiVersion": "3.1.10",
                    "error": {
                        "code": "400",
                        "message": "Address not eligible for carrier pickup.",
                        "errors": [
                            {"code": "E-1000", "message": "The address could not be matched."}
                        ],
                    },
                },
            )
            return

        self._send_json(
            200,
            {
                "pickupAddress": {
                    "firstName": None,
                    "lastName": None,
                    "firm": None,
                    "address": {
                        "streetAddress": street.upper(),
                        "secondaryAddress": secondary if secondary else None,
                        "city": city.upper(),
                        "state": state.upper(),
                        "ZIPCode": zip_code,
                        "ZIPPlus4": "2520",
                        "urbanization": None,
                    },
                    "contact": [
                        {"eMail": None},
                        {"phone": None, "extension": None},
                    ],
                }
            },
        )

    # -- endpoint 3: schedule pickup -----------------------------------------

    def _handle_schedule_pickup(self):
        if not self._bearer_ok():
            self._unauthorized()
            return

        body = self._parsed_body()

        # Sleep to make the app's progress animation visible during manual QA.
        time.sleep(1.5)

        if MOCK_FAIL == "500":
            self._send_text(500, "Internal Server Error")
            return

        if MOCK_FAIL in SCHEDULE_ERROR_BODIES:
            status, payload = SCHEDULE_ERROR_BODIES[MOCK_FAIL]
            self._send_json(status, payload)
            return

        confirmation_number = f"WTC{random_digits(9)}"
        pickup_date = body.get("pickupDate")

        self._send_json(
            200,
            {
                "confirmationNumber": confirmation_number,
                "pickupDate": pickup_date,
                "carrierPickupRequest": body,
            },
        )


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), MockHandler)
    print(f"PickupBar mock USPS server listening on http://127.0.0.1:{PORT}")
    if MOCK_FAIL:
        print(f"MOCK_FAIL={MOCK_FAIL} -- POST /pickup/v3/carrier-pickup will be forced to fail")
    if MOCK_TOKEN_FAIL:
        print("MOCK_TOKEN_FAIL set -- POST /oauth2/v3/token will always return 401")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
