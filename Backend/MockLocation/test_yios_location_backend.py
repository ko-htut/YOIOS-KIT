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
from types import SimpleNamespace
from typing import Optional


TEST_UDID = "00008030-00123456789ABCDE"
TEST_ECID = 0x123456789ABCDEF
TEST_ECID_TEXT = "0x123456789ABCDEF"


class FakeMissingValueError(Exception):
    pass


class FakeXpcUInt64Type(int):
    pass


class FakeXpcInt64Type(int):
    pass


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


def fake_imports(
    trace,
    set_error=None,
    dvt_close_error=None,
    tunnel_close_error=None,
    reported_product_type="iPhone12,8",
    reported_udid=TEST_UDID,
    product_version="17.7",
    allow_clear=False,
    transport="usb",
    reported_ecid=TEST_ECID,
    lockdown_product_type=None,
    lockdown_ecid=None,
    paired=True,
    connection_lost=False,
    lockdown_connection_type="Network",
    dvt_close_blocks=False,
    tunnel_close_blocks=False,
):
    class FakeRSD:
        udid = reported_udid
        product_type = reported_product_type
        ecid = reported_ecid

        def __init__(self):
            self.product_version = product_version

        async def get_developer_mode_status(self):
            trace.append("developer-mode")
            return True

    class FakeTunnel:
        def __init__(self, serial, autopair, remotepairing_fallback, connection_type, auto_reconnect):
            assert serial == TEST_UDID
            assert autopair is False
            assert auto_reconnect is False
            assert remotepairing_fallback is False
            assert connection_type == ("Network" if transport == "wifi" else "USB")
            trace.append("tunnel-init")

        async def aopen(self):
            trace.append("tunnel-open")
            return FakeRSD()

        async def aclose(self):
            trace.append("tunnel-close")
            if tunnel_close_blocks:
                await asyncio.Event().wait()
            if tunnel_close_error is not None:
                raise tunnel_close_error

        async def wait_closed(self):
            trace.append("transport-wait")
            if not connection_lost:
                await asyncio.Event().wait()

    class FakeDVT:
        def __init__(self, rsd):
            assert isinstance(rsd, FakeRSD)
            trace.append("dvt-init")

        async def connect(self):
            trace.append("dvt-connect")

        async def close(self):
            trace.append("dvt-close")
            if dvt_close_blocks:
                await asyncio.Event().wait()
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
            trace.append("location-clear" if allow_clear else "FORBIDDEN-clear")

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

    imports = FakeImports()
    async def create_using_usbmux(**kwargs):
        assert transport == "wifi"
        assert kwargs == {
            "serial": TEST_UDID, "connection_type": "Network", "autopair": False,
            "auto_reconnect": False,
        }
        trace.append("network-lockdown-open")
        async def close():
            trace.append("network-lockdown-close")
        return SimpleNamespace(
            udid=reported_udid,
            product_type=lockdown_product_type or reported_product_type,
            ecid=reported_ecid if lockdown_ecid is None else lockdown_ecid,
            product_version=product_version, paired=paired, close=close,
            service=SimpleNamespace(mux_device=SimpleNamespace(connection_type=lockdown_connection_type)),
        )
    imports.create_using_usbmux = create_using_usbmux
    return imports


