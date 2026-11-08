#!/usr/bin/python3
"""Restricted JSON-lines bridge for YIOS-KIT's iOS location simulator.

The bridge deliberately exposes only version, readiness probe, static set,
opt-in experimental one-shot set, clear, USB Wi-Fi preparation, and an exact-target
request that makes the Developer Mode option expected in Settings. The separate
native path uses only a verified Apple Mach-O for persistent location commands;
Apple may prepare its own developer-image services. The SDK never installs an
image, enables Developer Mode, reboots, pairs a phone, starts a privileged
tunnel, retries a request, or falls back to RemotePairing.
"""

import asyncio
import json
import logging
import math
import os
import re
import stat
import sys
import uuid
from decimal import Decimal, InvalidOperation
from importlib import metadata
from pathlib import Path
from typing import Any, Dict, Optional, Tuple


PROTOCOL_VERSION = 1
BACKEND_VERSION = "1.4.0"
PINNED_PYMOBILEDEVICE3_VERSION = "10.9.0"
MINIMUM_IOS = (17, 4)
MAX_REQUEST_BYTES = 4096
CONNECT_TIMEOUT_SECONDS = 45.0
SERVICE_TIMEOUT_SECONDS = 30.0
CLOSE_TIMEOUT_SECONDS = 5.0
NATIVE_TOOL_PATH = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"
NATIVE_CAPABILITY = "com.apple.coredevice.feature.simulatelocation"
NATIVE_OUTPUT_LIMIT = 2 * 1024 * 1024
NATIVE_PROCESS_TIMEOUT_SECONDS = 30.0
UDID_PATTERN = re.compile(r"^[A-Za-z0-9-]{8,64}$")
ECID_PATTERN = re.compile(r"^0x[0-9A-F]{1,16}$")
IPHONE_PRODUCT_TYPE_PATTERN = re.compile(r"^iPhone[1-9][0-9]*,(?:0|[1-9][0-9]*)$")
DECIMAL_PATTERN = re.compile(r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$")


# Keep the protocol stream separate from stdout/stderr before importing any
# third-party module.  Upstream warnings, logs, and tracebacks are discarded so
# they can never leak identifiers, coordinates, tunnel addresses, or pair data.
_protocol_fd = os.dup(1)
_null_fd = os.open(os.devnull, os.O_WRONLY)
os.dup2(_null_fd, 1)
os.dup2(_null_fd, 2)


def emit(event: str, status: str, **fields: Any) -> None:
    payload: Dict[str, Any] = {
        "protocol": PROTOCOL_VERSION,
        "event": event,
        "status": status,
    }
    payload.update(fields)
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True, ensure_ascii=True)
    try:
        os.write(_protocol_fd, (encoded + "\n").encode("utf-8"))
    except OSError:
        # If the owning app has gone away, terminate without trying a device
        # operation or writing anywhere else.
        raise SystemExit(5)


def emit_hello() -> None:
    emit(
        "hello",
        "ok",
        protocol_version=PROTOCOL_VERSION,
        backend_version=BACKEND_VERSION,
        pymobiledevice3_version=PINNED_PYMOBILEDEVICE3_VERSION,
        python_version="3.9",
    )


def fail(code: str, phase: str, exit_code: int = 3) -> int:
    emit("error", "error", code=code, phase=phase)
    return exit_code


def private_package_root() -> Path:
    # Both the Vendor payload and the .app use this shape:
    #   <root>/Helpers/YIOSLocation/this-file.py
    #   <root>/Resources/YIOSLocation/python-packages/
    return Path(__file__).resolve().parents[2] / "Resources" / "YIOSLocation" / "python-packages"


def restrict_import_path() -> Path:
    package_root = private_package_root()
    if not package_root.is_dir():
        raise RuntimeError("private package root missing")

    # -I already ignores PYTHONPATH and the user site.  Also remove any system
    # third-party directory so a partial app payload cannot silently mix with a
    # separately installed package set.
    sys.path[:] = [
        entry
        for entry in sys.path
        if "site-packages" not in entry and "dist-packages" not in entry
    ]
    sys.path.insert(0, str(package_root))
    return package_root


