#!/usr/bin/python3
"""Start a private simulator bridge, install the simulator app and launch it."""

import argparse
import json
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

from yios_simulator_bridge import (BridgeError, CHILD_ENV, MAX_BODY, SIMCTL, SimulatorClient,
                                   bounded_command, canonical_uuid, decode_json, secure_directory)


def main():
    parser = argparse.ArgumentParser(description="Launch the YIOS-KIT Mock Location simulator test workspace.")
    parser.add_argument("simulator", help="Exact UUID of one already booted iPhone simulator.")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[2]
    app = project / "build/Companion/Simulator/YIOS-KIT Companion.app"
    child = None
    log = None
    try:
        target = canonical_uuid(args.simulator)
        client = SimulatorClient()
        client.verify_tool()
        client.attest(target)
        try:
            info = plistlib.loads((app / "Info.plist").read_bytes())
        except (OSError, ValueError):
            raise BridgeError("build_simulator_companion_first")
        if info.get("CFBundleIdentifier") != "local.minthanhtut.YIOSKitCompanion" or info.get("CFBundleSupportedPlatforms") != ["iPhoneSimulator"]:
            raise BridgeError("invalid_simulator_app")
        output = project / "build/CompanionSimulator"
        secure_directory(output)
        session = Path(tempfile.mkdtemp(prefix="session-", dir=str(output)))
        config_path = session / "bridge-config.json"
        log = (session / "bridge.log").open("wb")
        child = subprocess.Popen([
            "/usr/bin/python3", str(Path(__file__).with_name("yios_simulator_bridge.py")),
            "--simulator", target, "--config", str(config_path), "--state-dir", str(output / "state" / target)
        ], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=CHILD_ENV, cwd=str(project))
        deadline = time.monotonic() + 10
        while not config_path.exists():
            if child.poll() is not None:
                raise BridgeError("bridge_start_failed")
            if time.monotonic() >= deadline:
                raise BridgeError("bridge_start_timeout")
            time.sleep(0.05)
        data = config_path.read_bytes()
        if len(data) > MAX_BODY:
            raise BridgeError("invalid_configuration")
        config = decode_json(data)
        if config.get("protocol") != 1 or config.get("simulatorID") != target:
            raise BridgeError("invalid_configuration")
        # Commands use the immutable UUID, never simctl's ambiguous 'booted' alias.
        client.attest(target)
        bounded_command([SIMCTL, "install", target, str(app)], 45)
        # Termination is restricted to this test app so the new launch receives
        # the new session config. Saved Places remain in the app's data container.
        try:
            bounded_command([SIMCTL, "terminate", target, "local.minthanhtut.YIOSKitCompanion"], 10)
        except BridgeError:
            pass  # A not-running app has nothing to terminate.
        bounded_command([SIMCTL, "launch", target, "local.minthanhtut.YIOSKitCompanion"], 20,
                        simulator_launch_config=json.dumps(config, separators=(",", ":")))
        print("Simulator Companion launched with its private Mock Location bridge.", flush=True)
        print("Use the Mock Location tab. Core Location read-back is independent of the saved map pin.", flush=True)
        print("Choose Clear in the app before closing this terminal. Closing does not reset the simulator.", flush=True)
        print("Private configuration: " + str(config_path), flush=True)
        child.wait()
        return child.returncode
    except KeyboardInterrupt:
        return 0
    except (BridgeError, OSError, ValueError) as error:
        code = error.code if isinstance(error, BridgeError) else "simulator_launch_failed"
        print("Simulator Companion: " + code, file=sys.stderr)
        return 1
    finally:
        if child is not None and child.poll() is None:
            child.send_signal(signal.SIGTERM)
            try:
                child.wait(timeout=45)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        if log:
            log.close()


if __name__ == "__main__":
    raise SystemExit(main())
