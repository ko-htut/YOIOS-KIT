#!/usr/bin/python3
"""Offline state-machine test for the restricted Mock Location bridge.

All device-facing classes are fakes. The test must never open usbmux, a tunnel,
or a developer service.
"""

import ast
import asyncio
import importlib.util
import json
import os
import pathlib
import sys


TEST_UDID = "00008030-00123456789ABCDE"
TEST_ECID = 0x123456789ABCDEF
TEST_ECID_TEXT = "0x123456789ABCDEF"


def load_bridge(path):
    saved_stdout = os.dup(1)
    saved_stderr = os.dup(2)
    try:
        spec = importlib.util.spec_from_file_location("yios_location_backend_under_test", path)
        if spec is None or spec.loader is None:
            raise AssertionError("cannot create bridge import spec")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        os.dup2(saved_stdout, 1)
        os.dup2(saved_stderr, 2)
        os.close(saved_stdout)
        os.close(saved_stderr)

    # Importing the bridge reserves a duplicate of stdout for its private JSON
    # stream. Replace it with a per-test pipe so nothing reaches test output.
    os.close(module._protocol_fd)
    return module


def run_captured(module, coroutine):
    read_fd, write_fd = os.pipe()
    module._protocol_fd = write_fd
    try:
        result = asyncio.run(asyncio.wait_for(coroutine, timeout=1.0))
    finally:
        os.close(write_fd)
        module._protocol_fd = -1

    chunks = []
    while True:
        chunk = os.read(read_fd, 4096)
        if not chunk:
            break
        chunks.append(chunk)
    os.close(read_fd)
    lines = b"".join(chunks).decode("ascii").splitlines()
    return result, [json.loads(line) for line in lines]


def fake_imports(trace, set_error=None, dvt_close_error=None, tunnel_close_error=None):
    class FakeRSD:
        udid = TEST_UDID
        product_type = "iPhone12,8"
        product_version = "17.7"

        async def get_developer_mode_status(self):
            trace.append("developer-mode")
            return True

    class FakeTunnel:
        def __init__(self, serial, autopair, remotepairing_fallback):
            assert serial == TEST_UDID
            assert autopair is False
            assert remotepairing_fallback is False
            trace.append("tunnel-init")

        async def aopen(self):
            trace.append("tunnel-open")
            return FakeRSD()

        async def aclose(self):
            trace.append("tunnel-close")
            if tunnel_close_error is not None:
                raise tunnel_close_error

    class FakeDVT:
        def __init__(self, rsd):
            assert isinstance(rsd, FakeRSD)
            trace.append("dvt-init")

        async def connect(self):
            trace.append("dvt-connect")

        async def close(self):
            trace.append("dvt-close")
            if dvt_close_error is not None:
                raise dvt_close_error

    class FakeLocation:
        def __init__(self, dvt):
            assert isinstance(dvt, FakeDVT)
            trace.append("location-init")

        async def connect(self):
            trace.append("location-connect")

        async def set(self, latitude, longitude):
            assert latitude == 16.8409
            assert longitude == 96.1735
            trace.append("location-set")
            if set_error is not None:
                raise set_error

        async def clear(self):
            trace.append("FORBIDDEN-clear")

    class FakeImports:
        UserspaceRsdTunnel = FakeTunnel
        DvtProvider = FakeDVT
        LocationSimulation = FakeLocation
        device_not_found_errors = ()
        trust_errors = ()
        unlock_errors = ()
        pairing_errors = ()
        userspace_errors = ()
        developer_mode_errors = ()
        device_busy_errors = ()
        invalid_service_errors = ()
        amfi_errors = ()
        connection_errors = ()

    return FakeImports()


