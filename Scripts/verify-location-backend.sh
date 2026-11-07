#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"

write_checksums=0
if [[ "${1:-}" == "--write-checksums" ]]; then
  write_checksums=1
  shift
fi

payload_root="${1:-${project_dir}/Vendor/LocationBackend/arm64}"
helpers_dir="${payload_root}/Helpers/YIOSLocation"
resources_dir="${payload_root}/Resources/YIOSLocation"
packages_dir="${resources_dir}/python-packages"
checksum_file="${payload_root}/Resources/LocationBackendPayload.sha256"
launcher="${helpers_dir}/yios-location-backend"
bridge="${resources_dir}/yios_location_backend.py"

fail() {
  print -u2 -- "Location backend verification failed: $*"
  exit 1
}

if (( write_checksums )); then
  [[ -d "$helpers_dir" && -d "$resources_dir" ]] || fail "payload directories are missing"
  /usr/bin/python3 - "$payload_root" "$checksum_file" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
files = []
for relative_root in (pathlib.Path("Helpers/YIOSLocation"), pathlib.Path("Resources/YIOSLocation")):
    files.extend(path for path in (root / relative_root).rglob("*") if path.is_file() and not path.is_symlink())
with output.open("w", encoding="utf-8") as stream:
    for path in sorted(files, key=lambda item: item.relative_to(root).as_posix()):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        stream.write("%s  %s\n" % (digest, path.relative_to(root).as_posix()))
PY
  exit 0
fi

[[ -d "$helpers_dir" && -d "$packages_dir" ]] || fail "payload directories are missing"
[[ -x "$launcher" && -f "$bridge" ]] || fail "restricted launcher is missing"
[[ ! -x "$bridge" ]] || fail "Python bridge must be a non-executable bundle resource"
[[ -f "${resources_dir}/LocationBackendManifest.json" ]] || fail "manifest is missing"
[[ -f "$checksum_file" ]] || fail "payload checksum list is missing"
[[ -f "${resources_dir}/Source/pymobiledevice3-10.9.0.tar.gz" ]] || fail "corresponding source is missing"
[[ -f "${resources_dir}/ThirdPartyNotices/pymobiledevice3-GPL-3.0-or-later.txt" ]] || fail "GPL notice is missing"
[[ -f "${resources_dir}/ThirdPartyNotices/test-yios-location-backend.py" ]] || fail "offline protocol test is missing"

