#!/usr/bin/env python3
"""
mock-server.py -- local mock of the USPS API for manual QA of Pickup.

Pickup is a macOS menu bar app that schedules USPS carrier pickups. This
script stands in for the real USPS OAuth + Carrier Pickup APIs so you can
exercise the app's happy paths and error paths without hitting production.

Python 3 standard library only -- no pip dependencies.

Usage:

    # 1. Start the mock server (default port 8787):
    python3 Scripts/mock-server.py

    # 2. Point Pickup at it and launch the app:
    PICKUP_BASE_URL=http://127.0.0.1:8787 open .build/dd/Build/Products/Debug/Pickup.app

    # Force the schedule-pickup endpoint to fail with a specific status,
    # to test the app's error handling:
    MOCK_FAIL=403 python3 Scripts/mock-server.py

    # Force the token endpoint to fail (e.g. to test the app's "credentials
    # invalid" path after credentials were previously valid):
    MOCK_TOKEN_FAIL=1 python3 Scripts/mock-server.py

    # Use a different port:
    PORT=9000 python3 Scripts/mock-server.py

The schedule endpoint validates the body against the USPS OpenAPI contract
(docs/usps/carrier-pickup-v3.yaml) the way the live API does -- unknown keys,
contact entries other than {"email"} / {"cellNumber"}, enum values, JSON null,
OTHER without specialInstructions -- and answers violations with a 400
OASValidation error.

Endpoints emulated:
    POST   /oauth2/v3/token
    GET    /pickup/v3/carrier-pickup/eligibility
    POST   /pickup/v3/carrier-pickup
    GET    /pickup/v3/carrier-pickup/{confirmationNumber}
    PUT    /pickup/v3/carrier-pickup/{confirmationNumber}
    DELETE /pickup/v3/carrier-pickup/{confirmationNumber}

Pickups created by POST are kept in memory for the GET/PUT/DELETE endpoints,
which behave the way apis-tem.usps.com was observed to: GET returns an ETag
header (base64 SHA-256 of the body); PUT and DELETE require it as If-Match and
answer a stale one with the real "has been modified since" 400; a second DELETE
gets "Pickup already cancelled." (1401), a past pickup date "Pickup date is in
the past." (1100); a cancelled pickup still GETs as 200; unknown numbers 404.

Environment variables:
    PORT            Port to listen on (default: 8787)
    MOCK_FAIL       One of 400, 403, 429, 503, 500 -- forces that status
                    for POST /pickup/v3/carrier-pickup
    MOCK_TOKEN_FAIL If set to a truthy value, forces POST /oauth2/v3/token
                    to always return 401
"""

import base64
import datetime
import hashlib
import json
import os
import threading
import random
import re
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


# -- request contract ---------------------------------------------------------
#
# Mirrors `components.schemas` in docs/usps/carrier-pickup-v3.yaml (USPS Carrier
# Pickup 3.1.10), which is the contract. The live API validates the body against
# that OpenAPI spec and rejects violations with a 400 "OASValidation" error, so
# the mock does the same instead of accepting anything.

REQUEST_KEYS = {"pickupDate", "pickupAddress", "packages", "estimatedWeight",
                "pickupLocation", "nextAvailablePickup"}
REQUIRED_REQUEST_KEYS = {"pickupDate", "pickupAddress", "packages", "estimatedWeight",
                         "pickupLocation"}
PICKUP_ADDRESS_KEYS = {"firstName", "lastName", "firm", "address", "contact"}
CONTACT_KEYS = {"email", "cellNumber"}
PACKAGE_KEYS = {"packageType", "packageCount"}
PACKAGE_TYPES = {"FIRST-CLASS_PACKAGE_SERVICE", "PRIORITY_MAIL_EXPRESS", "PRIORITY_MAIL",
                 "RETURNS", "USPS_GROUND_ADVANTAGE", "INTERNATIONAL", "OTHER"}
PICKUP_LOCATION_KEYS = {"packageLocation", "specialInstructions", "dogPresent"}
PACKAGE_LOCATIONS = {"FRONT_DOOR", "BACK_DOOR", "SIDE_DOOR", "KNOCK_ON_DOOR", "MAIL_ROOM",
                     "OFFICE", "PORCH", "RECEPTION", "MAILBOX", "OTHER"}