def fake_reveal_imports(
    trace,
    developer_mode_enabled=False,
    paired=True,
    reported_ecid=TEST_ECID,
    reveal_error=None,
    reported_product_type="iPhone12,8",
    reported_udid=TEST_UDID,
    product_version="17.7",
    wifi_enabled=False,
    wifi_error=None,
    wifi_setting_sticks=True,
    wifi_initial_read_error=None,
    wifi_readback_error=None,
):
    class FakeLockdown:
        udid = reported_udid
        identifier = reported_udid
        product_type = reported_product_type

        def __init__(self):
            self.paired = paired
            self.product_version = product_version
            self.service = SimpleNamespace(mux_device=SimpleNamespace(connection_type="USB"))
            self.wifi_enabled = wifi_enabled
            self.wifi_status_reads = 0

        @property
        def ecid(self):
            return reported_ecid

        async def get_developer_mode_status(self):
            trace.append("developer-mode-status")
            return developer_mode_enabled

        async def close(self):
            trace.append("lockdown-close")

        async def get_enable_wifi_connections(self):
            trace.append("wifi-status")
            self.wifi_status_reads += 1
            error = wifi_initial_read_error if self.wifi_status_reads == 1 else wifi_readback_error
            if error is not None:
                raise error
            return self.wifi_enabled

        async def set_enable_wifi_connections(self, value):
            assert value is True
            trace.append("wifi-enable")
            if wifi_error is not None:
                raise wifi_error
            if wifi_setting_sticks:
                self.wifi_enabled = value

    lockdown = FakeLockdown()

    async def create_using_usbmux(**kwargs):
        assert kwargs == {
            "serial": TEST_UDID,
            "connection_type": "USB",
            "autopair": False,
            "auto_reconnect": False,
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
        missing_value_errors = (FakeMissingValueError,)
        amfi_errors = ()
        connection_errors = ()
        userspace_errors = ()
        developer_mode_errors = ()
        device_busy_errors = ()

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


def operation_request(command, product_type):
    request = {"udid": TEST_UDID, "expectedProductType": product_type}
    if command in ("set", "set-persistent"):
        request.update(latitude="16.8409", longitude="96.1735")
    elif command == "reveal-developer-mode":
        request["expectedECID"] = TEST_ECID_TEXT
    return request


def assert_generic_iphone_targets(module, trace):
    # These are identity-policy fixtures, not claims that every older model
    # can run the required iOS build. OS capability is checked independently.
    product_types = (
        "iPhone8,4", "iPhone9,3", "iPhone11,8", "iPhone12,8",
        "iPhone13,1", "iPhone15,2", "iPhone17,2", "iPhone99,9", "iPhone1,0",
    )
    commands = ("probe", "set", "set-persistent", "clear", "reveal-developer-mode")
    original_read_stdin_line = module.read_stdin_line

    async def clear_live_session():
        return b'{"command":"clear"}\n'

    module.read_stdin_line = clear_live_session
    try:
        for product_type in product_types:
            assert module.parse_product_type(product_type) == product_type
            for command in commands:
                trace.clear()
                imports = (
                    fake_reveal_imports(trace, reported_product_type=product_type)
                    if command == "reveal-developer-mode"
                    else fake_imports(trace, reported_product_type=product_type, allow_clear=True)
                )
                status, events = run_captured(
                    module,
                    module.execute(command, operation_request(command, product_type), imports),
                )
                assert status == 0, (command, product_type, events)
                attested = [event for event in events if event["event"] == "attested"]
                assert len(attested) == 1
                assert attested[0]["product_type"] == product_type
                assert all(event["event"] != "error" for event in events)
                assert TEST_UDID not in json.dumps(events)
                if command == "probe":
                    assert "location-set" not in trace and "location-clear" not in trace
                elif command == "set":
                    assert trace.count("location-set") == 1
                    assert trace.count("location-clear") == 1
                elif command == "set-persistent":
                    assert trace.count("location-set") == 1
                    assert "location-clear" not in trace
                elif command == "clear":
                    assert "location-set" not in trace
                    assert trace.count("location-clear") == 1
                else:
                    assert trace.count("amfi-reveal") == 1

        for invalid_product in (
            None, True, 12, "", "iPad13,1", "iPod9,1", "AppleTV6,2",
            "iphone13,1", " iPhone13,1", "iPhone13,1 ", "iPhone13,1\n",
            "iPhone0,1", "iPhone01,1", "iPhone13,01", "iPhone13,-1",
            "iPhone13,+1", "iPhone١٣,1", "iPhone13,1;clear", "iPhone13,1,2",
            "iPhone9223372036854775808,1", "iPhone1,9223372036854775808",
            "iPhone" + "9" * 40 + ",1",
        ):
            assert module.parse_product_type(invalid_product) is None
            for command in commands:
                trace.clear()
                imports = fake_reveal_imports(trace) if command == "reveal-developer-mode" else fake_imports(trace)
                status, events = run_captured(
                    module,
                    module.execute(command, operation_request(command, invalid_product), imports),
                )
                assert status == 2, (command, invalid_product, events)
                assert len(events) == 1 and events[0]["code"] == "invalid_request"
                assert trace == ["event:error"]

        # Accepting all iPhone models never permits a different matching-class
        # phone to receive the request. Identity must agree before opening DVT
        # or dispatching the AMFI Settings request.
        for command in commands:
            for mismatch in (
                {"reported_product_type": "iPhone15,2"},
                {"reported_product_type": "iPad13,1"},
                {"reported_product_type": None},
                {"reported_udid": "00008030-00123456789ABCDF"},
            ):
                trace.clear()
                imports = (
                    fake_reveal_imports(trace, **mismatch)
                    if command == "reveal-developer-mode"
                    else fake_imports(trace, **mismatch)
                )
                status, events = run_captured(
                    module,
                    module.execute(command, operation_request(command, "iPhone13,1"), imports),
                )
                assert status == 3, (command, mismatch, events)
                assert events[-1]["code"] == "target_mismatch"
                assert all(event["event"] not in ("attested", "ready", "requestDispatched") for event in events)
                assert "dvt-init" not in trace and "amfi-reveal" not in trace
                assert "location-set" not in trace and "FORBIDDEN-clear" not in trace

        for command in commands:
            for os_version in ("15.8", "17.3", None, "invalid"):
                trace.clear()
                imports = (
                    fake_reveal_imports(trace, product_version=os_version)
                    if command == "reveal-developer-mode"
                    else fake_imports(trace, product_version=os_version)
                )
                status, events = run_captured(
                    module,
                    module.execute(command, operation_request(command, "iPhone12,8"), imports),
                )
                assert status == 3, (command, os_version, events)
                assert all(event["event"] not in ("attested", "ready", "requestDispatched") for event in events)
                assert "dvt-init" not in trace and "amfi-reveal" not in trace
    finally:
        module.read_stdin_line = original_read_stdin_line


def assert_wifi_contract(module, trace):
    identity = {
        "udid": TEST_UDID, "expectedProductType": "iPhone12,8",
        "expectedECID": TEST_ECID_TEXT,
    }
    for already_enabled in (False, True):
        trace.clear()
        status, events = run_captured(module, module.execute(
            "enable-wifi", identity, fake_reveal_imports(trace, wifi_enabled=already_enabled),
        ))
        assert status == 0
        assert [event["event"] for event in events] == [
            "hello", "attested", "requestDispatched", "wifiEnabled",
        ]
        assert events[-1]["status"] == "ok"
        assert trace.count("wifi-status") == (1 if already_enabled else 2)
        assert trace.count("wifi-enable") == (0 if already_enabled else 1)
        assert trace.index("event:attested") < trace.index("wifi-status")
        assert trace.count("lockdown-close") == 1
        assert "amfi-reveal" not in trace and "dvt-init" not in trace

    for options, code in (
        ({"paired": False}, "pairing_required"),
        ({"reported_ecid": TEST_ECID + 1}, "target_mismatch"),
        ({"reported_udid": "00008030-00123456789ABCDF"}, "target_mismatch"),
        ({"reported_product_type": "iPhone15,2"}, "target_mismatch"),
    ):
        trace.clear()
        status, events = run_captured(module, module.execute(
            "enable-wifi", identity, fake_reveal_imports(trace, **options),
        ))
        assert status == 3 and events[-1]["code"] == code
        assert "wifi-status" not in trace and "wifi-enable" not in trace

    trace.clear()
    status, events = run_captured(module, module.execute(
        "enable-wifi", identity,
        fake_reveal_imports(trace, wifi_error=OSError("private network failure")),
    ))
    assert status == 4 and events[-1]["phase"] == "wifiSetup"
    assert trace.count("wifi-enable") == 1
    assert "private network failure" not in json.dumps(events)

    trace.clear()
    status, events = run_captured(module, module.execute(
        "enable-wifi", identity, fake_reveal_imports(trace, wifi_setting_sticks=False),
    ))
    assert status == 4 and events[-1]["phase"] == "wifiSetup"
    assert all(event["event"] != "wifiEnabled" for event in events)
    assert trace.count("wifi-enable") == 1 and trace.count("wifi-status") == 2

    async def clear_control():
        return b'{"command":"clear"}\n'
    original_reader = module.read_stdin_line
    module.read_stdin_line = clear_control
    try:
        for command in ("probe", "set", "clear"):
            request = dict(identity, transport="wifi")
            if command == "set":
                request.update(latitude="16.8409", longitude="96.1735")
            trace.clear()
            status, events = run_captured(module, module.execute(
                command, request, fake_imports(trace, transport="wifi", allow_clear=True),
            ))
            assert status == 0, (command, events)
            assert trace.index("network-lockdown-open") < trace.index("tunnel-init")
            assert trace.index("network-lockdown-close") < trace.index("tunnel-init")
            assert trace.index("tunnel-open") < trace.index("dvt-init")
            assert trace.count("location-set") == (1 if command == "set" else 0)
            assert trace.count("location-clear") == (0 if command == "probe" else 1)
            assert TEST_UDID not in json.dumps(events) and TEST_ECID_TEXT not in json.dumps(events)

        for options, code, tunnel_opened in (
            ({"paired": False}, "pairing_required", False),
            ({"lockdown_ecid": TEST_ECID + 1}, "target_mismatch", False),
            ({"lockdown_product_type": "iPhone15,2"}, "target_mismatch", False),
            ({"lockdown_connection_type": "USB"}, "target_mismatch", False),
            ({"reported_ecid": TEST_ECID + 1, "lockdown_ecid": TEST_ECID}, "target_mismatch", True),
            ({"reported_product_type": "iPhone15,2", "lockdown_product_type": "iPhone12,8"}, "target_mismatch", True),
        ):
            trace.clear()
            request = dict(identity, transport="wifi", latitude="16.8409", longitude="96.1735")
            status, events = run_captured(module, module.execute(
                "set", request, fake_imports(trace, transport="wifi", **options),
            ))
            assert status == 3 and events[-1]["code"] == code, (options, events)
            assert ("tunnel-init" in trace) is tunnel_opened
            assert "dvt-init" not in trace and "location-set" not in trace
    finally:
        module.read_stdin_line = original_reader

    original_close_timeout = module.CLOSE_TIMEOUT_SECONDS
    module.CLOSE_TIMEOUT_SECONDS = 0.01
    try:
        trace.clear()
        request = {"udid": TEST_UDID, "expectedProductType": "iPhone12,8",
                   "latitude": "16.8409", "longitude": "96.1735"}
        status, events = run_captured(module, module.execute(
            "set-persistent", request,
            fake_imports(trace, dvt_close_blocks=True, tunnel_close_blocks=True),
        ))
        assert status == 5 and events[-1]["phase"] == "persistentTeardown"
        assert trace.count("dvt-close") == 1 and trace.count("tunnel-close") == 1
        assert "FORBIDDEN-clear" not in trace
    finally:
        module.CLOSE_TIMEOUT_SECONDS = original_close_timeout

    # Wi-Fi loss must win over a simultaneously queued Clear. The backend
    # closes its contexts and reports uncertainty without issuing another RPC.
    async def blocked_control():
        await asyncio.Event().wait()
    module.read_stdin_line = blocked_control
    try:
        trace.clear()
        request = dict(identity, transport="wifi", latitude="16.8409", longitude="96.1735")
        status, events = run_captured(module, module.execute(
            "set", request, fake_imports(trace, transport="wifi", connection_lost=True),
        ))
        assert status == 5
        assert events[-1] == {
            "protocol": 1, "event": "error", "status": "uncertain",
            "code": "connection_lost", "phase": "transport",
        }
        assert trace.count("location-set") == 1
        assert "location-clear" not in trace and "FORBIDDEN-clear" not in trace
        assert trace.count("tunnel-open") == 1
        assert trace.count("dvt-close") == 1 and trace.count("tunnel-close") == 1
    finally:
        module.read_stdin_line = original_reader

    # Invalid transport/identity/command combinations fail before any connection.
    for command, request in (
        ("probe", dict(identity, transport="USB")),
        ("probe", dict(identity, transport=None)),
        ("probe", {"udid": TEST_UDID, "expectedProductType": "iPhone12,8", "transport": "wifi"}),
        ("probe", dict(identity, transport="wifi", expectedECID="0x0")),
        ("enable-wifi", dict(identity, transport="wifi")),
        ("set-persistent", dict(identity, transport="wifi", latitude="16.8409", longitude="96.1735")),
    ):
        trace.clear()
        status, events = run_captured(module, module.execute(command, request, fake_imports(trace)))
        assert status == 2 and events[-1]["code"] == "invalid_request"
        assert trace == ["event:error"]

    # Exercise the real cancellable pipe reader, including read-ahead, without
    # a thread, phone, socket, or privileged service.
    async def exercise_pipe():
        read_fd, write_fd = os.pipe()
        old_stdin = sys.stdin
        sys.stdin = SimpleNamespace(fileno=lambda: read_fd)
        module._stdin_pending.clear()
        try:
            reader = asyncio.create_task(module.read_stdin_line())
            await asyncio.sleep(0)
            reader.cancel()
            await asyncio.gather(reader, return_exceptions=True)
            os.write(write_fd, b'{"command":"clear"}\n{"command":"quit"}\n')
            assert await module.read_stdin_line() == b'{"command":"clear"}\n'
            assert await module.read_stdin_line() == b'{"command":"quit"}\n'
            os.close(write_fd)
            write_fd = -1
            assert await module.read_stdin_line() == b""
        finally:
            sys.stdin = old_stdin
            os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)
    asyncio.run(asyncio.wait_for(exercise_pipe(), timeout=1.0))