[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "verification requires Apple silicon"
python_minor="$(/usr/bin/python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
[[ "$python_minor" == "3.9" ]] || fail "/usr/bin/python3 3.9 is required"

if /usr/bin/find "$helpers_dir" "$resources_dir" -type l -print -quit | /usr/bin/grep -q .; then
  fail "symlinks are not allowed in the payload"
fi
if /usr/bin/find "$helpers_dir" "$resources_dir" ! -type f ! -type d -print -quit | /usr/bin/grep -q .; then
  fail "special files are not allowed in the payload"
fi

/usr/bin/python3 - "$payload_root" "$checksum_file" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
listed = set()
for line in manifest.read_text(encoding="utf-8").splitlines():
    digest, separator, relative = line.partition("  ")
    if not separator or len(digest) != 64 or relative.startswith("/") or ".." in pathlib.PurePosixPath(relative).parts:
        raise SystemExit("invalid checksum manifest entry")
    listed.add(relative)
actual = set()
for relative_root in (pathlib.Path("Helpers/YIOSLocation"), pathlib.Path("Resources/YIOSLocation")):
    actual.update(
        path.relative_to(root).as_posix()
        for path in (root / relative_root).rglob("*")
        if path.is_file() and not path.is_symlink()
    )
if listed != actual:
    raise SystemExit("checksum manifest does not exactly match the payload file set")
PY

(
  cd "$payload_root"
  /usr/bin/shasum -a 256 -c "Resources/LocationBackendPayload.sha256" >/dev/null
)

source_checksum="$(/usr/bin/shasum -a 256 "${resources_dir}/Source/pymobiledevice3-10.9.0.tar.gz" | /usr/bin/awk '{print $1}')"
[[ "$source_checksum" == "20785dcd92b4d09277ede37573f0be765a8fa77df021208ee0787138b38526b4" ]] || fail "source checksum mismatch"

# Verify the narrow source contract. The only permitted Developer Mode mutation
# is the pinned upstream reveal-only Settings marker. These checks fail closed
# if future edits enable/accept Developer Mode, reboot, pair, mount a DDI,
# retry, use a raw AMFI plist action, or fall back to RemotePairing.
/usr/bin/grep -Fq 'autopair=False' "$bridge" || fail "autopair must remain disabled"
/usr/bin/grep -Fq 'remotepairing_fallback=False' "$bridge" || fail "RemotePairing fallback must remain disabled"
/usr/bin/grep -Fq 'IPHONE_PRODUCT_TYPE_PATTERN' "$bridge" || fail "iPhone ProductType validation is missing"
/usr/bin/grep -Fq 'parse_product_type(request.get("expectedProductType"))' "$bridge" || fail "requested iPhone identity validation is missing"
/usr/bin/grep -Fq 'getattr(rsd, "product_type", None) != expected_product_type' "$bridge" || fail "exact RSD ProductType attestation is missing"
/usr/bin/grep -Fq 'getattr(lockdown, "product_type", None) != expected_product_type' "$bridge" || fail "exact lockdown ProductType attestation is missing"
/usr/bin/grep -Fq 'get_developer_mode_status' "$bridge" || fail "Developer Mode readiness check is missing"
/usr/bin/grep -Fq 'connection_type="USB"' "$bridge" || fail "Developer Mode reveal must stay on exact USB"
/usr/bin/grep -Fq 'expectedECID' "$bridge" || fail "Developer Mode reveal ECID attestation is missing"
/usr/bin/grep -Fq 'reveal_developer_mode_option_in_ui' "$bridge" || fail "reveal-only Developer Mode method is missing"
/usr/bin/grep -Fq 'developerModeOptionRequested' "$bridge" || fail "Developer Mode option protocol event is missing"
/usr/bin/grep -Fq 'command == "set-persistent"' "$bridge" || fail "one-shot persistent experiment is missing"
/usr/bin/grep -Fq 'phase="persistentTeardown"' "$bridge" || fail "persistent teardown failure contract is missing"
if /usr/bin/grep -E 'enable_developer_mode|enable_developer_mode_post_restart|DEVELOPER_MODE_ENABLE|DEVELOPER_MODE_ACCEPT|retry_create_using_usbmux|mount_developer|mounter|autopair=True|start_tunnel_over_remotepairing|send_recv_plist' "$bridge" >/dev/null; then
  fail "a forbidden enable/reboot/DDI/pair/retry/raw-AMFI path is present"
fi
/usr/bin/python3 - "$bridge" <<'PY' || fail "the restricted bridge contains a forbidden call"
import ast
import pathlib
import sys

tree = ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    name = None
    if isinstance(node.func, ast.Name):
        name = node.func.id
    elif isinstance(node.func, ast.Attribute):
        name = node.func.attr
    if name in {
        "fork", "forkpty", "daemon", "setsid", "Popen",
        "enable_developer_mode", "enable_developer_mode_post_restart",
        "retry_create_using_usbmux", "send_recv_plist",
    }:
        raise SystemExit(1)
PY

# Exercise the set-persistent and reveal-only Developer Mode state machines with
# fully in-memory fakes. This proves the event order, exact target/USB options,
# and absence of clear/enable/reboot/pair/retry without opening a device service.
/usr/bin/python3 "${resources_dir}/ThirdPartyNotices/test-yios-location-backend.py" "$bridge" \
  || fail "offline backend protocol test failed"

native_count=0
while IFS= read -r native_file; do
  (( native_count += 1 ))
  architectures="$(/usr/bin/lipo -archs "$native_file")"
  [[ " ${architectures} " == *' arm64 '* ]] || fail "native dependency lacks arm64: ${native_file:t}"
  build_metadata="$(/usr/bin/xcrun vtool -show-build "$native_file")" || fail "cannot read deployment target: ${native_file:t}"
  /usr/bin/python3 -c '
import re, sys
text = sys.argv[1]
versions = re.findall(r"^\s+minos\s+([0-9]+(?:\.[0-9]+)*)\s*$", text, re.M)
versions += re.findall(r"cmd LC_VERSION_MIN_MACOSX.*?^\s+version\s+([0-9]+(?:\.[0-9]+)*)\s*$", text, re.M | re.S)
if not versions:
    raise SystemExit(1)
for raw in versions:
    parts = tuple(int(part) for part in raw.split("."))
    if parts > (13, 0):
        raise SystemExit(1)
' "$build_metadata" || fail "native dependency requires newer than macOS 13: ${native_file:t}"
  /usr/bin/codesign --verify --strict --all-architectures "$native_file" || fail "invalid signature: ${native_file:t}"
  if /usr/bin/otool -L "$native_file" | /usr/bin/grep '^[[:space:]]' | /usr/bin/grep -E '/opt/homebrew|/usr/local|/private/tmp|/YIOS/' >/dev/null; then
    fail "non-relocatable dependency in ${native_file:t}"
  fi
done < <(
  /usr/bin/find "$packages_dir" -type f -print | while IFS= read -r candidate; do
    /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O' && print -- "$candidate"
  done
)
(( native_count > 0 )) || fail "native dependency closure is missing"
/usr/bin/codesign --verify --strict "$launcher" || fail "launcher signature is invalid"

test_home="$(/usr/bin/mktemp -d /private/tmp/yios-location-home.XXXXXX)"
cleanup_test_home() {
  if [[ -n "${test_home:-}" && "$test_home" == /private/tmp/yios-location-home.* ]]; then
    /bin/rm -rf "$test_home"
  fi
}
trap cleanup_test_home EXIT INT TERM
version_output="$(/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LC_ALL=C \
  LANG=C \
  HOME="$test_home" \
  TMPDIR="${TMPDIR:-/private/tmp}" \
  "$launcher" version)" \
  || fail "version command failed"
line_count="$(print -r -- "$version_output" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$line_count" == "1" ]] || fail "version output is not one JSON line"
/usr/bin/python3 -c '
import json, sys
value = json.loads(sys.argv[1])
assert value == {
    "backend_version": "1.2.0",
    "event": "hello",
    "protocol": 1,
    "protocol_version": 1,
    "pymobiledevice3_version": "10.9.0",
    "python_version": "3.9",
    "status": "ok",
}
' "$version_output" || fail "unexpected version response"