# The order the real test environment echoes package lines in.
ECHO_PACKAGE_TYPES = ["PRIORITY_MAIL_EXPRESS", "PRIORITY_MAIL", "RETURNS",
                      "USPS_GROUND_ADVANTAGE", "INTERNATIONAL", "OTHER"]
CELL_NUMBER = re.compile(r"^\d{10}$")


def _find_null(value, path):
    """Returns the path of the first JSON null inside `value`, or None."""
    if value is None:
        return path or "/"
    if isinstance(value, dict):
        for key, child in value.items():
            found = _find_null(child, f"{path}/{key}")
            if found:
                return found
    if isinstance(value, list):
        for index, child in enumerate(value):
            found = _find_null(child, f"{path}/{index}")
            if found:
                return found
    return None


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def schedule_violations(body):
    """Lists every way `body` breaks the SchedulePickupRequest schema, as
    (path, message) pairs. Empty when the body is valid."""
    problems = []

    def unknown_keys(obj, allowed, path):
        extra = sorted(set(obj) - allowed)
        if extra:
            names = ", ".join(extra)
            problems.append((path, "Object instance has properties which are not allowed "
                                   f"by the schema: [{names}]"))

    if not isinstance(body, dict):
        return [("/", "Request body must be a JSON object")]
    null_path = _find_null(body, "")
    if null_path is not None:
        problems.append((null_path, "Instance type (null) does not match any allowed primitive type"))

    unknown_keys(body, REQUEST_KEYS, "/")
    missing = sorted(REQUIRED_REQUEST_KEYS - set(body))
    if missing:
        problems.append(("/", f"Object has missing required properties: [{', '.join(missing)}]"))

    address = body.get("pickupAddress")
    if isinstance(address, dict):
        unknown_keys(address, PICKUP_ADDRESS_KEYS, "/pickupAddress")
        for key in ("firstName", "lastName"):
            value = address.get(key)
            if not isinstance(value, str) or not 1 <= len(value) <= 50:
                problems.append((f"/pickupAddress/{key}", "must be a string of 1-50 characters"))
        if not isinstance(address.get("address"), dict):
            problems.append(("/pickupAddress", "Object has missing required properties: [address]"))
        contact = address.get("contact")
        if not isinstance(contact, list) or not 1 <= len(contact) <= 2:
            problems.append(("/pickupAddress/contact", "Array must have between 1 and 2 items"))
        else:
            for index, entry in enumerate(contact):
                path = f"/pickupAddress/contact/{index}"
                if not isinstance(entry, dict):
                    problems.append((path, "must be an object"))
                    continue
                unknown_keys(entry, CONTACT_KEYS, path)
                if len(entry) != 1:
                    problems.append((path, "Instance failed to match exactly one schema "
                                           "(email or cellNumber)"))
                if "cellNumber" in entry:
                    cell = entry["cellNumber"]
                    if not isinstance(cell, str) or not CELL_NUMBER.match(cell):
                        problems.append((f"{path}/cellNumber",
                                         'ECMA 262 regex "^\\d{10}$" does not match input string'))
                if "email" in entry:
                    email = entry["email"]
                    if not isinstance(email, str) or len(email) > 50:
                        problems.append((f"{path}/email", "must be a string of at most 50 characters"))
    elif "pickupAddress" in body:
        problems.append(("/pickupAddress", "must be an object"))

    packages = body.get("packages")
    if isinstance(packages, list):
        for index, line in enumerate(packages):
            path = f"/packages/{index}"
            if not isinstance(line, dict):
                problems.append((path, "must be an object"))
                continue
            unknown_keys(line, PACKAGE_KEYS, path)
            if line.get("packageType") not in PACKAGE_TYPES:
                problems.append((f"{path}/packageType",
                                 f"Instance value ({json.dumps(line.get('packageType'))}) not found in enum"))
            if not _is_int(line.get("packageCount")):
                problems.append((f"{path}/packageCount", "Instance type does not match integer"))
    elif "packages" in body:
        problems.append(("/packages", "must be an array"))

    location = body.get("pickupLocation")
    if isinstance(location, dict):
        unknown_keys(location, PICKUP_LOCATION_KEYS, "/pickupLocation")
        if location.get("packageLocation") not in PACKAGE_LOCATIONS:
            problems.append(("/pickupLocation/packageLocation",
                             f"Instance value ({json.dumps(location.get('packageLocation'))}) not found in enum"))
        if location.get("packageLocation") == "OTHER":
            instructions = location.get("specialInstructions")
            if not isinstance(instructions, str) or not instructions.strip():
                problems.append(("/pickupLocation/specialInstructions",
                                 "specialInstructions is required when packageLocation is OTHER"))
    elif "pickupLocation" in body:
        problems.append(("/pickupLocation", "must be an object"))

    return problems


