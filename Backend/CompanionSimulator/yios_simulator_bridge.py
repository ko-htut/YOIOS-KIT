#!/usr/bin/python3
"""A loopback-only, exact-simulator location bridge for YIOS-KIT development.

This program never invokes a physical-device tool. An acknowledgement means
simctl accepted a request; the iOS app independently checks Core Location.
"""

from __future__ import annotations

import argparse
import datetime
import fcntl
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import stat
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Dict, Optional, Tuple
import uuid


PROTOCOL = 1
MAX_BODY = 4096
MAX_REQUESTS = 128
MAX_COMMAND_OUTPUT = 2 * 1024 * 1024
XCRUN = "/usr/bin/xcrun"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
SIMCTL_WRAPPER = DEVELOPER_DIR + "/usr/bin/simctl"
SIMCTL = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
CHILD_ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "C", "LC_ALL": "C", "DEVELOPER_DIR": DEVELOPER_DIR,
    "TMPDIR": tempfile.gettempdir(),
}


class BridgeError(Exception):
    def __init__(self, code: str, status: int = 400):
        super().__init__(code)
        self.code, self.status = code, status


def canonical_uuid(value: Any) -> str:
    if not isinstance(value, str) or len(value) != 36:
        raise BridgeError("invalid_request")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        raise BridgeError("invalid_request")
    if str(parsed) != value.lower():
        raise BridgeError("invalid_request")
    return str(parsed).upper()


def decode_json(data: bytes) -> Any:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def constant(_):
        raise ValueError("nonfinite constant")

    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)
    except (ValueError, UnicodeError, RecursionError):
        raise BridgeError("invalid_request")


