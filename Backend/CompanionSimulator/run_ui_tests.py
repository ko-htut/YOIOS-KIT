#!/usr/bin/env python3
"""Run the real Companion UI against one explicitly selected iPhone simulator."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid


def run_logged(command, root, env, log, timeout):
    process = subprocess.Popen(command, cwd=root, env=env, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = process.wait(timeout=timeout)
        if code:
            raise subprocess.CalledProcessError(code, command[0])
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True, type=uuid.UUID)
    parser.add_argument("--only-testing", help="Optional XCTest class/method identifier")
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parents[2]
    output = root / "build" / "CompanionSimulator"
    output.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="ui-run-", dir=output))
    config_path = run_dir / "bridge-config.json"
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin",
               DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    simulator = str(args.simulator).upper()
    server_log = (run_dir / "bridge.log").open("wb")
    server = subprocess.Popen([
        "/usr/bin/python3", str(root / "Backend/CompanionSimulator/yios_simulator_bridge.py"),
        "--simulator", simulator, "--config", str(config_path),
        "--state-dir", str(output / "state" / simulator)
    ], cwd=root, env=env, stdout=server_log, stderr=subprocess.STDOUT)
    config = None
    success = False
    cleanup_ok = True
    ui_tests_started = False
    try:
        for _ in range(200):
            if server.poll() is not None:
                raise RuntimeError("The bridge could not start. Check the private bridge log.")
            if config_path.is_file():
                config = json.loads(config_path.read_text())
                break
            time.sleep(0.05)
        if config is None:
            raise RuntimeError("The bridge did not produce its session configuration.")
        if uuid.UUID(config["simulatorID"]) != args.simulator:
            raise RuntimeError("The bridge configuration does not match the requested simulator.")

        derived = root / "build/Companion/DerivedData-UITests"
        build = ["/usr/bin/xcodebuild", "build-for-testing", "-quiet", "-project",
                 str(root / "Companion/YIOSKitCompanion.xcodeproj"), "-scheme", "YIOSKitCompanion",
                 "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "id=" + simulator,
                 "-derivedDataPath", str(derived), "-parallel-testing-enabled", "NO",
                 "CODE_SIGNING_ALLOWED=NO"]
        with (run_dir / "build.log").open("wb") as log:
            run_logged(build, root, env, log, timeout=300)
        plans = list((derived / "Build/Products").glob("*.xctestrun"))
        if len(plans) != 1:
            raise RuntimeError("Expected one generated Companion test run configuration.")
        plan = plistlib.loads(plans[0].read_bytes())
        test_root = str(plans[0].parent)

        def absolute_paths(value):
            if isinstance(value, str):
                return value.replace("__TESTROOT__", test_root)
            if isinstance(value, list):
                return [absolute_paths(item) for item in value]
            if isinstance(value, dict):
                return {key: absolute_paths(item) for key, item in value.items()}
            return value

        plan = absolute_paths(plan)
        targets = []
        for configuration in plan.get("TestConfigurations", []):
            targets.extend(configuration.get("TestTargets", []))
        if not targets:
            targets = [value for value in plan.values()
                       if isinstance(value, dict) and "TestBundlePath" in value]
        if len(targets) != 1 or targets[0].get("BlueprintName") != "YIOSKitCompanionUITests":
            raise RuntimeError("Only the Companion simulator UI test target may run.")
        compact = json.dumps(config, separators=(",", ":"))
        for key in ("EnvironmentVariables", "UITargetAppEnvironmentVariables"):
            targets[0].setdefault(key, {})["YIOS_SIMULATOR_BRIDGE_CONFIG"] = compact
        private_plan = run_dir / "Companion.xctestrun"
        private_plan.write_bytes(plistlib.dumps(plan))
        test = ["/usr/bin/xcodebuild", "test-without-building", "-xctestrun", str(private_plan),
                "-destination", "id=" + simulator, "-parallel-testing-enabled", "NO",
                "-resultBundlePath", str(run_dir / "results.xcresult")]
        if args.only_testing:
            test.append("-only-testing:" + args.only_testing)
        print("Running Companion simulator UI tests. Private artifacts: " + str(run_dir), flush=True)
        with (run_dir / "test.log").open("wb") as log:
            ui_tests_started = True
            run_logged(test, root, env, log, timeout=600)
        summary = subprocess.run([
            "/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary", "--path",
            str(run_dir / "results.xcresult")
        ], cwd=root, env=env, capture_output=True, check=True, timeout=30)
        counts = json.loads(summary.stdout)
        passed = counts.get("passedTests")
        required = 1 if args.only_testing else 5
        if not isinstance(passed, int) or isinstance(passed, bool) or passed < required or \
                counts.get("totalTestCount") != passed or counts.get("failedTests") != 0 or \
                counts.get("skippedTests") != 0 or counts.get("result") != "Passed":
            raise RuntimeError("The expected UI tests did not all run and pass.")
        print("Verified XCTest results: " + str(passed) + " tests passed.", flush=True)
        success = True
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # No raw subprocess output, environment, URLs or session tokens in stdout.
        print("Simulator UI checks failed. Review the private logs in " + str(run_dir), file=sys.stderr)
        print("Failure category: " + type(error).__name__, file=sys.stderr)
    finally:
        # XCTest's iOS runner is launched by CoreSimulator, outside the host
        # xcodebuild process group. Stop only our two known test applications
        # before Clear, including on timeout, so a late client cannot set again.
        owned_apps = ("local.minthanhtut.YIOSKitCompanionUITests.xctrunner",
                      "local.minthanhtut.YIOSKitCompanion") if ui_tests_started else ()
        for bundle in owned_apps:
            try:
                subprocess.run(["/usr/bin/xcrun", "simctl", "terminate", simulator, bundle],
                               env=env, capture_output=True, timeout=12)
            except subprocess.SubprocessError:
                cleanup_ok = False
        if ui_tests_started:
            try:
                subprocess.run(["/usr/bin/xcrun", "simctl", "uninstall", simulator,
                                "local.minthanhtut.YIOSKitCompanionUITests.xctrunner"],
                               env=env, capture_output=True, timeout=12)
            except subprocess.SubprocessError:
                cleanup_ok = False
        if config is not None and server.poll() is None:
            try:
                body = json.dumps({"requestID": str(uuid.uuid4())}).encode()
                request = urllib.request.Request(config["baseURL"] + "/v1/clear", data=body,
                    headers={"Authorization": "Bearer " + config["token"], "Content-Type": "application/json"},
                    method="POST")
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(request, timeout=45) as response:
                    result = json.loads(response.read(32768))
                cleanup_ok = cleanup_ok and result.get("state") == "clearAccepted" and result.get("acknowledgement") == "accepted"
            except Exception:
                cleanup_ok = False
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=40)
            except subprocess.TimeoutExpired:
                cleanup_ok = False
                server.kill()
                server.wait(timeout=5)
        server_log.close()
        if not cleanup_ok:
            print("Simulator cleanup needs review. The bridge journal is retained; restart it and send Clear.", file=sys.stderr)
    if success and cleanup_ok:
        print("COMPANION SIMULATOR UI TEST PASS — test override cleared.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
