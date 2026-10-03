#!/usr/bin/env python3
"""Copies the UI test's screenshots out of its result bundle.

    export-uitest-screenshots.py <result.xcresult> <output dir>

The UI-test runner is sandboxed (it inherits the app's entitlements), so it
can only write PNGs inside its own container, and on recent macOS reading
another app's container from a shell is gated behind an "access data from
other apps" prompt: a plain `cp` out of it fails silently until someone
answers. Every screenshot is also attached to the .xcresult, which lives in
.build and needs no permission, so export the attachments and give them back
their names ("08-history.png" rather than "08-history_0_<UUID>.png").
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    bundle, out_dir = sys.argv[1], sys.argv[2]
    if not os.path.isdir(bundle):
        print(f"export-uitest-screenshots: no result bundle at {bundle}", file=sys.stderr)
        return 1
    os.makedirs(out_dir, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        result = subprocess.run(
            ["xcrun", "xcresulttool", "export", "attachments",
             "--path", bundle, "--output-path", tmp],
            capture_output=True, text=True)
        if result.returncode != 0:
            print("export-uitest-screenshots: xcresulttool failed:\n" + result.stderr,
                  file=sys.stderr)
            return 1

        with open(os.path.join(tmp, "manifest.json")) as f:
            manifest = json.load(f)

        count = 0
        for test in manifest:
            for attachment in test.get("attachments", []):
                exported = attachment.get("exportedFileName")
                name = attachment.get("suggestedHumanReadableName") or exported
                if not exported or not name.lower().endswith(".png"):
                    continue
                # "08-history_0_1A2B...-....png" -> "08-history.png"
                name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(?=\.png$)", "", name)
                shutil.copyfile(os.path.join(tmp, exported), os.path.join(out_dir, name))
                count += 1

    print(f"Exported {count} screenshots from {bundle}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