def secure_directory(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or path.resolve() != path.absolute():
        raise BridgeError("private_storage_unavailable", 500)
    os.chmod(path, 0o700)


def write_private_json(path: Path, document: Dict[str, Any]) -> None:
    secure_directory(path.parent)
    if path.exists() or path.is_symlink():
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise BridgeError("private_storage_unavailable", 500)
    descriptor, temporary = tempfile.mkstemp(prefix=".bridge-", dir=str(path.parent))
    try:
        os.fchmod(descriptor, 0o600)
        payload = json.dumps(document, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8") + b"\n"
        with os.fdopen(descriptor, "wb") as output:
            descriptor = -1
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    except OSError:
        raise BridgeError("private_storage_unavailable", 500)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def bounded_command(arguments, timeout: float = 15, simulator_launch_config: Optional[str] = None) -> bytes:
    """Capture at most 2 MiB, kill the private process group, and reap on error."""
    environment = CHILD_ENV.copy()
    if simulator_launch_config is not None:
        if arguments[:2] != [SIMCTL, "launch"] or len(simulator_launch_config.encode("utf-8")) > MAX_BODY:
            raise BridgeError("invalid_configuration")
        environment["SIMCTL_CHILD_YIOS_SIMULATOR_BRIDGE_CONFIG"] = simulator_launch_config
    process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=environment, cwd="/", start_new_session=True)
    output = bytearray()
    total = 0
    overflow = threading.Event()
    lock = threading.Lock()

    def stop(kind):
        try:
            os.killpg(process.pid, kind)
        except ProcessLookupError:
            pass

    def read(stream, keep):
        nonlocal total
        try:
            while True:
                data = os.read(stream.fileno(), 8192)
                if not data:
                    return
                with lock:
                    total += len(data)
                    if total > MAX_COMMAND_OUTPUT:
                        overflow.set()
                    elif keep:
                        output.extend(data)
                if overflow.is_set():
                    stop(signal.SIGTERM)
                    return
        except (OSError, ValueError):
            return

    threads = [threading.Thread(target=read, args=(process.stdout, True), daemon=True),
               threading.Thread(target=read, args=(process.stderr, False), daemon=True)]
    for thread in threads:
        thread.start()
    failed = False
    try:
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            failed = True
            stop(signal.SIGTERM)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                stop(signal.SIGKILL)
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    raise BridgeError("simulator_command_failed", 409)
        for thread in threads:
            thread.join(timeout=1)
        if any(thread.is_alive() for thread in threads):
            failed = True
            stop(signal.SIGKILL)
        with lock:
            captured = bytes(output)
        if failed or overflow.is_set() or process.returncode != 0:
            raise BridgeError("simulator_command_failed", 409)
        return captured
    finally:
        if process.poll() is None:
            stop(signal.SIGKILL)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        process.stdout.close()
        process.stderr.close()
        for thread in threads:
            thread.join(timeout=1)


class SimulatorClient:
    def __init__(self, runner: Callable = bounded_command):
        self.runner = runner

    def verify_tool(self) -> None:
        try:
            resolved = self.runner([XCRUN, "--find", "simctl"], 10).decode("utf-8").strip()
            if resolved != SIMCTL_WRAPPER:
                raise BridgeError("simulator_tool_unavailable", 503)
            current, first = Path(SIMCTL), True
            while True:
                metadata = current.lstat()
                expected = stat.S_ISREG if first else stat.S_ISDIR
                if not expected(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
                    raise BridgeError("simulator_tool_unavailable", 503)
                if current == Path("/"):
                    break
                current, first = current.parent, False
            with open(SIMCTL, "rb") as source:
                if source.read(4) not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe",
                                          b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
                    raise BridgeError("simulator_tool_unavailable", 503)
            self.runner(["/usr/bin/codesign", "--verify", "--strict", "-R", "=anchor apple", SIMCTL], 10)
        except (OSError, UnicodeError, BridgeError):
            raise BridgeError("simulator_tool_unavailable", 503)

    def attest(self, target: str) -> None:
        try:
            document = decode_json(self.runner([SIMCTL, "list", "devices", "--json"], 15))
            devices = document["devices"]
            if not isinstance(devices, dict):
                raise BridgeError("target_unavailable", 409)
            matches = []
            for runtime, records in devices.items():
                if not isinstance(runtime, str) or not isinstance(records, list):
                    raise BridgeError("target_unavailable", 409)
                for record in records:
                    if isinstance(record, dict) and isinstance(record.get("udid"), str) and record["udid"].upper() == target:
                        matches.append((runtime, record))
            if len(matches) != 1:
                raise BridgeError("target_unavailable", 409)
            runtime, record = matches[0]
            if not runtime.startswith("com.apple.CoreSimulator.SimRuntime.iOS-") or record.get("state") != "Booted" or record.get("isAvailable") is not True:
                raise BridgeError("target_unavailable", 409)
            kind = record.get("deviceTypeIdentifier")
            if not isinstance(kind, str) or not kind.startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-"):
                raise BridgeError("target_unavailable", 409)
        except (KeyError, TypeError, BridgeError):
            raise BridgeError("target_unavailable", 409)

    def set(self, target: str, latitude: float, longitude: float) -> None:
        coordinate = "{:.15f},{:.15f}".format(latitude, longitude)
        self.runner([SIMCTL, "location", target, "set", coordinate], 15)

    def clear(self, target: str) -> None:
        self.runner([SIMCTL, "location", target, "clear"], 15)


class BridgeState:
    def __init__(self, target: str, client: SimulatorClient, journal: Path,
                 session_id: Optional[str] = None, token: Optional[str] = None):
        self.target = canonical_uuid(target)
        self.session_id = canonical_uuid(session_id or str(uuid.uuid4()))
        self.token = token or secrets.token_hex(32)
        if not re.fullmatch(r"[0-9a-f]{64}", self.token):
            raise BridgeError("invalid_configuration")
        self.client, self.journal = client, journal
        self.operation_lock = threading.Lock()
        self.state_lock = threading.RLock()
        self.state, self.revision = "idle", 0
        self.cache = {}  # Never evict a nonce and thereby permit mutation replay.
        self.last_request = None
        self._recover_journal()

    def _recover_journal(self) -> None:
        if not self.journal.exists() and not self.journal.is_symlink():
            return
        try:
            metadata = self.journal.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_size > 8192:
                raise ValueError()
            document = decode_json(self.journal.read_bytes())
            if document.get("protocol") != PROTOCOL or document.get("simulatorID") != self.target:
                raise ValueError()
            revision = document.get("revision")
            if type(revision) is not int or revision < 0:
                raise ValueError()
            self.revision = revision
            self.state = "clearAccepted" if document.get("state") == "clearAccepted" else "uncertain"
        except (OSError, ValueError, AttributeError, BridgeError):
            raise BridgeError("journal_unreadable", 503)

    def status(self) -> Dict[str, Any]:
        with self.state_lock:
            return {"protocol": PROTOCOL, "sessionID": self.session_id, "simulatorID": self.target,
                    "state": self.state, "revision": self.revision}

    def _record(self, state: str, revision: int, request_id: str, digest: str) -> None:
        document = {"protocol": PROTOCOL, "simulatorID": self.target, "state": state,
                    "revision": revision, "lastRequestID": request_id, "requestDigest": digest,
                    "updatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
        write_private_json(self.journal, document)
        with self.state_lock:
            self.state, self.revision = state, revision

    def mutate(self, operation: str, body: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        expected = {"requestID", "latitude", "longitude"} if operation == "set" else {"requestID"}
        if operation not in ("set", "clear") or not isinstance(body, dict) or set(body) != expected:
            raise BridgeError("invalid_request")
        request_id = canonical_uuid(body["requestID"])
        latitude = longitude = None
        if operation == "set":
            latitude, longitude = body["latitude"], body["longitude"]
            if type(latitude) not in (int, float) or type(longitude) not in (int, float):
                raise BridgeError("invalid_request")
            try:
                latitude, longitude = float(latitude), float(longitude)
            except (ValueError, OverflowError):
                raise BridgeError("invalid_request")
            if not math.isfinite(latitude) or not math.isfinite(longitude) or not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
                raise BridgeError("invalid_request")
        canonical = json.dumps([operation, latitude.hex() if latitude is not None else None,
                                longitude.hex() if longitude is not None else None], separators=(",", ":"))
        digest = hashlib.sha256(canonical.encode("ascii")).hexdigest()
        if not self.operation_lock.acquire(blocking=False):
            raise BridgeError("operation_busy", 409)
        try:
            if request_id in self.cache:
                cached_digest, code, response = self.cache[request_id]
                if not hmac.compare_digest(cached_digest, digest):
                    raise BridgeError("request_id_conflict", 409)
                if response.get("revision") != self.revision:
                    raise BridgeError("stale_request", 409)
                return code, response.copy()
            reserved_clear = (len(self.cache) == MAX_REQUESTS and operation == "clear"
                              and self.state in ("setAccepted", "uncertain"))
            if len(self.cache) >= MAX_REQUESTS and not reserved_clear:
                raise BridgeError("session_request_limit", 409)
            if operation == "set" and self.state == "uncertain":
                raise BridgeError("clear_required", 409)
            self.client.attest(self.target)
            revision = self.revision + 1
            # Durably establish uncertainty before invoking the OS tool.
            self._record("uncertain", revision, request_id, digest)
            code, acknowledgement = 200, "accepted"
            try:
                if operation == "set":
                    self.client.set(self.target, latitude, longitude)
                else:
                    self.client.clear(self.target)
                self._record("setAccepted" if operation == "set" else "clearAccepted", revision, request_id, digest)
            except Exception:
                # Even an unexpected post-dispatch error must retain and cache
                # uncertainty. Retrying the same Clear nonce must not dispatch
                # a second OS operation after a malformed tool response.
                code, acknowledgement = 409, "uncertain"
                with self.state_lock:
                    self.state, self.revision = "uncertain", revision
            response = self.status()
            response.update({"requestID": request_id, "operation": operation, "acknowledgement": acknowledgement})
            self.cache[request_id] = (digest, code, response.copy())
            self.last_request = request_id
            return code, response
        finally:
            self.operation_lock.release()


class BridgeServer(ThreadingHTTPServer):
    # A normal shutdown waits for the bounded in-flight OS request to be reaped.
    # It must not abandon a child simctl while releasing the controller lock.
    daemon_threads = False
    request_queue_size = 8

    def __init__(self, state: BridgeState):
        self.bridge = state
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(("127.0.0.1", 0), BridgeHandler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # Never log request headers, body, auth token, coordinates or tool output.
        pass


class BridgeHandler(BaseHTTPRequestHandler):
    server_version = "YIOSSimulatorBridge/1"
    sys_version = ""
    protocol_version = "HTTP/1.0"

    def setup(self):
        super().setup()
        self.connection.settimeout(3)

    def log_message(self, format, *args):
        pass

    def _send(self, code, document):
        data = json.dumps(document, separators=(",", ":"), allow_nan=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def _auth(self):
        values = self.headers.get_all("Authorization", [])
        expected = "Bearer " + self.server.bridge.token
        if len(values) != 1 or not hmac.compare_digest(values[0].encode("utf-8"), expected.encode("ascii")):
            raise BridgeError("unauthorized", 401)
        if self.headers.get("Origin") is not None:
            raise BridgeError("browser_requests_rejected", 403)
        if self.headers.get("Transfer-Encoding") is not None:
            raise BridgeError("invalid_request")

    def _error(self, error):
        self._send(error.status, {"protocol": PROTOCOL, "error": error.code})

    def do_GET(self):
        try:
            self._auth()
            if self.path != "/v1/status":
                raise BridgeError("unknown_endpoint", 404)
            self._send(200, self.server.bridge.status())
        except BridgeError as error:
            self._error(error)

    def do_POST(self):
        try:
            self._auth()
            operation = {"/v1/set": "set", "/v1/clear": "clear"}.get(self.path)
            if operation is None:
                raise BridgeError("unknown_endpoint", 404)
            lengths = self.headers.get_all("Content-Length", [])
            if len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,5}", lengths[0]):
                raise BridgeError("invalid_request")
            length = int(lengths[0])
            if length < 2 or length > MAX_BODY:
                raise BridgeError("invalid_request", 413)
            content_types = self.headers.get_all("Content-Type", [])
            if len(content_types) != 1 or content_types[0].lower() not in ("application/json", "application/json; charset=utf-8"):
                raise BridgeError("invalid_request", 415)
            data = self.rfile.read(length)
            if len(data) != length:
                raise BridgeError("invalid_request")
            code, response = self.server.bridge.mutate(operation, decode_json(data))
            self._send(code, response)
        except BridgeError as error:
            self._error(error)
        except (OSError, socket.timeout):
            self.close_connection = True


def main() -> int:
    parser = argparse.ArgumentParser(description="Run YIOS-KIT's loopback-only exact-iPhone-simulator bridge.")
    parser.add_argument("--simulator", required=True, help="Exact booted iPhone Simulator UUID; never 'booted'.")
    parser.add_argument("--config", required=True, type=Path, help="Private JSON config for SIMCTL_CHILD_YIOS_SIMULATOR_BRIDGE_CONFIG.")
    parser.add_argument("--state-dir", type=Path, help="Private journal directory; defaults to this user's Application Support.")
    args = parser.parse_args()
    server, lock_descriptor = None, -1
    try:
        target = canonical_uuid(args.simulator)
        directory = (args.state_dir or Path.home() / "Library/Application Support/YIOS-KIT/CompanionSimulator" / target).absolute()
        secure_directory(directory)
        # A custom journal directory cannot create a second controller for the
        # same simulator. The lock always lives in one fixed per-user location.
        lock_directory = Path.home() / "Library/Application Support/YIOS-KIT/CompanionSimulator/Locks"
        secure_directory(lock_directory)
        lock_path = lock_directory / (target + ".lock")
        lock_descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        metadata = os.fstat(lock_descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise BridgeError("private_storage_unavailable", 500)
        try:
            fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BridgeError("simulator_controller_already_running", 409)
        client = SimulatorClient()
        client.verify_tool()
        client.attest(target)
        state = BridgeState(target, client, directory / "state.json")
        server = BridgeServer(state)
        config = {"protocol": PROTOCOL, "baseURL": "http://127.0.0.1:" + str(server.server_address[1]),
                  "token": state.token, "sessionID": state.session_id, "simulatorID": target}
        write_private_json(args.config.absolute(), config)

        def shutdown(signum, frame):
            threading.Thread(target=server.shutdown, daemon=True).start()

        signal.signal(signal.SIGTERM, shutdown)
        signal.signal(signal.SIGINT, shutdown)
        print("Simulator bridge ready. Private launch configuration saved.", flush=True)
        print("Stopping the bridge does not clear a simulated location. Use Clear in the Companion first.", flush=True)
        server.serve_forever(poll_interval=0.2)
        return 0
    except (BridgeError, OSError) as error:
        code = error.code if isinstance(error, BridgeError) else "bridge_start_failed"
        print("Simulator bridge: " + code, flush=True)
        return 1
    finally:
        if server is not None:
            server.server_close()
        if lock_descriptor >= 0:
            os.close(lock_descriptor)


if __name__ == "__main__":
    raise SystemExit(main())
