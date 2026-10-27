#!/usr/bin/env python3
"""Run addon checks in isolation, without starting DOGWALK or sending events."""
import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--godot", default="godot", help="Godot executable")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="testing-floor-godot-") as directory:
    target = Path(directory)
    shutil.copytree(root / "addons/testing_floor", target / "addons/testing_floor",
                    ignore=shutil.ignore_patterns("TestingFloor.local.json"))
    (target / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Telemetry checks"\n')
    shutil.copy2(root / "tools/test_telemetry.gd", target / "test.gd")
    raise SystemExit(subprocess.call([args.godot, "--headless", "--path", str(target), "--script", "res://test.gd"]))