def parse_json_line(line: bytes) -> Optional[Dict[str, Any]]:
    if not line or len(line) > MAX_REQUEST_BYTES:
        return None
    try:
        text = line.decode("utf-8", errors="strict")
        value = json.loads(
            text,
            parse_float=Decimal,
            parse_int=Decimal,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
    except (UnicodeError, ValueError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def parse_udid(value: Any) -> Optional[str]:
    if not isinstance(value, str) or UDID_PATTERN.fullmatch(value) is None:
        return None
    return value


def parse_product_type(value: Any) -> Optional[str]:
    if (
        not isinstance(value, str)
        or len(value) > 32
        or IPHONE_PRODUCT_TYPE_PATTERN.fullmatch(value) is None
    ):
        return None
    major, minor = value[len("iPhone"):].split(",")
    if int(major) > 0x7FFFFFFFFFFFFFFF or int(minor) > 0x7FFFFFFFFFFFFFFF:
        return None
    return value


def normalized_udid(value: Any) -> str:
    return str(value or "").replace("-", "").upper()


def parse_ecid(value: Any) -> Optional[int]:
    if not isinstance(value, str) or ECID_PATTERN.fullmatch(value) is None:
        return None
    candidate = int(value[2:], 16)
    return candidate if candidate > 0 else None


def parse_coordinate(value: Any, minimum: Decimal, maximum: Decimal) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, Decimal):
        candidate = value
    elif isinstance(value, (int, float)):
        if not math.isfinite(float(value)):
            return None
        candidate = Decimal(str(value))
    elif isinstance(value, str) and len(value) <= 32 and DECIMAL_PATTERN.fullmatch(value):
        try:
            candidate = Decimal(value)
        except InvalidOperation:
            return None
    else:
        return None
    if not candidate.is_finite() or candidate < minimum or candidate > maximum:
        return None
    return float(candidate)


def parse_os_version(value: Any) -> Optional[Tuple[int, int]]:
    match = re.match(r"^(\d+)\.(\d+)", str(value or ""))
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


class BackendImports:
    def __init__(self) -> None:
        restrict_import_path()
        if metadata.version("pymobiledevice3") != PINNED_PYMOBILEDEVICE3_VERSION:
            raise RuntimeError("pinned package version mismatch")

        logging.disable(logging.CRITICAL)

        from pymobiledevice3.exceptions import (  # pylint: disable=import-outside-toplevel
            ConnectionFailedError,
            ConnectionTerminatedError,
            DeveloperModeIsNotEnabledError,
            DeviceAlreadyInUseError,
            DeviceNotFoundError,
            DvtException,
            InvalidServiceError,
            MissingValueError,
            NoDeviceConnectedError,
            NotPairedError,
            NotTrustedError,
            PasswordRequiredError,
            PairingDialogResponsePendingError,
            PairingError,
            PyMobileDevice3Exception,
            StartServiceError,
            UserspaceTunnelUnavailableError,
        )
        from pymobiledevice3.lockdown import create_using_usbmux  # pylint: disable=import-outside-toplevel
        from pymobiledevice3.remote.userspace_tunnel import (  # pylint: disable=import-outside-toplevel
            UserspaceRsdTunnel,
        )
        from pymobiledevice3.services.amfi import AmfiService  # pylint: disable=import-outside-toplevel
        from pymobiledevice3.services.dvt.instruments.dvt_provider import (  # pylint: disable=import-outside-toplevel
            DvtProvider,
        )
        from pymobiledevice3.services.dvt.instruments.location_simulation import (  # pylint: disable=import-outside-toplevel
            LocationSimulation,
        )

        self.UserspaceRsdTunnel = UserspaceRsdTunnel
        self.DvtProvider = DvtProvider
        self.LocationSimulation = LocationSimulation
        self.create_using_usbmux = create_using_usbmux
        self.AmfiService = AmfiService
        self.NativeLocationTool = NativeLocationTool
        self.device_not_found_errors = (DeviceNotFoundError, NoDeviceConnectedError)
        self.pairing_errors = (NotPairedError, PairingError)
        self.trust_errors = (NotTrustedError, PairingDialogResponsePendingError)
        self.unlock_errors = (PasswordRequiredError,)
        self.userspace_errors = (UserspaceTunnelUnavailableError,)
        self.developer_mode_errors = (DeveloperModeIsNotEnabledError,)
        self.invalid_service_errors = (InvalidServiceError,)
        self.missing_value_errors = (MissingValueError,)
        self.amfi_errors = (StartServiceError, PyMobileDevice3Exception)
        self.device_busy_errors = (DeviceAlreadyInUseError,)
        self.connection_errors = (ConnectionFailedError, ConnectionTerminatedError, DvtException)


def map_exception(imports: BackendImports, error: BaseException, phase: str) -> str:
    if isinstance(error, imports.device_not_found_errors):
        return "target_not_found"
    if isinstance(error, imports.trust_errors):
        return "pairing_required"
    if isinstance(error, imports.unlock_errors):
        return "unlock_required"
    if isinstance(error, imports.pairing_errors):
        return "pairing_required"
    if isinstance(error, imports.userspace_errors):
        return "tunnel_unavailable"
    if isinstance(error, imports.developer_mode_errors):
        return "developer_mode_required"
    if isinstance(error, imports.device_busy_errors):
        return "developer_service_unavailable"
    if isinstance(error, imports.invalid_service_errors):
        if phase in ("dvt", "location_service"):
            return "developer_disk_image_required"
        return "developer_service_unavailable"
    if isinstance(error, asyncio.TimeoutError):
        return "timeout"
    if isinstance(error, PermissionError):
        return "permission_denied"
    if isinstance(error, OSError) or isinstance(error, imports.connection_errors):
        return "tunnel_unavailable" if phase == "tunnel" else "developer_service_unavailable"
    return "internal_failure"


def map_reveal_exception(imports: BackendImports, error: BaseException) -> str:
    if isinstance(error, imports.device_not_found_errors):
        return "target_not_found"
    if isinstance(error, imports.trust_errors):
        return "pairing_required"
    if isinstance(error, imports.unlock_errors):
        return "unlock_required"
    if isinstance(error, imports.pairing_errors):
        return "pairing_required"
    if isinstance(error, asyncio.TimeoutError):
        return "timeout"
    if isinstance(error, PermissionError):
        return "permission_denied"
    if isinstance(error, OSError) or isinstance(error, imports.connection_errors):
        return "developer_mode_reveal_failed"
    if isinstance(error, imports.invalid_service_errors) or isinstance(error, imports.amfi_errors):
        return "developer_mode_reveal_failed"
    return "internal_failure"


_stdin_pending = bytearray()


async def read_stdin_line() -> bytes:
    """Read a cancellable control line without leaving a worker blocked on stdin."""
    loop = asyncio.get_running_loop()
    result = loop.create_future()
    descriptor = sys.stdin.fileno()

    def consume() -> None:
        if result.done():
            return
        newline = _stdin_pending.find(b"\n")
        if newline >= 0:
            length = min(newline + 1, MAX_REQUEST_BYTES + 1)
            line = bytes(_stdin_pending[:length])
            del _stdin_pending[:length]
            result.set_result(line)
        elif len(_stdin_pending) > MAX_REQUEST_BYTES:
            result.set_result(bytes(_stdin_pending))
            _stdin_pending.clear()

    def readable() -> None:
        if result.done():
            return
        try:
            chunk = os.read(descriptor, MAX_REQUEST_BYTES + 1)
            if not chunk:
                result.set_result(bytes(_stdin_pending))
                _stdin_pending.clear()
                return
            _stdin_pending.extend(chunk)
            consume()
        except BaseException as error:
            if not result.done():
                result.set_exception(error)

    consume()
    if not result.done():
        loop.add_reader(descriptor, readable)
    try:
        return await result
    finally:
        loop.remove_reader(descriptor)


def attest_identity(target: Any, udid: str, product_type: str, ecid: Optional[int]) -> None:
    reported_udid = getattr(target, "udid", None) or getattr(target, "identifier", None)
    if normalized_udid(reported_udid) != normalized_udid(udid):
        raise TargetMismatchError()
    if getattr(target, "product_type", None) != product_type:
        raise TargetMismatchError()
    if ecid is not None:
        try:
            reported_ecid = getattr(target, "ecid")
            if (
                not isinstance(reported_ecid, int)
                or isinstance(reported_ecid, bool)
                or int(reported_ecid) != ecid
            ):
                raise TargetMismatchError()
        except (AttributeError, TypeError, ValueError, KeyError):
            raise TargetMismatchError() from None


async def open_attested_lockdown(
    imports: BackendImports,
    udid: str,
    expected_product_type: str,
    expected_ecid: int,
    connection_type: str,
) -> Any:
    lockdown = await asyncio.wait_for(
        imports.create_using_usbmux(
            serial=udid, connection_type=connection_type, autopair=False, auto_reconnect=False,
        ),
        timeout=CONNECT_TIMEOUT_SECONDS,
    )
    try:
        mux_device = getattr(getattr(lockdown, "service", None), "mux_device", None)
        if getattr(mux_device, "connection_type", None) != connection_type:
            raise TargetMismatchError()
        attest_identity(lockdown, udid, expected_product_type, expected_ecid)
        if getattr(lockdown, "paired", False) is not True:
            raise PairingRequiredError()
        os_version = parse_os_version(getattr(lockdown, "product_version", None))
        if os_version is None or os_version < MINIMUM_IOS:
            raise UnsupportedOSError()
        return lockdown
    except BaseException:
        await close_bounded(lockdown.close())
        raise


async def open_attested_target(
    imports: BackendImports,
    udid: str,
    expected_product_type: str,
    transport: str = "usb",
    expected_ecid: Optional[int] = None,
) -> Tuple[Any, Any]:
    if transport == "wifi":
        assert expected_ecid is not None
        lockdown = await open_attested_lockdown(
            imports, udid, expected_product_type, expected_ecid, "Network",
        )
        await asyncio.wait_for(lockdown.close(), timeout=CLOSE_TIMEOUT_SECONDS)
    tunnel = imports.UserspaceRsdTunnel(
        serial=udid,
        autopair=False,
        remotepairing_fallback=False,
        connection_type="Network" if transport == "wifi" else "USB",
        auto_reconnect=False,
    )
    try:
        rsd = await asyncio.wait_for(tunnel.aopen(), timeout=CONNECT_TIMEOUT_SECONDS)

        if normalized_udid(getattr(rsd, "udid", None)) != normalized_udid(udid):
            raise TargetMismatchError()
        if getattr(rsd, "product_type", None) != expected_product_type:
            raise TargetMismatchError()
        attest_identity(rsd, udid, expected_product_type, expected_ecid)

        os_version = parse_os_version(getattr(rsd, "product_version", None))
        if os_version is None or os_version < MINIMUM_IOS:
            raise UnsupportedOSError()

        developer_mode = await asyncio.wait_for(
            rsd.get_developer_mode_status(),
            timeout=SERVICE_TIMEOUT_SECONDS,
        )
        if developer_mode is not True:
            raise DeveloperModeDisabledError()

        emit("attested", "ok", product_type=expected_product_type)
        return tunnel, rsd
    except BaseException:
        await close_bounded(tunnel.aclose())
        raise


class TargetMismatchError(Exception):
    pass


class UnsupportedOSError(Exception):
    pass


class DeveloperModeDisabledError(Exception):
    pass


class PairingRequiredError(Exception):
    pass


async def close_bounded(operation: Any) -> bool:
    try:
        await asyncio.wait_for(operation, timeout=CLOSE_TIMEOUT_SECONDS)
        return True
    except BaseException:
        return False


async def reveal_developer_mode(
    imports: BackendImports,
    udid: str,
    expected_product_type: str,
    expected_ecid: int,
) -> int:
    lockdown = None
    phase = "usb"
    emit_hello()
    try:
        lockdown = await asyncio.wait_for(
            imports.create_using_usbmux(
                serial=udid,
                connection_type="USB",
                autopair=False,
                auto_reconnect=False,
            ),
            timeout=CONNECT_TIMEOUT_SECONDS,
        )
        reported_udid = (
            getattr(lockdown, "udid", None)
            or getattr(lockdown, "identifier", None)
        )
        try:
            reported_ecid = int(getattr(lockdown, "ecid"))
        except (AttributeError, TypeError, ValueError, KeyError):
            raise TargetMismatchError() from None

        if normalized_udid(reported_udid) != normalized_udid(udid):
            raise TargetMismatchError()
        if (
            getattr(lockdown, "product_type", None) != expected_product_type
            or reported_ecid != expected_ecid
        ):
            raise TargetMismatchError()
        os_version = parse_os_version(getattr(lockdown, "product_version", None))
        if os_version is None or os_version < MINIMUM_IOS:
            raise UnsupportedOSError()
        if getattr(lockdown, "paired", False) is not True:
            raise PairingRequiredError()

        emit("attested", "ok", product_type=expected_product_type)
        phase = "developerModeStatus"
        enabled = await asyncio.wait_for(
            lockdown.get_developer_mode_status(),
            timeout=SERVICE_TIMEOUT_SECONDS,
        )
        if enabled is True:
            emit("developerModeAlreadyEnabled", "alreadyEnabled")
            return 0

        phase = "developerModeReveal"
        emit("requestDispatched", "working")
        await asyncio.wait_for(
            imports.AmfiService(lockdown).reveal_developer_mode_option_in_ui(),
            timeout=SERVICE_TIMEOUT_SECONDS,
        )
        emit("developerModeOptionRequested", "settingsOptionExpected")
        return 0
    except TargetMismatchError:
        return fail("target_mismatch", "attestation")
    except UnsupportedOSError:
        return fail("developer_mode_reveal_failed", "attestation")
    except PairingRequiredError:
        return fail("pairing_required", "pairing")
    except BaseException as error:
        return fail(map_reveal_exception(imports, error), phase, 4)
    finally:
        if lockdown is not None:
            try:
                await asyncio.wait_for(lockdown.close(), timeout=CLOSE_TIMEOUT_SECONDS)
            except BaseException:
                pass


async def with_location_service(imports: BackendImports, rsd: Any) -> Tuple[Any, Any]:
    dvt = imports.DvtProvider(rsd)
    try:
        await asyncio.wait_for(dvt.connect(), timeout=SERVICE_TIMEOUT_SECONDS)
        location = imports.LocationSimulation(dvt)
        await asyncio.wait_for(location.connect(), timeout=SERVICE_TIMEOUT_SECONDS)
    except BaseException:
        await close_bounded(dvt.close())
        raise
    return dvt, location


async def enable_wifi(
    imports: BackendImports, udid: str, expected_product_type: str, expected_ecid: int,
) -> int:
    lockdown = None
    phase = "usb"
    emit_hello()
    try:
        lockdown = await open_attested_lockdown(
            imports, udid, expected_product_type, expected_ecid, "USB",
        )
        emit("attested", "ok", product_type=expected_product_type)
        phase = "wifiSetup"
        try:
            enabled = await asyncio.wait_for(
                lockdown.get_enable_wifi_connections(), timeout=SERVICE_TIMEOUT_SECONDS,
            )
        except imports.missing_value_errors:
            # An unset key permits the explicitly confirmed first enable write.
            # Only the initial read has this exception; readback must succeed.
            enabled = False
        emit("requestDispatched", "working")
        if enabled is not True:
            await asyncio.wait_for(
                lockdown.set_enable_wifi_connections(True), timeout=SERVICE_TIMEOUT_SECONDS,
            )
            enabled = await asyncio.wait_for(
                lockdown.get_enable_wifi_connections(), timeout=SERVICE_TIMEOUT_SECONDS,
            )
            if enabled is not True:
                return fail("developer_service_unavailable", phase, 4)
        emit("wifiEnabled", "ok")
        return 0
    except TargetMismatchError:
        return fail("target_mismatch", "attestation")
    except PairingRequiredError:
        return fail("pairing_required", "pairing")
    except UnsupportedOSError:
        return fail("developer_service_unavailable", "attestation")
    except BaseException as error:
        return fail(map_exception(imports, error, phase), phase, 4)
    finally:
        if lockdown is not None:
            try:
                await asyncio.wait_for(lockdown.close(), timeout=CLOSE_TIMEOUT_SECONDS)
            except BaseException:
                pass


class NativeToolUnavailableError(Exception):
    pass


class NativeCommandError(Exception):
    pass


class NativeSchemaError(Exception):
    pass


class NativeTargetNotFoundError(Exception):
    pass


def native_uuid(value: Any) -> str:
    if not isinstance(value, str):
        raise NativeSchemaError()
    try:
        parsed = str(uuid.UUID(value)).upper()
    except (ValueError, AttributeError):
        raise NativeSchemaError() from None
    if parsed != value.upper():
        raise NativeSchemaError()
    return parsed


def native_tool_file_valid() -> bool:
    """Accept only the fixed root-owned, non-writable, non-symlink Mach-O."""
    tool = Path(NATIVE_TOOL_PATH)
    try:
        for index, path in enumerate((tool,) + tuple(tool.parents)):
            metadata_value = path.lstat()
            if metadata_value.st_uid != 0 or metadata_value.st_mode & 0o022:
                return False
            expected_kind = stat.S_ISREG if index == 0 else stat.S_ISDIR
            if not expected_kind(metadata_value.st_mode):
                return False
            if index == 0 and not metadata_value.st_mode & 0o111:
                return False
        with tool.open("rb") as stream:
            return stream.read(4) in (
                b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
            )
    except (OSError, ValueError):
        return False


def native_child_environment() -> Dict[str, str]:
    # Do not inherit the SDK's private HOME/XDG paths or caller toolchain,
    # loader, Python, proxy, or credential variables. Apple uses its OS account
    # databases when HOME is absent; the parent process remains unchanged.
    result = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"}
    temporary = os.environ.get("TMPDIR", "/private/tmp")
    if temporary.startswith("/") and "\x00" not in temporary:
        result["TMPDIR"] = temporary
    return result


def native_child_arguments(action: str, arguments: Tuple[str, ...]) -> Tuple[str, ...]:
    """The sole child-process allowlist: signature check or five fixed CLI shapes."""
    if action == "verify" and not arguments:
        return ("/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple", NATIVE_TOOL_PATH)
    common = ("--timeout", "20", "--json-output", "-")
    if action == "list" and not arguments:
        return (NATIVE_TOOL_PATH, "list", "devices") + common
    if action in ("details", "clear") and len(arguments) == 1:
        target = native_uuid(arguments[0])
        words = ("device", "info", "details") if action == "details" else ("device", "simulate", "location", "clear")
        return (NATIVE_TOOL_PATH,) + words + ("--device", target) + common
    if action == "set" and len(arguments) == 3:
        target = native_uuid(arguments[0])
        if any(not isinstance(value, str) or len(value) > 350 or DECIMAL_PATTERN.fullmatch(value) is None
               for value in arguments[1:]):
            raise NativeSchemaError()
        latitude = parse_coordinate(Decimal(arguments[1]), Decimal("-90"), Decimal("90"))
        longitude = parse_coordinate(Decimal(arguments[2]), Decimal("-180"), Decimal("180"))
        if latitude is None or longitude is None:
            raise NativeSchemaError()
        return (
            NATIVE_TOOL_PATH, "device", "simulate", "location", "coordinate", "--device", target,
            "--latitude=" + arguments[1], "--longitude=" + arguments[2],
        ) + common
    raise NativeSchemaError()


async def run_native_child(action: str, arguments: Tuple[str, ...] = ()) -> Tuple[int, bytes, bytes]:
    argv = native_child_arguments(action, arguments)
    process = await asyncio.create_subprocess_exec(
        *argv, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, env=native_child_environment(), cwd="/",
    )
    captured_bytes = 0

    async def capture(stream: Any) -> bytes:
        nonlocal captured_bytes
        chunks = []
        while True:
            chunk = await stream.read(65536)
            if not chunk:
                return b"".join(chunks)
            captured_bytes += len(chunk)
            if captured_bytes > NATIVE_OUTPUT_LIMIT:
                raise NativeCommandError()
            chunks.append(chunk)

    tasks = (
        asyncio.create_task(process.wait()),
        asyncio.create_task(capture(process.stdout)),
        asyncio.create_task(capture(process.stderr)),
    )
    try:
        result = await asyncio.wait_for(asyncio.gather(*tasks), timeout=NATIVE_PROCESS_TIMEOUT_SECONDS)
        return result[0], result[1], result[2]
    finally:
        if process.returncode is None:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(process.wait(), timeout=CLOSE_TIMEOUT_SECONDS)
            except BaseException:
                pass
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


class NativeLocationTool:
    async def verify(self) -> None:
        if not native_tool_file_valid():
            raise NativeToolUnavailableError()
        try:
            status, _output, _error = await run_native_child("verify")
        except (OSError, NativeCommandError, asyncio.TimeoutError):
            raise NativeToolUnavailableError() from None
        if status != 0:
            raise NativeToolUnavailableError()

    async def request(self, action: str, arguments: Tuple[str, ...] = ()) -> Dict[str, Any]:
        status, output, _error = await run_native_child(action, arguments)
        if status != 0:
            raise NativeCommandError()
        try:
            value = json.loads(
                output.decode("utf-8", errors="strict"),
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
        except (ValueError, UnicodeError):
            raise NativeSchemaError() from None
        if (
            not isinstance(value, dict) or not isinstance(value.get("info"), dict)
            or value["info"].get("outcome") != "success"
            or "error" in value or not isinstance(value.get("result"), dict)
        ):
            raise NativeSchemaError()
        return value["result"]


def native_hardware_records(record: Dict[str, Any]) -> list:
    properties = record.get("properties", {})
    if not isinstance(properties, dict):
        raise NativeSchemaError()
    records = []
    if "hardware" in properties:
        records.append(properties["hardware"])
    if "hardwareProperties" in record:
        records.append(record["hardwareProperties"])
    if not records or any(not isinstance(value, dict) for value in records):
        raise NativeSchemaError()
    return records


def attest_native_record(record: Any, udid: str, product_type: str, ecid: int) -> str:
    if not isinstance(record, dict):
        raise NativeSchemaError()
    target_uuid = native_uuid(record.get("identifier"))
    for hardware in native_hardware_records(record):
        if (
            normalized_udid(hardware.get("udid")) != normalized_udid(udid)
            or hardware.get("productType") != product_type
            or type(hardware.get("ecid")) is not int or hardware["ecid"] != ecid
            or hardware.get("deviceType") != "iPhone" or hardware.get("platform") != "iOS"
        ):
            raise TargetMismatchError()
    properties = record.get("properties", {})
    connections = []
    if "connection" in properties:
        connections.append((properties["connection"], "state"))
    if "connectionProperties" in record:
        connections.append((record["connectionProperties"], "tunnelState"))
    if not connections:
        raise NativeSchemaError()
    for connection, state_key in connections:
        if not isinstance(connection, dict):
            raise NativeSchemaError()
        if connection.get("pairingState") != "paired":
            raise PairingRequiredError()
        if connection.get(state_key) != "connected" or connection.get("transportType") != "wired":
            raise NativeTargetNotFoundError()
    state = properties.get("state", {})
    if not isinstance(state, dict):
        raise NativeSchemaError()
    if "developerModeStatus" in state:
        mode = state["developerModeStatus"]
        if not isinstance(mode, dict) or not isinstance(mode.get("enabled"), dict):
            raise DeveloperModeDisabledError()
    legacy_device = record.get("deviceProperties", {})
    if not isinstance(legacy_device, dict):
        raise NativeSchemaError()
    if "developerModeStatus" in legacy_device and legacy_device["developerModeStatus"] != "enabled":
        raise DeveloperModeDisabledError()
    return target_uuid


def select_native_target(result: Dict[str, Any], udid: str, product_type: str, ecid: int) -> str:
    devices = result.get("devices")
    if not isinstance(devices, list):
        raise NativeSchemaError()
    matching = []
    for record in devices:
        if not isinstance(record, dict):
            raise NativeSchemaError()
        try:
            hardware = native_hardware_records(record)
        except NativeSchemaError:
            continue  # unrelated simulators may not expose hardware identity
        if any(normalized_udid(value.get("udid")) == normalized_udid(udid) for value in hardware):
            matching.append(record)
    if not matching:
        raise NativeTargetNotFoundError()
    if len(matching) != 1:
        raise TargetMismatchError()
    return attest_native_record(matching[0], udid, product_type, ecid)


async def open_native_usb_target(imports: BackendImports, udid: str, product_type: str, ecid: int) -> Any:
    lockdown = await open_attested_lockdown(imports, udid, product_type, ecid, "USB")
    try:
        enabled = await asyncio.wait_for(lockdown.get_developer_mode_status(), timeout=SERVICE_TIMEOUT_SECONDS)
        if enabled is not True:
            raise DeveloperModeDisabledError()
        return lockdown
    except BaseException:
        await close_bounded(lockdown.close())
        raise


async def execute_native(
    command: str, imports: BackendImports, udid: str, product_type: str, ecid: int,
    latitude: Optional[float], longitude: Optional[float],
) -> int:
    emit_hello()
    lockdown = None
    phase = "usb"
    try:
        lockdown = await open_native_usb_target(imports, udid, product_type, ecid)
        if not await close_bounded(lockdown.close()):
            raise NativeCommandError()
        lockdown = None
        phase = "nativeTool"
        tool = imports.NativeLocationTool()
        await tool.verify()
        phase = "nativeAttestation"
        target_uuid = select_native_target(await tool.request("list"), udid, product_type, ecid)
        details = await tool.request("details", (target_uuid,))
        if attest_native_record(details, udid, product_type, ecid) != target_uuid:
            raise TargetMismatchError()
        capabilities = details.get("capabilities")
        if not isinstance(capabilities, list) or not any(
            isinstance(value, dict) and value.get("featureIdentifier") == NATIVE_CAPABILITY
            for value in capabilities
        ):
            raise NativeToolUnavailableError()
        # Details can be cached. Reopen and validate the exact live USB target
        # immediately before dispatch, retaining this handle through the action.
        phase = "usb"
        lockdown = await open_native_usb_target(imports, udid, product_type, ecid)
        emit("attested", "ok", product_type=product_type)
        emit("ready", "ok")
        if command == "probe-native":
            return 0
        phase = "nativeSet" if command == "set-native-persistent" else "nativeClear"
        emit("requestDispatched", "working")
        if command == "set-native-persistent":
            assert latitude is not None and longitude is not None
            result = await tool.request("set", (
                target_uuid, format(Decimal(repr(latitude)), "f"), format(Decimal(repr(longitude)), "f"),
            ))
        else:
            result = await tool.request("clear", (target_uuid,))
        if "deviceIdentifier" in result and native_uuid(result["deviceIdentifier"]) != target_uuid:
            raise TargetMismatchError()
        if command == "set-native-persistent":
            emit("active", "assumedActive", persistence="experimental")
        else:
            emit("clearSent", "realLocationExpected")
        return 0
    except TargetMismatchError:
        return fail("target_mismatch", "attestation")
    except PairingRequiredError:
        return fail("pairing_required", "pairing")
    except DeveloperModeDisabledError:
        return fail("developer_mode_required", "developerMode")
    except UnsupportedOSError:
        return fail("developer_service_unavailable", "attestation")
    except NativeToolUnavailableError:
        return fail("native_tool_unavailable", phase, 4)
    except NativeTargetNotFoundError:
        return fail("target_not_found", phase, 4)
    except (NativeCommandError, NativeSchemaError):
        return fail("developer_service_unavailable", phase, 4)
    except BaseException as error:
        return fail(map_exception(imports, error, phase), phase, 4)
    finally:
        if lockdown is not None:
            await close_bounded(lockdown.close())


async def read_live_control(tunnel: Any) -> Optional[bytes]:
    """Prefer transport loss over a simultaneous control request; never retry."""
    control_task = asyncio.create_task(read_stdin_line())
    closed_task = asyncio.create_task(tunnel.wait_closed())
    try:
        done, _pending = await asyncio.wait(
            (control_task, closed_task), return_when=asyncio.FIRST_COMPLETED,
        )
        if closed_task in done:
            # Reading the result consumes a sanitized upstream failure too.
            try:
                closed_task.result()
            except BaseException:
                pass
            return None
        return control_task.result()
    finally:
        for task in (control_task, closed_task):
            if not task.done():
                task.cancel()
        await asyncio.gather(control_task, closed_task, return_exceptions=True)


async def close_persistent_context(dvt: Any, tunnel: Any) -> bool:
    """Close both one-shot handles exactly once without leaking exceptions.

    Both closes are attempted even if the first fails. The caller converts a
    False result into a structured, privacy-safe protocol error after the Set
    acknowledgement; raw teardown exceptions are never serialized.
    """
    dvt_closed = await close_bounded(dvt.close())
    tunnel_closed = await close_bounded(tunnel.aclose())
    return dvt_closed and tunnel_closed


async def execute(command: str, request: Dict[str, Any], imports: BackendImports) -> int:
    allowed_fields = {"udid", "expectedProductType"}
    optional_fields = set()
    native_command = command in ("probe-native", "set-native-persistent", "clear-native")
    if command in ("set", "set-persistent", "set-native-persistent"):
        allowed_fields.update(("latitude", "longitude"))
    if command in ("reveal-developer-mode", "enable-wifi") or native_command:
        allowed_fields.add("expectedECID")
    if command in ("probe", "set", "clear"):
        optional_fields.update(("transport", "expectedECID"))
    if not allowed_fields.issubset(request) or not set(request).issubset(allowed_fields | optional_fields):
        return fail("invalid_request", "request", 2)

    udid = parse_udid(request.get("udid"))
    expected_product_type = parse_product_type(request.get("expectedProductType"))
    if udid is None or expected_product_type is None:
        return fail("invalid_request", "request", 2)

    if command in ("reveal-developer-mode", "enable-wifi"):
        expected_ecid = parse_ecid(request.get("expectedECID"))
        if expected_ecid is None:
            return fail("invalid_request", "request", 2)
        if command == "enable-wifi":
            return await enable_wifi(imports, udid, expected_product_type, expected_ecid)
        return await reveal_developer_mode(imports, udid, expected_product_type, expected_ecid)

    transport = request.get("transport", "usb")
    if transport not in ("usb", "wifi"):
        return fail("invalid_request", "request", 2)
    expected_ecid = None
    if native_command or transport == "wifi" or "expectedECID" in request:
        expected_ecid = parse_ecid(request.get("expectedECID"))
        if expected_ecid is None:
            return fail("invalid_request", "request", 2)

    latitude: Optional[float] = None
    longitude: Optional[float] = None
    if command in ("set", "set-persistent", "set-native-persistent"):
        latitude = parse_coordinate(request.get("latitude"), Decimal("-90"), Decimal("90"))
        longitude = parse_coordinate(request.get("longitude"), Decimal("-180"), Decimal("180"))
        if latitude is None or longitude is None:
            return fail("invalid_request", "request", 2)

    if native_command:
        assert expected_ecid is not None
        return await execute_native(
            command, imports, udid, expected_product_type, expected_ecid, latitude, longitude,
        )

    emit_hello()
    tunnel = None
    dvt = None
    phase = "tunnel"
    try:
        tunnel, rsd = await open_attested_target(
            imports, udid, expected_product_type, transport, expected_ecid,
        )
        phase = "dvt"
        dvt, location = await with_location_service(imports, rsd)
        phase = "location_service"
        emit("ready", "ok")

        if command == "probe":
            return 0

        if command == "clear":
            phase = "clear"
            emit("requestDispatched", "working")
            await asyncio.wait_for(location.clear(), timeout=SERVICE_TIMEOUT_SECONDS)
            emit("clearSent", "realLocationExpected")
            return 0

        phase = "set"
        assert latitude is not None and longitude is not None
        emit("requestDispatched", "working")
        await asyncio.wait_for(location.set(latitude, longitude), timeout=SERVICE_TIMEOUT_SECONDS)
        if command == "set-persistent":
            # This deliberately performs no clear, fork, detach, retry, or
            # keepalive. There is no read-back getter, so persistence remains
            # an experimental assumption.
            emit("active", "assumedActive", persistence="experimental")

            # Transfer ownership out of finally before awaiting either close.
            # This prevents a failed close from being attempted a second time.
            persistent_dvt, dvt = dvt, None
            persistent_tunnel, tunnel = tunnel, None
            if not await close_persistent_context(persistent_dvt, persistent_tunnel):
                emit(
                    "error",
                    "uncertain",
                    code="internal_failure",
                    phase="persistentTeardown",
                )
                return 5
            return 0

        emit("active", "assumedActive")

        while True:
            control_line = await read_live_control(tunnel)
            if control_line is None:
                emit("error", "uncertain", code="connection_lost", phase="transport")
                return 5
            control = parse_json_line(control_line)
            if control is None:
                emit("error", "uncertain", code="internal_failure", phase="control")
                return 5
            if set(control.keys()) != {"command"} or control.get("command") not in ("clear", "quit"):
                emit("error", "error", code="invalid_request", phase="control")
                continue
            if control["command"] == "quit":
                emit("error", "uncertain", code="internal_failure", phase="quitWithoutReset")
                return 0

            phase = "clear"
            emit("requestDispatched", "working")
            await asyncio.wait_for(location.clear(), timeout=SERVICE_TIMEOUT_SECONDS)
            emit("clearSent", "realLocationExpected")
            return 0
    except TargetMismatchError:
        return fail("target_mismatch", "attestation")
    except UnsupportedOSError:
        return fail("developer_service_unavailable", "attestation")
    except DeveloperModeDisabledError:
        return fail("developer_mode_required", "developerMode")
    except PairingRequiredError:
        return fail("pairing_required", "pairing")
    except BaseException as error:  # structured allowlist only; never serialize error text
        return fail(map_exception(imports, error, phase), phase, 4)
    finally:
        if dvt is not None:
            try:
                await asyncio.wait_for(dvt.close(), timeout=CLOSE_TIMEOUT_SECONDS)
            except BaseException:
                pass
        if tunnel is not None:
            try:
                await asyncio.wait_for(tunnel.aclose(), timeout=CLOSE_TIMEOUT_SECONDS)
            except BaseException:
                pass


def version_command() -> int:
    try:
        restrict_import_path()
        actual = metadata.version("pymobiledevice3")
    except BaseException:
        return fail("internal_failure", "startup", 4)
    if actual != PINNED_PYMOBILEDEVICE3_VERSION or sys.version_info[:2] != (3, 9):
        return fail("internal_failure", "startup", 4)
    emit_hello()
    return 0


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in (
        "version",
        "probe",
        "set",
        "set-persistent",
        "clear",
        "reveal-developer-mode",
        "enable-wifi",
        "probe-native",
        "set-native-persistent",
        "clear-native",
    ):
        return fail("invalid_request", "startup", 2)
    command = sys.argv[1]
    if command == "version":
        return version_command()

    # Avoid BufferedReader read-ahead consuming a subsequent live control line.
    initial_line = bytearray()
    while len(initial_line) <= MAX_REQUEST_BYTES:
        chunk = os.read(sys.stdin.fileno(), 1)
        initial_line.extend(chunk)
        if not chunk or chunk == b"\n":
            break
    request = parse_json_line(bytes(initial_line))
    if request is None:
        return fail("invalid_request", "request", 2)
    if sys.version_info[:2] != (3, 9):
        return fail("internal_failure", "startup", 4)
    try:
        imports = BackendImports()
    except BaseException:
        return fail("internal_failure", "startup", 4)
    return asyncio.run(execute(command, request, imports))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SystemExit:
        raise
    except BaseException:
        raise SystemExit(fail("internal_failure", "startup", 4))