def assert_ecid_integer_subclasses(module, trace):
    request = {
        "udid": TEST_UDID, "expectedProductType": "iPhone12,8",
        "expectedECID": TEST_ECID_TEXT, "transport": "wifi",
    }
    # RemoteXPC decodes uint64 ECIDs into an int subclass; USB plist uses int.
    # Both representations must attest to the same exact numeric identity.
    for reported_ecid, lockdown_ecid in (
        (FakeXpcUInt64Type(TEST_ECID), TEST_ECID),
        (TEST_ECID, FakeXpcUInt64Type(TEST_ECID)),
        (FakeXpcUInt64Type(TEST_ECID), FakeXpcUInt64Type(TEST_ECID)),
        (FakeXpcInt64Type(TEST_ECID), TEST_ECID),
        (TEST_ECID, FakeXpcInt64Type(TEST_ECID)),
        (FakeXpcInt64Type(TEST_ECID), FakeXpcInt64Type(TEST_ECID)),
    ):
        trace.clear()
        status, events = run_captured(module, module.execute(
            "probe", request, fake_imports(
                trace, transport="wifi", product_version="27.3",
                reported_ecid=reported_ecid, lockdown_ecid=lockdown_ecid,
            ),
        ))
        assert status == 0 and events[-1]["event"] == "ready"
        assert trace.count("tunnel-open") == 1 and trace.count("dvt-connect") == 1
        assert "location-set" not in trace and "FORBIDDEN-clear" not in trace
        assert TEST_UDID not in json.dumps(events) and TEST_ECID_TEXT not in json.dumps(events)

    # An integer subclass with a different value is still the wrong device,
    # whether the disagreement is reported by Network lockdown or by RSD.
    for reported_ecid, lockdown_ecid, tunnel_opened in (
        (FakeXpcUInt64Type(TEST_ECID + 1), TEST_ECID, True),
        (TEST_ECID, FakeXpcUInt64Type(TEST_ECID + 1), False),
        (FakeXpcInt64Type(TEST_ECID + 1), TEST_ECID, True),
        (TEST_ECID, FakeXpcInt64Type(TEST_ECID + 1), False),
    ):
        trace.clear()
        status, events = run_captured(module, module.execute(
            "probe", request, fake_imports(
                trace, transport="wifi", reported_ecid=reported_ecid, lockdown_ecid=lockdown_ecid,
            ),
        ))
        assert status == 3 and events[-1]["code"] == "target_mismatch"
        assert ("tunnel-open" in trace) is tunnel_opened
        assert "dvt-init" not in trace and "location-set" not in trace

    # These inputs deliberately compare numerically equal after coercion, so
    # they prove type rejection rather than merely a different ECID value.
    for raw_ecid, expected in ((True, 1), (False, 0), (12345.0, 12345), ("12345", 12345)):
        target = SimpleNamespace(udid=TEST_UDID, product_type="iPhone12,8", ecid=raw_ecid)
        try:
            module.attest_identity(target, TEST_UDID, "iPhone12,8", expected)
            raise AssertionError("non-integer ECID accepted")
        except module.TargetMismatchError:
            pass