def fake_reveal_imports(
    trace,
    developer_mode_enabled=False,
    paired=True,
    reported_ecid=TEST_ECID,
    reveal_error=None,
):
    class FakeLockdown:
        udid = TEST_UDID
        identifier = TEST_UDID
        product_type = "iPhone12,8"
        product_version = "17.7"

        def __init__(self):
            self.paired = paired

        @property
        def ecid(self):
            return reported_ecid

        async def get_developer_mode_status(self):
            trace.append("developer-mode-status")
            return developer_mode_enabled

        async def close(self):
            trace.append("lockdown-close")

    lockdown = FakeLockdown()

    async def create_using_usbmux(**kwargs):
        assert kwargs == {
            "serial": TEST_UDID,
            "connection_type": "USB",
            "autopair": False,
        }
        trace.append("lockdown-open")
        return lockdown

    class FakeAmfi:
        def __init__(self, supplied_lockdown):
            assert supplied_lockdown is lockdown
            trace.append("amfi-init")

        async def reveal_developer_mode_option_in_ui(self):
            trace.append("amfi-reveal")
            if reveal_error is not None:
                raise reveal_error

        async def enable_developer_mode(self):
            trace.append("FORBIDDEN-enable")
            raise AssertionError("Developer Mode enable must never be called")

        async def enable_developer_mode_post_restart(self):
            trace.append("FORBIDDEN-accept")
            raise AssertionError("post-restart accept must never be called")

    class FakeImports:
        device_not_found_errors = ()
        trust_errors = ()
        unlock_errors = ()
        pairing_errors = ()
        invalid_service_errors = ()
        amfi_errors = ()
        connection_errors = ()

    imports = FakeImports()
    imports.create_using_usbmux = create_using_usbmux
    imports.AmfiService = FakeAmfi
    return imports


def assert_invalid_request(module, request, trace):
    trace.clear()
    status, events = run_captured(
        module,
        module.execute("set-persistent", request, fake_imports(trace)),
    )
    assert status == 2
    assert events == [{
        "code": "invalid_request",
        "event": "error",
        "phase": "request",
        "protocol": 1,
        "status": "error",
    }]
    assert trace == ["event:error"]


def assert_no_process_spawning(bridge_path):
    tree = ast.parse(bridge_path.read_text(encoding="utf-8"))
    forbidden = {
        "fork",
        "forkpty",
        "daemon",
        "setsid",
        "Popen",
        "enable_developer_mode",
        "enable_developer_mode_post_restart",
        "retry_create_using_usbmux",
        "send_recv_plist",
    }
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        if isinstance(node.func, ast.Name):
            name = node.func.id
        elif isinstance(node.func, ast.Attribute):
            name = node.func.attr
        else:
            name = None
        assert name not in forbidden


def assert_persistent_close_failure(module, request, trace, **fake_options):
    trace.clear()
    status, events = run_captured(
        module,
        module.execute("set-persistent", request, fake_imports(trace, **fake_options)),
    )
    assert status == 5
    assert [event["event"] for event in events] == [
        "hello",
        "attested",
        "ready",
        "requestDispatched",
        "active",
        "error",
    ]
    assert events[-1] == {
        "code": "internal_failure",
        "event": "error",
        "phase": "persistentTeardown",
        "protocol": 1,
        "status": "uncertain",
    }
    assert trace.count("location-set") == 1
    assert trace.count("tunnel-open") == 1
    assert trace.count("dvt-close") == 1
    assert trace.count("tunnel-close") == 1
    assert "FORBIDDEN-clear" not in trace
    assert trace.index("event:active") < trace.index("dvt-close") < trace.index("tunnel-close")
    assert trace.index("tunnel-close") < trace.index("event:error")
    serialized = json.dumps(events)
    assert "synthetic DVT close detail" not in serialized
    assert "synthetic tunnel close detail" not in serialized