def oas_validation_error(problems):
    """A 400 body shaped like the one the live API returns."""
    path, message = problems[0]
    return {
        "apiVersion": "/pickup/v3/",
        "error": {
            "code": "400",
            "message": "OASValidation OpenAPI-Spec-Validation-Carrier-Pickup with resource "
                       f"'oas://carrier-pickup.yaml': failed with reason: "
                       f"'[ERROR - [Path '{path}'] {message}]'",
            "errors": [
                {"status": "400", "code": "OASValidation", "title": "OASValidation",
                 "detail": f"[Path '{p}'] {m}", "source": {"parameter": p}}
                for p, m in problems
            ],
        },
    }


def schedule_echo(body):
    """`carrierPickupRequest` the way the live test environment echoes it:
    names and address upper-cased, a ZIP+4 filled in, `{}` for a cell number
    it did not keep, and one line per package type, zero counts included."""
    address = body.get("pickupAddress", {})
    postal = dict(address.get("address", {}))
    for key in ("streetAddress", "secondaryAddress", "city", "state"):
        if isinstance(postal.get(key), str):
            postal[key] = postal[key].upper().replace("'", "")
    postal.setdefault("ZIPPlus4", "0001")
    contact = [{"email": entry["email"].upper()} if "email" in entry else {}
               for entry in address.get("contact", [])]
    counts = {line["packageType"]: line["packageCount"] for line in body.get("packages", [])}
    echo_address = {"firstName": address.get("firstName", "").upper(),
                    "lastName": address.get("lastName", "").upper()}
    if address.get("firm"):
        echo_address["firm"] = address["firm"].upper()
    echo_address["address"] = postal
    echo_address["contact"] = contact
    return {
        "pickupDate": body.get("pickupDate"),
        "pickupAddress": echo_address,
        "packages": [{"packageType": t, "packageCount": counts.get(t, 0)} for t in ECHO_PACKAGE_TYPES],
        "estimatedWeight": body.get("estimatedWeight"),
        "pickupLocation": body.get("pickupLocation"),
    }


# -- stored pickups (GET / PUT / DELETE) ----------------------------------------

PICKUPS = {}  # confirmation number -> {"pickupDate", "request", "cancelled"}
PICKUPS_LOCK = threading.Lock()
PICKUP_PATH = re.compile(r"^/pickup/v3/carrier-pickup/([A-Za-z0-9]+)$")


def stored_echo(request):
    """`carrierPickupRequest` the way the live GET returns it: like the
    schedule echo, but with the cell number kept and an email as `{}`."""
    echo = schedule_echo(request)
    echo["pickupAddress"]["contact"] = [
        {"cellNumber": entry["cellNumber"]} if "cellNumber" in entry else {}
        for entry in request.get("pickupAddress", {}).get("contact", [])
    ]
    return echo


def pickup_body(number, pickup):
    return {"confirmationNumber": number,
            "pickupDate": pickup["pickupDate"],
            "carrierPickupRequest": stored_echo(pickup["request"])}


def etag_for(body):
    digest = hashlib.sha256(json.dumps(body, sort_keys=True).encode("utf-8")).digest()
    return base64.b64encode(digest).decode("ascii")


def modified_since_error(number):
    return {"error": {"message": f"The resource, /pickup/v3/carrier-pickup/{number} has been modified "
                                 "since the update indicated by the If-Match request header.",
                      "errors": []}}


ALREADY_CANCELLED_ERROR = {"error": {"code": "400", "message": "Pickup already cancelled.",
                                     "errors": [{"title": "Pickup already cancelled.",
                                                 "detail": "Pickup already cancelled.", "code": "1401"}]}}