def assert_initially_missing_wifi_flag(module, trace):
    request = {
        "udid": TEST_UDID, "expectedProductType": "iPhone12,8",
        "expectedECID": TEST_ECID_TEXT,
    }
    private_detail = "private unset flag " + TEST_UDID + " " + TEST_ECID_TEXT

    # A first-time missing key is the sole read failure that permits the one
    # already-confirmed write. Success still requires the second read to be true.
    trace.clear()
    status, events = run_captured(module, module.execute(
        "enable-wifi", request, fake_reveal_imports(
            trace, product_version="27.3",
            wifi_initial_read_error=FakeMissingValueError(private_detail),
        ),
    ))
    assert status == 0
    assert [event["event"] for event in events] == [
        "hello", "attested", "requestDispatched", "wifiEnabled",
    ]
    assert trace.count("wifi-enable") == 1 and trace.count("wifi-status") == 2
    assert trace.count("lockdown-open") == 1 and trace.count("lockdown-close") == 1
    assert trace.index("wifi-status") < trace.index("event:requestDispatched") < trace.index("wifi-enable")
    assert trace.index("wifi-enable") < len(trace) - 1 - trace[::-1].index("wifi-status")
    assert all(secret not in json.dumps(events) for secret in (private_detail, TEST_UDID, TEST_ECID_TEXT))

    # Missing readback is not treated as another unset first read, and never
    # causes a second setter. Other readback errors and false readback fail too.
    for initial_missing in (False, True):
        for readback_error, sticks in (
            (FakeMissingValueError(private_detail), True),
            (OSError(private_detail), True),
            (asyncio.TimeoutError(private_detail), True),
            (None, False),
        ):
            trace.clear()
            status, events = run_captured(module, module.execute(
                "enable-wifi", request, fake_reveal_imports(
                    trace,
                    wifi_initial_read_error=FakeMissingValueError(private_detail) if initial_missing else None,
                    wifi_readback_error=readback_error, wifi_setting_sticks=sticks,
                ),
            ))
            assert status == 4 and events[-1]["phase"] == "wifiSetup"
            assert trace.count("wifi-enable") == 1 and trace.count("wifi-status") == 2
            assert trace.count("lockdown-open") == 1 and trace.count("lockdown-close") == 1
            assert all(event["event"] != "wifiEnabled" for event in events)
            assert all(secret not in json.dumps(events) for secret in (private_detail, TEST_UDID, TEST_ECID_TEXT))

    # Every other initial read error must fail before dispatch or any write.
    for initial_error in (
        OSError(private_detail), RuntimeError(private_detail),
        asyncio.TimeoutError(private_detail), PermissionError(private_detail),
    ):
        trace.clear()
        status, events = run_captured(module, module.execute(
            "enable-wifi", request,
            fake_reveal_imports(trace, wifi_initial_read_error=initial_error),
        ))
        assert status == 4 and events[-1]["phase"] == "wifiSetup"
        assert trace.count("wifi-status") == 1 and "wifi-enable" not in trace
        assert trace.count("lockdown-open") == 1 and trace.count("lockdown-close") == 1
        assert all(event["event"] not in ("requestDispatched", "wifiEnabled") for event in events)
        assert private_detail not in json.dumps(events)

    # A missing initial value never weakens exact identity or Trust preflight.
    for options, expected_code in (
        ({"paired": False}, "pairing_required"),
        ({"reported_ecid": TEST_ECID + 1}, "target_mismatch"),
        ({"reported_udid": "00008030-00123456789ABCDF"}, "target_mismatch"),
        ({"reported_product_type": "iPhone15,2"}, "target_mismatch"),
    ):
        trace.clear()
        status, events = run_captured(module, module.execute(
            "enable-wifi", request, fake_reveal_imports(
                trace, wifi_initial_read_error=FakeMissingValueError(private_detail), **options,
            ),
        ))
        assert status == 3 and events[-1]["code"] == expected_code
        assert "wifi-status" not in trace and "wifi-enable" not in trace
        assert "amfi-reveal" not in trace and "dvt-init" not in trace