def assert_invalid_reveal_request(module, request, trace):
    trace.clear()
    status, events = run_captured(
        module,
        module.execute(
            "reveal-developer-mode",
            request,
            fake_reveal_imports(trace),
        ),
    )
    assert status == 2
    assert events == [{
        "code": "invalid_request",
        "event": "error",
        "phase": "request",
        "protocol": 1,
        "status": "error",
    }]
    assert trace == ["event:error"]


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: test-yios-location-backend.py BRIDGE")
    bridge_path = pathlib.Path(sys.argv[1])
    if not bridge_path.is_file():
        raise SystemExit("bridge is missing")

    assert_no_process_spawning(bridge_path)
    module = load_bridge(bridge_path)
    trace = []
    original_emit = module.emit

    def traced_emit(event, status, **fields):
        trace.append("event:" + event)
        original_emit(event, status, **fields)

    module.emit = traced_emit
    request = {
        "udid": TEST_UDID,
        "expectedProductType": "iPhone12,8",
        "latitude": "16.8409",
        "longitude": "96.1735",
    }
    status, events = run_captured(
        module,
        module.execute("set-persistent", request, fake_imports(trace)),
    )

    assert status == 0
    assert [event["event"] for event in events] == [
        "hello",
        "attested",
        "ready",
        "requestDispatched",
        "active",
    ]
    assert events[-1]["status"] == "assumedActive"
    assert events[-1]["persistence"] == "experimental"
    assert all(event["protocol"] == 1 for event in events)
    assert "FORBIDDEN-clear" not in trace
    assert trace.count("location-set") == 1
    assert trace.count("tunnel-open") == 1
    assert trace.index("event:active") < trace.index("dvt-close") < trace.index("tunnel-close")

    serialized = json.dumps(events, separators=(",", ":"))
    assert TEST_UDID not in serialized
    assert "16.8409" not in serialized
    assert "96.1735" not in serialized

    # Malformed JSON never reaches execute, and missing/extra/wrong fields fail
    # before constructing a tunnel or invoking any location method.
    assert module.parse_json_line(b'{"udid":') is None
    assert module.parse_json_line(b'[]\n') is None

    missing_coordinate = dict(request)
    del missing_coordinate["longitude"]
    assert_invalid_request(module, missing_coordinate, trace)

    extra_control_field = dict(request)
    extra_control_field["command"] = "clear"
    assert_invalid_request(module, extra_control_field, trace)

    invalid_coordinate = dict(request)
    invalid_coordinate["latitude"] = "NaN"
    assert_invalid_request(module, invalid_coordinate, trace)

    wrong_product = dict(request)
    wrong_product["expectedProductType"] = "iPhone99,9"
    assert_invalid_request(module, wrong_product, trace)

    # A failure after requestDispatched must be one-shot: one Set attempt, no
    # Clear, no retry, and deterministic context cleanup after the error event.
    trace.clear()
    status, events = run_captured(
        module,
        module.execute(
            "set-persistent",
            request,
            fake_imports(trace, set_error=OSError("synthetic private detail")),
        ),
    )
    assert status == 4
    assert [event["event"] for event in events] == [
        "hello",
        "attested",
        "ready",
        "requestDispatched",
        "error",
    ]
    assert events[-1] == {
        "code": "developer_service_unavailable",
        "event": "error",
        "phase": "set",
        "protocol": 1,
        "status": "error",
    }
    assert trace.count("location-set") == 1
    assert trace.count("tunnel-open") == 1
    assert "FORBIDDEN-clear" not in trace
    assert trace.index("event:requestDispatched") < trace.index("location-set")
    assert trace.index("event:error") < trace.index("dvt-close") < trace.index("tunnel-close")
    assert "synthetic private detail" not in json.dumps(events)

    # The Developer Mode Settings action is exact-target, USB-only, and reveal
    # only. It never pairs, enables Developer Mode, reboots, retries, opens DVT,
    # or emits the target identifiers over the protocol stream.
    reveal_request = {
        "udid": TEST_UDID,
        "expectedProductType": "iPhone12,8",
        "expectedECID": TEST_ECID_TEXT,
    }
    trace.clear()
    status, events = run_captured(
        module,
        module.execute(
            "reveal-developer-mode",
            reveal_request,
            fake_reveal_imports(trace),
        ),
    )
    assert status == 0
    assert [event["event"] for event in events] == [
        "hello",
        "attested",
        "requestDispatched",
        "developerModeOptionRequested",
    ]
    assert events[-1]["status"] == "settingsOptionExpected"
    assert trace.count("lockdown-open") == 1
    assert trace.count("amfi-reveal") == 1
    assert trace.count("lockdown-close") == 1
    assert "FORBIDDEN-enable" not in trace
    assert "FORBIDDEN-accept" not in trace
    reveal_serialized = json.dumps(events, separators=(",", ":"))
    assert TEST_UDID not in reveal_serialized
    assert TEST_ECID_TEXT not in reveal_serialized

    trace.clear()
    status, events = run_captured(
        module,
        module.execute(
            "reveal-developer-mode",
            reveal_request,
            fake_reveal_imports(trace, developer_mode_enabled=True),
        ),
    )
    assert status == 0
    assert [event["event"] for event in events] == [
        "hello",
        "attested",
        "developerModeAlreadyEnabled",
    ]
    assert events[-1]["status"] == "alreadyEnabled"
    assert "amfi-reveal" not in trace
    assert trace.count("lockdown-close") == 1

    trace.clear()
    status, events = run_captured(
        module,
        module.execute(
            "reveal-developer-mode",
            reveal_request,
            fake_reveal_imports(trace, reported_ecid=TEST_ECID + 1),
        ),
    )
    assert status == 3
    assert events[-1]["code"] == "target_mismatch"
    assert events[-1]["phase"] == "attestation"
    assert "amfi-reveal" not in trace
    assert trace.count("lockdown-close") == 1

    trace.clear()
    status, events = run_captured(
        module,
        module.execute(
            "reveal-developer-mode",
            reveal_request,
            fake_reveal_imports(trace, paired=False),
        ),
    )
    assert status == 3
    assert events[-1]["code"] == "pairing_required"
    assert events[-1]["phase"] == "pairing"
    assert "developer-mode-status" not in trace
    assert "amfi-reveal" not in trace

    for invalid_ecid in (None, "0x0", "0xabcdef", "81985529216486895", "0X1234"):
        invalid_reveal = dict(reveal_request)
        if invalid_ecid is None:
            del invalid_reveal["expectedECID"]
        else:
            invalid_reveal["expectedECID"] = invalid_ecid
        assert_invalid_reveal_request(module, invalid_reveal, trace)
    extra_reveal = dict(reveal_request)
    extra_reveal["latitude"] = "1"
    assert_invalid_reveal_request(module, extra_reveal, trace)

    trace.clear()
    status, events = run_captured(
        module,
        module.execute(
            "reveal-developer-mode",
            reveal_request,
            fake_reveal_imports(
                trace,
                reveal_error=OSError("synthetic private reveal detail"),
            ),
        ),
    )
    assert status == 4
    assert [event["event"] for event in events] == [
        "hello",
        "attested",
        "requestDispatched",
        "error",
    ]
    assert events[-1]["code"] == "developer_mode_reveal_failed"
    assert events[-1]["phase"] == "developerModeReveal"
    assert trace.count("amfi-reveal") == 1
    assert trace.count("lockdown-close") == 1
    assert "synthetic private reveal detail" not in json.dumps(events)

    # A Set acknowledgement is not a clean completion claim. DVT and tunnel
    # close failures each produce one sanitized nonzero result; both handles
    # are still attempted exactly once and finally cannot double-close them.
    assert_persistent_close_failure(
        module,
        request,
        trace,
        dvt_close_error=OSError("synthetic DVT close detail"),
    )
    assert_persistent_close_failure(
        module,
        request,
        trace,
        tunnel_close_error=OSError("synthetic tunnel close detail"),
    )
    assert_persistent_close_failure(
        module,
        request,
        trace,
        dvt_close_error=OSError("synthetic DVT close detail"),
        tunnel_close_error=OSError("synthetic tunnel close detail"),
    )

    print("LOCATION BACKEND OFFLINE SET-PERSISTENT + DEVELOPER-MODE-OPTION TEST PASS")


if __name__ == "__main__":
    main()
