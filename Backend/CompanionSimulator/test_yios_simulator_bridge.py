#!/usr/bin/python3
"""Offline HTTP, target, journal and process-lifetime contract checks."""

import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import uuid

from yios_simulator_bridge import (BridgeError, BridgeServer, BridgeState, MAX_REQUESTS,
                                   SIMCTL, SimulatorClient, bounded_command, decode_json)


TARGET = "2A16B14C-335B-4297-A94F-4E0C7733A70C"
SESSION = "12345678-1234-1234-1234-123456789ABC"
TOKEN = "a" * 64


def request_id():
    return str(uuid.uuid4()).upper()


class FakeClient:
    def __init__(self, journal):
        self.journal = journal
        self.available = True
        self.fail = False
        self.attestations = 0
        self.operations = []
        self.entered = None
        self.release = None

    def attest(self, target):
        assert target == TARGET
        self.attestations += 1
        if not self.available:
            raise BridgeError("target_unavailable", 409)

    def mutate(self, operation, target):
        assert target == TARGET
        document = json.loads(self.journal.read_text())
        assert document["state"] == "uncertain", "journal must precede dispatch"
        self.operations.append(operation)
        if self.entered:
            self.entered.set()
            self.release.wait(timeout=3)
        if self.fail:
            raise BridgeError("simulator_command_failed", 409)

    def set(self, target, latitude, longitude):
        assert latitude == 16.8409 and longitude == 96.1735
        self.mutate("set", target)

    def clear(self, target):
        self.mutate("clear", target)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yios-simulator-tests-")
        self.journal = Path(self.temporary.name).resolve() / "private" / "state.json"
        self.client = FakeClient(self.journal)
        self.state = BridgeState(TARGET, self.client, self.journal, SESSION, TOKEN)
        self.server = BridgeServer(self.state)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.temporary.cleanup()

    def http(self, method, path, body=None, token=TOKEN, extra_headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        headers = {"Authorization": "Bearer " + token}
        if body is not None:
            body = json.dumps(body, allow_nan=True).encode() if not isinstance(body, bytes) else body
            headers["Content-Type"] = "application/json"
        headers.update(extra_headers or {})
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        document = json.loads(response.read())
        status = response.status
        connection.close()
        return status, document

    def set_body(self, identifier=None):
        return {"requestID": identifier or request_id(), "latitude": 16.8409, "longitude": 96.1735}

    def test_exact_session_and_no_coordinates_in_status(self):
        status, value = self.http("GET", "/v1/status")
        self.assertEqual(status, 200)
        self.assertEqual(value, {"protocol": 1, "sessionID": SESSION, "simulatorID": TARGET, "state": "idle", "revision": 0})
        self.assertEqual(self.server.server_address[0], "127.0.0.1")

    def test_unauthorized_does_not_mutate_or_write_journal(self):
        self.assertEqual(self.http("POST", "/v1/set", self.set_body(), "b" * 64)[0], 401)
        self.assertEqual(self.http("GET", "/v1/status", token="b" * 64)[0], 401)
        self.assertEqual(self.http("GET", "/v1/status", token="é" * 64)[0], 401)
        self.assertEqual(self.client.operations, [])
        self.assertEqual(self.client.attestations, 0)
        self.assertFalse(self.journal.exists())

    def test_browser_and_wrong_endpoint_rejected(self):
        self.assertEqual(self.http("POST", "/v1/set", self.set_body(), extra_headers={"Origin": "http://evil.invalid"})[0], 403)
        self.assertEqual(self.http("POST", "/v1/launch", self.set_body())[0], 404)
        self.assertEqual(self.http("GET", "/v1/status?target=booted")[0], 404)
        self.assertEqual(self.client.operations, [])

    def test_invalid_coordinates_cannot_dispatch(self):
        for coordinate in [True, False, "16.8409", None, float("nan"), float("inf"), -90.0001, 90.0001]:
            body = self.set_body()
            body["latitude"] = coordinate
            self.assertEqual(self.http("POST", "/v1/set", body)[0], 400)
        for coordinate in [-180.0001, 180.0001, True, "96.1735"]:
            body = self.set_body()
            body["longitude"] = coordinate
            self.assertEqual(self.http("POST", "/v1/set", body)[0], 400)
        body = self.set_body()
        body["simulatorID"] = "booted"
        self.assertEqual(self.http("POST", "/v1/set", body)[0], 400)
        self.assertEqual(self.client.operations, [])
        self.assertEqual(self.state.status()["revision"], 0)

    def test_duplicate_json_keys_and_large_bodies_rejected(self):
        raw = ('{"requestID":"' + request_id() + '","latitude":1,"latitude":2,"longitude":3}').encode()
        self.assertEqual(self.http("POST", "/v1/set", raw)[0], 400)
        self.assertEqual(self.http("POST", "/v1/set", b" " * 5000)[0], 413)
        self.assertEqual(self.client.operations, [])

    def test_success_and_immediate_replay_dispatch_once(self):
        body = self.set_body()
        first = self.http("POST", "/v1/set", body)
        second = self.http("POST", "/v1/set", body)
        self.assertEqual(first, second)
        self.assertEqual(first[0], 200)
        self.assertEqual(first[1]["requestID"], body["requestID"])
        self.assertEqual(first[1]["state"], "setAccepted")
        self.assertEqual(first[1]["acknowledgement"], "accepted")
        self.assertEqual(self.client.operations, ["set"])
        self.assertEqual(self.client.attestations, 1)
        data = self.journal.read_text()
        self.assertNotIn("16.8409", data)
        self.assertNotIn("96.1735", data)
        self.assertEqual(self.journal.stat().st_mode & 0o777, 0o600)

    def test_changed_body_same_nonce_and_stale_replay_rejected(self):
        body = self.set_body()
        self.http("POST", "/v1/set", body)
        changed = body.copy()
        changed["latitude"] = 1.3521
        self.assertEqual(self.http("POST", "/v1/set", changed)[1]["error"], "request_id_conflict")
        self.http("POST", "/v1/clear", {"requestID": request_id()})
        self.assertEqual(self.http("POST", "/v1/set", body)[1]["error"], "stale_request")
        self.assertEqual(self.client.operations, ["set", "clear"])

    def test_uncertain_is_cached_and_requires_clear(self):
        self.client.fail = True
        body = self.set_body()
        first = self.http("POST", "/v1/set", body)
        replay = self.http("POST", "/v1/set", body)
        self.assertEqual(first, replay)
        self.assertEqual(first[0], 409)
        self.assertEqual(first[1]["acknowledgement"], "uncertain")
        self.assertEqual(self.client.operations, ["set"])
        self.assertEqual(self.http("POST", "/v1/set", self.set_body())[1]["error"], "clear_required")
        self.client.fail = False
        self.assertEqual(self.http("POST", "/v1/clear", {"requestID": request_id()})[0], 200)
        self.assertEqual(self.state.status()["state"], "clearAccepted")

    def test_unexpected_clear_failure_is_cached_before_retry(self):
        original = self.client.clear

        def fail(target):
            original(target)
            raise RuntimeError("unexpected post-dispatch failure")

        self.client.clear = fail
        body = {"requestID": request_id()}
        first = self.http("POST", "/v1/clear", body)
        second = self.http("POST", "/v1/clear", body)
        self.assertEqual(first, second)
        self.assertEqual(first[0], 409)
        self.assertEqual(first[1]["acknowledgement"], "uncertain")
        self.assertEqual(self.client.operations, ["clear"])

    def test_target_failure_does_not_mutate_or_write_journal(self):
        self.client.available = False
        self.assertEqual(self.http("POST", "/v1/set", self.set_body())[1]["error"], "target_unavailable")
        self.assertEqual(self.client.operations, [])
        self.assertFalse(self.journal.exists())

    def test_recovered_set_needs_manual_clear_and_no_auto_reset(self):
        self.http("POST", "/v1/set", self.set_body())
        recovered = BridgeState(TARGET, self.client, self.journal, token=TOKEN)
        self.assertEqual(recovered.status()["state"], "uncertain")
        with self.assertRaises(BridgeError) as error:
            recovered.mutate("set", self.set_body())
        self.assertEqual(error.exception.code, "clear_required")
        self.assertEqual(self.client.operations, ["set"])
        self.assertEqual(recovered.mutate("clear", {"requestID": request_id()})[0], 200)

    def test_corrupt_or_wrong_target_journal_fails_closed(self):
        self.journal.parent.mkdir(mode=0o700)
        self.journal.write_text("bad json")
        with self.assertRaises(BridgeError):
            BridgeState(TARGET, self.client, self.journal, token=TOKEN)
        self.journal.write_text(json.dumps({"protocol": 1, "simulatorID": str(uuid.uuid4()), "revision": 0}))
        with self.assertRaises(BridgeError):
            BridgeState(TARGET, self.client, self.journal, token=TOKEN)

    def test_parallel_mutations_do_not_overlap(self):
        self.client.entered, self.client.release = threading.Event(), threading.Event()
        result = []
        worker = threading.Thread(target=lambda: result.append(self.http("POST", "/v1/set", self.set_body())))
        worker.start()
        self.assertTrue(self.client.entered.wait(timeout=2))
        code, value = self.http("POST", "/v1/clear", {"requestID": request_id()})
        self.assertEqual(code, 409)
        self.assertEqual(value["error"], "operation_busy")
        self.client.release.set()
        worker.join(timeout=3)
        self.assertEqual(result[0][0], 200)
        self.assertEqual(self.client.operations, ["set"])

    def test_request_limit_never_evicts_a_nonce(self):
        for _ in range(MAX_REQUESTS):
            self.assertEqual(self.state.mutate("clear", {"requestID": request_id()})[0], 200)
        with self.assertRaises(BridgeError) as error:
            self.state.mutate("clear", {"requestID": request_id()})
        self.assertEqual(error.exception.code, "session_request_limit")
        self.assertEqual(len(self.client.operations), MAX_REQUESTS)

    def test_request_limit_reserves_one_clear_for_last_active_set(self):
        for _ in range(MAX_REQUESTS - 1):
            self.state.mutate("clear", {"requestID": request_id()})
        self.state.mutate("set", self.set_body())
        self.assertEqual(self.state.status()["state"], "setAccepted")
        self.assertEqual(self.state.mutate("clear", {"requestID": request_id()})[0], 200)
        self.assertEqual(self.state.status()["state"], "clearAccepted")
        self.assertEqual(len(self.state.cache), MAX_REQUESTS + 1)
        with self.assertRaises(BridgeError):
            self.state.mutate("set", self.set_body())


class ClientTests(unittest.TestCase):
    def records(self, state="Booted", target=TARGET, available=True, kind="iPhone-17"):
        return {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            {"udid": target, "state": state, "isAvailable": available,
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + kind}
        ]}}

    def test_booted_exact_iphone_required(self):
        for records in [self.records(state="Shutdown"), self.records(target=str(uuid.uuid4())),
                        self.records(available=False), self.records(kind="iPad-Pro"), {"devices": {}}]:
            client = SimulatorClient(runner=lambda args, timeout: json.dumps(records).encode())
            with self.assertRaises(BridgeError) as error:
                client.attest(TARGET)
            self.assertEqual(error.exception.code, "target_unavailable")
        SimulatorClient(runner=lambda args, timeout: json.dumps(self.records()).encode()).attest(TARGET)

    def test_only_fixed_tool_exact_uuid_and_coordinate_arguments(self):
        commands = []
        client = SimulatorClient(runner=lambda args, timeout: commands.append(args) or b"")
        client.set(TARGET, -0.000000000000001, -180)
        client.clear(TARGET)
        self.assertEqual(commands[0], [SIMCTL, "location", TARGET, "set", "-0.000000000000001,-180.000000000000000"])
        self.assertEqual(commands[1], [SIMCTL, "location", TARGET, "clear"])

    def test_duplicate_and_nonfinite_json_rejected(self):
        for data in [b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}', b'\xff']:
            with self.assertRaises(BridgeError):
                decode_json(data)

    def test_process_output_and_timeout_are_bounded(self):
        self.assertEqual(bounded_command(["/usr/bin/python3", "-c", "print('ok')"], 2), b"ok\n")
        for script, timeout in [("import sys; sys.stdout.write('x' * 3000000)", 2),
                                ("import time; time.sleep(10)", 0.05)]:
            started = time.monotonic()
            with self.assertRaises(BridgeError):
                bounded_command(["/usr/bin/python3", "-c", script], timeout)
            self.assertLess(time.monotonic() - started, 5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