PAST_DATE_ERROR = {"error": {"message": "Pickup date is in the past.",
                             "errors": [{"code": "1100", "title": "Pickup date is in the past.",
                                         "detail": "Pickup date is in the past."}]}}


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
    server_version = "PickupMockUSPS/1.0"

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

    def _send_json_etag(self, status, payload, etag):
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("ETag", etag)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self._log(status, payload)

    def _send_empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()
        self._log(status, None)

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
        match = PICKUP_PATH.match(path)
        if match:
            return self._handle_get_pickup(match.group(1))

        self._not_found()

    def do_PUT(self):
        match = PICKUP_PATH.match(urllib.parse.urlparse(self.path).path)
        if match:
            return self._handle_update_pickup(match.group(1))
        self._not_found()

    def do_DELETE(self):
        match = PICKUP_PATH.match(urllib.parse.urlparse(self.path).path)
        if match:
            return self._handle_cancel_pickup(match.group(1))
        self._not_found()

    def _unknown_pickup(self, number):
        self._send_json(404, {"error": {"code": "404",
                                        "message": f"No pickup with confirmation number {number}."}})

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
                "scope": "addresses carrier-pickup labels locations",
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
                }
            },
        )

    # -- endpoint 3: schedule pickup -----------------------------------------

    def _handle_schedule_pickup(self):
        if not self._bearer_ok():
            self._unauthorized()
            return

        body = self._parsed_body()

        problems = schedule_violations(body)
        if problems:
            self._send_json(400, oas_validation_error(problems))
            return

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
        with PICKUPS_LOCK:
            PICKUPS[confirmation_number] = {"pickupDate": pickup_date, "request": body,
                                            "cancelled": False}

        self._send_json(
            200,
            {
                "confirmationNumber": confirmation_number,
                "pickupDate": pickup_date,
                "carrierPickupRequest": schedule_echo(body),
            },
        )


    def _handle_get_pickup(self, number):
        if not self._bearer_ok():
            return self._unauthorized()
        with PICKUPS_LOCK:
            pickup = PICKUPS.get(number)
            if pickup is None:
                return self._unknown_pickup(number)
            body = pickup_body(number, pickup)
        # A cancelled pickup still reads back as 200 with the same body.
        self._send_json_etag(200, body, etag_for(body))

    def _handle_update_pickup(self, number):
        if not self._bearer_ok():
            return self._unauthorized()
        payload = self._parsed_body()
        with PICKUPS_LOCK:
            pickup = PICKUPS.get(number)
            if pickup is None:
                return self._unknown_pickup(number)
            current = etag_for(pickup_body(number, pickup))
            if self.headers.get("If-Match") != current:
                return self._send_json(400, modified_since_error(number))
            if pickup["cancelled"]:
                return self._send_json(400, ALREADY_CANCELLED_ERROR)
            if not isinstance(payload, dict):
                return self._send_json(400, oas_validation_error([("/", "Request body must be a JSON object")]))
            problems = []
            extra = sorted(set(payload) - {"pickupDate", "carrierPickupRequest"})
            if extra:
                problems.append(("/", "Object instance has properties which are not allowed by the "
                                      f"schema: [{', '.join(extra)}]"))
            if "pickupDate" not in payload or "carrierPickupRequest" not in payload:
                problems.append(("/", "Object has missing required properties: "
                                      "[carrierPickupRequest, pickupDate]"))
            inner = payload.get("carrierPickupRequest")
            # The spec does not forbid nextAvailablePickup inside it; it is ignored.
            problems += [(f"/carrierPickupRequest{p if p != '/' else ''}", m)
                         for p, m in schedule_violations(inner)]
            if problems:
                return self._send_json(400, oas_validation_error(problems))
            pickup["pickupDate"] = payload["pickupDate"]
            pickup["request"] = dict(inner, pickupDate=payload["pickupDate"])
            body = pickup_body(number, pickup)
        self._send_json_etag(200, body, etag_for(body))

    def _handle_cancel_pickup(self, number):
        if not self._bearer_ok():
            return self._unauthorized()
        with PICKUPS_LOCK:
            pickup = PICKUPS.get(number)
            if pickup is None:
                return self._unknown_pickup(number)
            if pickup["cancelled"]:
                return self._send_json(400, ALREADY_CANCELLED_ERROR)
            if self.headers.get("If-Match") != etag_for(pickup_body(number, pickup)):
                return self._send_json(400, modified_since_error(number))
            try:
                day = datetime.date.fromisoformat(pickup["pickupDate"])
            except (TypeError, ValueError):
                day = None
            if day is not None and day < datetime.date.today():
                return self._send_json(400, PAST_DATE_ERROR)
            pickup["cancelled"] = True
        self._send_empty(200)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), MockHandler)
    print(f"Pickup mock USPS server listening on http://127.0.0.1:{PORT}")
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