def assert_patched_tunnel_source(source_path):
    """Execute isolated upstream functions against fakes, never import services."""
    tree = ast.parse(source_path.read_text())
    provider = next(node for node in tree.body if isinstance(node, ast.AsyncFunctionDef)
                    and node.name == "_create_no_root_tunnel_provider")
    tunnel_class = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                        and node.name == "UserspaceRsdTunnel")
    wait_method = next(node for node in tunnel_class.body if isinstance(node, ast.AsyncFunctionDef)
                       and node.name == "wait_closed")
    class NotPairedError(Exception):
        pass
    class InvalidServiceError(Exception):
        pass
    class TunnelUnavailableError(Exception):
        pass
    trace = []
    provider_failure = [False]
    lockdown = SimpleNamespace(
        paired=True,
        service=SimpleNamespace(mux_device=SimpleNamespace(connection_type="Network")),
    )
    async def close():
        trace.append("close")
    lockdown.close = close
    async def create_using_usbmux(**kwargs):
        assert kwargs == {
            "serial": TEST_UDID, "autopair": False, "connection_type": "Network",
            "auto_reconnect": False,
        }
        trace.append("network")
        return lockdown
    async def create_provider(value):
        assert value is lockdown and value.paired is True
        trace.append("service")
        if provider_failure[0]:
            raise InvalidServiceError()
        return "provider"
    namespace = {
        "Optional": Optional, "asyncio": asyncio,
        "create_using_usbmux": create_using_usbmux,
        "tunnel_service": SimpleNamespace(CoreDeviceTunnelProxy=SimpleNamespace(create=create_provider)),
        "NotPairedError": NotPairedError, "InvalidServiceError": InvalidServiceError,
        "UserspaceTunnelUnavailableError": TunnelUnavailableError,
        "PyMobileDevice3Exception": RuntimeError,
    }
    selected = ast.Module(body=[provider, wait_method], type_ignores=[])
    exec(compile(selected, str(source_path), "exec"), namespace)
    async def exercise():
        result = await namespace[provider.name](TEST_UDID, False, False, "Network", False)
        assert result == ("provider", lockdown) and trace == ["network", "service"]
        trace.clear()
        lockdown.paired = False
        try:
            await namespace[provider.name](TEST_UDID, False, False, "Network", False)
            raise AssertionError("unpaired target was accepted")
        except NotPairedError:
            pass
        assert trace == ["network", "close"]
        trace.clear()
        lockdown.paired = True
        lockdown.service.mux_device.connection_type = "USB"
        try:
            await namespace[provider.name](TEST_UDID, False, False, "Network", False)
            raise AssertionError("wrong transport was accepted")
        except TunnelUnavailableError:
            pass
        assert trace == ["network", "close"]
        trace.clear()
        lockdown.service.mux_device.connection_type = "Network"
        provider_failure[0] = True
        try:
            await namespace[provider.name](TEST_UDID, False, False, "Network", False)
            raise AssertionError("unavailable network provider was accepted")
        except TunnelUnavailableError:
            pass
        assert trace == ["network", "service", "close"]
        event = asyncio.Event()
        transport = asyncio.create_task(event.wait())
        observer = asyncio.create_task(namespace[wait_method.name](SimpleNamespace(_closed_task=transport)))
        await asyncio.sleep(0)
        observer.cancel()
        await asyncio.gather(observer, return_exceptions=True)
        assert not transport.done(), "canceling an observer canceled the transport"
        event.set()
        await namespace[wait_method.name](SimpleNamespace(_closed_task=transport))
    asyncio.run(asyncio.wait_for(exercise(), timeout=1.0))

    lockdown_source = source_path.parents[1] / "lockdown.py"
    lockdown_tree = ast.parse(lockdown_source.read_text())
    lockdown_class = next(node for node in lockdown_tree.body if isinstance(node, ast.ClassDef)
                          and node.name == "LockdownClient")
    request_method = next(node for node in lockdown_class.body if isinstance(node, ast.AsyncFunctionDef)
                          and node.name == "_request")
    reconnect_method = next(node for node in lockdown_class.body if isinstance(node, ast.AsyncFunctionDef)
                            and node.name == "areestablish_connection")
    class ConnectionTerminatedError(Exception):
        pass
    class InvalidConnectionError(Exception):
        pass
    class LockdownError(Exception):
        pass
    request_namespace = {
        "asyncio": asyncio, "Any": object, "Optional": Optional,
        "ConnectionTerminatedError": ConnectionTerminatedError,
        "InvalidConnectionError": InvalidConnectionError, "LockdownError": LockdownError,
    }
    # Retain postponed annotations so the source's full type imports are not
    # needed to execute these isolated, network-free functions.
    future = ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)
    selected = ast.fix_missing_locations(ast.Module(
        body=[future, request_method, reconnect_method], type_ignores=[],
    ))
    exec(compile(selected, str(lockdown_source), "exec"), request_namespace)
    async def exercise_no_retry():
        for failure, response_error in (
            (ConnectionResetError("private reset"), None),
            (ConnectionTerminatedError("private lost transport"), None),
            (RuntimeError("different event loop"), None),
            (None, InvalidConnectionError("private connection")),
            (None, LockdownError("SessionInactive")),
        ):
            calls = []
            async def send_recv_plist(message):
                calls.append("send")
                if failure is not None:
                    raise failure
                return {}
            def verify(request, response, **kwargs):
                if response_error is not None:
                    raise response_error
                return response
            async def reconnect():
                calls.append("FORBIDDEN-reconnect")
                raise AssertionError("request replay attempted")
            target = SimpleNamespace(
                auto_reconnect=False, label="test", service=SimpleNamespace(send_recv_plist=send_recv_plist),
                _verify_request_response=verify, areestablish_connection=reconnect,
            )
            try:
                await request_namespace[request_method.name](target, "SetValue", {"Value": True})
                raise AssertionError("injected transport/session failure was hidden")
            except (ConnectionResetError, ConnectionTerminatedError, RuntimeError, InvalidConnectionError, LockdownError):
                pass
            assert calls == ["send"], calls
        calls = []
        async def forbidden_close():
            calls.append("FORBIDDEN-close-and-reconnect")
        target = SimpleNamespace(auto_reconnect=False, close=forbidden_close)
        try:
            await request_namespace[reconnect_method.name](target)
            raise AssertionError("explicit reconnect was accepted")
        except (RuntimeError, ConnectionTerminatedError):
            pass
        assert calls == []
    asyncio.run(asyncio.wait_for(exercise_no_retry(), timeout=1.0))

    factory = next(node for node in lockdown_tree.body if isinstance(node, ast.AsyncFunctionDef)
                   and node.name == "create_using_usbmux")
    factory_calls = []
    service = SimpleNamespace(mux_device=SimpleNamespace(serial=TEST_UDID))
    async def service_close():
        factory_calls.append("service-close")
    service.close = service_close
    async def open_service(*args, **kwargs):
        assert kwargs["connection_type"] == "Network"
        return service
    class FakeMux:
        async def __aenter__(self):
            return self
        async def __aexit__(self, *args):
            pass
    async def create_mux(**kwargs):
        return FakeMux()
    class FakeLockdown:
        def __init__(self, supplied_service, **kwargs):
            assert supplied_service is service
        async def _initialize(self):
            assert self.auto_reconnect is False
            factory_calls.append("initialize-without-retry")
        async def _handle_autopair(self, autopair, timeout):
            assert autopair is False and self.auto_reconnect is False
            factory_calls.append("validate-without-retry")
    factory_namespace = {
        "DEFAULT_LABEL": "test", "SERVICE_PORT": 62078, "SYSTEM_BUID": "test-buid",
        "ServiceConnection": SimpleNamespace(create_using_usbmux=open_service),
        "usbmux": SimpleNamespace(create_mux=create_mux),
        "UsbmuxLockdownClient": FakeLockdown, "PlistMuxConnection": type("PlistMux", (), {}),
        "PlistUsbmuxLockdownClient": FakeLockdown,
        "generate_host_id": lambda _hostname: "test-host",
        "create_pairing_records_cache_folder": lambda path: path,
    }
    selected = ast.fix_missing_locations(ast.Module(body=[future, factory], type_ignores=[]))
    exec(compile(selected, str(lockdown_source), "exec"), factory_namespace)
    asyncio.run(factory_namespace[factory.name](
        serial=TEST_UDID, autopair=False, connection_type="Network", auto_reconnect=False,
    ))
    assert factory_calls == ["initialize-without-retry", "validate-without-retry"]


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit("usage: test-yios-location-backend.py BRIDGE [PATCHED_TUNNEL_SOURCE]")
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
    wrong_product["expectedProductType"] = "iPad13,1"
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

    assert_generic_iphone_targets(module, trace)
    assert_wifi_contract(module, trace)
    assert_ecid_integer_subclasses(module, trace)
    assert_initially_missing_wifi_flag(module, trace)
    if len(sys.argv) == 3:
        assert_patched_tunnel_source(pathlib.Path(sys.argv[2]))

    print("LOCATION BACKEND OFFLINE GENERIC-IPHONE + PERSISTENT + DEVELOPER-MODE + WIFI TEST PASS")


if __name__ == "__main__":
    main()
