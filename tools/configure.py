#!/usr/bin/env python3
"""Generate the Godot addon's ignored settings from this checkout's .env."""
import argparse
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-key", action="store_true")
    args = parser.parse_args()
    env = {}
    source = ROOT / ".env"
    if source.exists():
        for line in source.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.removeprefix("export ").split("=", 1)
                env[key.strip()] = value.strip().strip("\"'")
    env.update({key: value for key, value in os.environ.items() if key.startswith("TESTING_FLOOR_")})
    key = env.get("TESTING_FLOOR_WRITE_KEY", "").strip()
    if args.require_key and (not key or key == "wk_your_key_here"):
        parser.error("Add TESTING_FLOOR_WRITE_KEY to .env before building.")
    settings = {
        "write_key": key,
        "app_version": "dogwalk-tf-0.1.0",
        "enable_in_editor": env.get("TESTING_FLOOR_ENABLE_IN_EDITOR", "0") == "1",
    }
    target = ROOT / "addons/testing_floor/TestingFloor.local.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(settings, indent=2) + "\n")
    target.chmod(0o600)
    print("Configured Testing Floor telemetry" + (" with editor collection enabled." if settings["enable_in_editor"] else "."))


if __name__ == "__main__":
    main()