# Import the complete pinned package closure without opening any device service.
# The invalid UDID is rejected only after BackendImports has loaded successfully,
# so this catches missing/incompatible Python dependencies while remaining offline.
set +e
invalid_output="$(/usr/bin/printf '%s\n' \
  '{"udid":"!","expectedProductType":"iPhone12,8"}' \
  | /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      LC_ALL=C \
      LANG=C \
      HOME="$test_home" \
      TMPDIR="${TMPDIR:-/private/tmp}" \
      "$launcher" probe)"
invalid_status=$?
set -e
[[ "$invalid_status" == "2" ]] || fail "offline import/request validation returned ${invalid_status}"
/usr/bin/python3 -c '
import json, sys
value = json.loads(sys.argv[1])
assert value["protocol"] == 1
assert value["event"] == "error"
assert value["status"] == "error"
assert value["code"] == "invalid_request"
assert value["phase"] == "request"
assert set(value) == {"protocol", "event", "status", "code", "phase"}
' "$invalid_output" || fail "offline import/request validation leaked or returned an unexpected response"

# Confirm the packaged command allowlist and request validation recognize the
# experimental path while rejecting the request before any tunnel is opened.
set +e
persistent_invalid_output="$(/usr/bin/printf '%s\n' \
  '{"udid":"!","expectedProductType":"iPhone12,8","latitude":"1","longitude":"2"}' \
  | /usr/bin/env -i \
      PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      LC_ALL=C \
      LANG=C \
      HOME="$test_home" \
      TMPDIR="${TMPDIR:-/private/tmp}" \
      "$launcher" set-persistent)"
persistent_invalid_status=$?
set -e
[[ "$persistent_invalid_status" == "2" ]] \
  || fail "offline set-persistent validation returned ${persistent_invalid_status}"
/usr/bin/python3 -c '
import json, sys
value = json.loads(sys.argv[1])
assert value == {
    "code": "invalid_request",
    "event": "error",
    "phase": "request",
    "protocol": 1,
    "status": "error",
}
' "$persistent_invalid_output" \
  || fail "offline set-persistent validation leaked or returned an unexpected response"

print -- "LOCATION BACKEND VERIFY PASS"
