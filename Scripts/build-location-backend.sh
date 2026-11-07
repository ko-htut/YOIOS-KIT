#!/bin/zsh
set -euo pipefail

# Build the app-private Python 3.9 runtime payload used only by the restricted
# Mock Location bridge. This script never contacts a phone.

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
backend_source="${project_dir}/Backend/MockLocation"
cache_dir="${YIOS_LOCATION_CACHE:-${project_dir}/.build-cache/location-backend-downloads}"
artifact_cache="${cache_dir}/dependency-artifacts"
vendor_target="${project_dir}/Vendor/LocationBackend/arm64"
python="/usr/bin/python3"
pymobiledevice_version="10.9.0"

pymobiledevice_wheel="pymobiledevice3-10.9.0-py3-none-any.whl"
pymobiledevice_wheel_url="https://files.pythonhosted.org/packages/02/a6/d241e52b152b971a807105c8d2f6902ee6b68800546bfcf3aa85b00949b1/pymobiledevice3-10.9.0-py3-none-any.whl"
pymobiledevice_wheel_sha256="dc1ac7e3eb3d12622f9a354b66c1368f2b7145344dd1a145ef191ef47b00bb4b"
pymobiledevice_source="pymobiledevice3-10.9.0.tar.gz"
pymobiledevice_source_url="https://files.pythonhosted.org/packages/6f/55/b8e0b5308133a5c1892018730bda7350cf6facbccc041c80e086efd0d365/pymobiledevice3-10.9.0.tar.gz"
pymobiledevice_source_sha256="20785dcd92b4d09277ede37573f0be765a8fa77df021208ee0787138b38526b4"

fail() {
  print -u2 -- "Location backend build failed: $*"
  exit 1
}

sha256_for() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

download_and_verify() {
  local filename="$1"
  local url="$2"
  local expected="$3"
  local destination="${cache_dir}/${filename}"

  if [[ -f "$destination" && "$(sha256_for "$destination")" == "$expected" ]]; then
    print -- "Using cached ${filename}"
    return
  fi
  [[ "${YIOS_LOCATION_OFFLINE:-0}" != "1" ]] || fail "verified cached artifact is required in offline mode: ${filename}"

  local partial="${destination}.partial.$$"
  /bin/rm -f "$partial"
  /usr/bin/curl --fail --location --retry 3 --output "$partial" "$url"
  local actual
  actual="$(sha256_for "$partial")"
  [[ "$actual" == "$expected" ]] || fail "checksum mismatch for ${filename}: ${actual}"
  /bin/mv "$partial" "$destination"
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "this payload targets macOS"
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || fail "this payload targets Apple silicon"
[[ -x "$python" ]] || fail "/usr/bin/python3 is required"
python_minor="$($python -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
[[ "$python_minor" == "3.9" ]] || fail "/usr/bin/python3 3.9 is required (found ${python_minor})"
[[ -f "${backend_source}/requirements-python39.lock" ]] || fail "dependency lock is missing"
[[ -f "${backend_source}/dependency-artifacts.sha256" ]] || fail "dependency artifact manifest is missing"
[[ -f "${backend_source}/yios_location_backend.py" ]] || fail "backend bridge is missing"
[[ -f "${backend_source}/test_yios_location_backend.py" ]] || fail "offline protocol test is missing"

/bin/mkdir -p "$cache_dir" "$artifact_cache"
download_and_verify "$pymobiledevice_wheel" "$pymobiledevice_wheel_url" "$pymobiledevice_wheel_sha256"
download_and_verify "$pymobiledevice_source" "$pymobiledevice_source_url" "$pymobiledevice_source_sha256"

# Resolve the version lock into a persistent wheel/source cache, then require an
# exact filename set and SHA-256 match before any artifact is installed.
typeset -a dependency_download_options
dependency_download_options=()
if [[ "${YIOS_LOCATION_OFFLINE:-0}" == "1" ]]; then
  dependency_download_options=(--no-index --find-links "$artifact_cache")
fi
PIP_DISABLE_PIP_VERSION_CHECK=1 \
PIP_CACHE_DIR="${cache_dir}/pip" \
PYTHONNOUSERSITE=1 \
  "$python" -m pip download \
    --disable-pip-version-check \
    "${dependency_download_options[@]}" \
    --dest "$artifact_cache" \
    --requirement "${backend_source}/requirements-python39.lock"
"$python" - "$artifact_cache" "${backend_source}/dependency-artifacts.sha256" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
expected = {}
for line in manifest.read_text(encoding="utf-8").splitlines():
    digest, separator, name = line.partition("  ")
    if not separator or len(digest) != 64 or pathlib.PurePath(name).name != name:
        raise SystemExit("invalid dependency artifact manifest")
    expected[name] = digest
actual = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in root.iterdir() if path.is_file()}
if actual != expected:
    raise SystemExit("downloaded dependency artifacts do not exactly match the pinned manifest")
PY

work_root="$(/usr/bin/mktemp -d /private/tmp/yios-location-backend.XXXXXX)"
cleanup() {
  if [[ "${YIOS_KEEP_LOCATION_BUILD:-0}" == "1" ]]; then
    print -u2 -- "Preserving location backend work directory: ${work_root:-unknown}"
  elif [[ -n "${work_root:-}" && "$work_root" == /private/tmp/yios-location-backend.* ]]; then
    /bin/rm -rf "$work_root"
  fi
}
trap cleanup EXIT INT TERM

payload_root="${work_root}/payload"
helpers_dir="${payload_root}/Helpers/YIOSLocation"
resources_dir="${payload_root}/Resources/YIOSLocation"
packages_dir="${resources_dir}/python-packages"
notices_dir="${resources_dir}/ThirdPartyNotices"
source_dir="${resources_dir}/Source"
expanded_source="${work_root}/source"
/bin/mkdir -p "$helpers_dir" "$packages_dir" "$notices_dir" "$source_dir" "$expanded_source"

PIP_DISABLE_PIP_VERSION_CHECK=1 \
PIP_CACHE_DIR="${cache_dir}/pip" \
PYTHONNOUSERSITE=1 \
  "$python" -m pip install \
    --disable-pip-version-check \
    --no-compile \
    --no-index \
    --find-links "$artifact_cache" \
    --target "$packages_dir" \
    --requirement "${backend_source}/requirements-python39.lock" \
    "${cache_dir}/${pymobiledevice_wheel}"

# Bytecode is regenerated by Python if needed. Removing it keeps the payload
# deterministic and avoids embedding maintainer-side absolute paths.
/usr/bin/find "$packages_dir" -type d -name __pycache__ -prune -exec /bin/rm -rf {} +
/usr/bin/find "$packages_dir" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

/bin/cp "${backend_source}/yios-location-backend" "${helpers_dir}/yios-location-backend"
/bin/cp "${backend_source}/yios_location_backend.py" "${resources_dir}/yios_location_backend.py"
/bin/chmod 0755 "${helpers_dir}/yios-location-backend"
/bin/chmod 0644 "${resources_dir}/yios_location_backend.py"
/bin/cp "${backend_source}/PROTOCOL.md" "${resources_dir}/PROTOCOL.md"
/bin/cp "${backend_source}/test_yios_location_backend.py" \
  "${notices_dir}/test-yios-location-backend.py"
/bin/cp "${backend_source}/requirements-python39.lock" "${resources_dir}/requirements-python39.lock"
/bin/cp "${backend_source}/dependency-artifacts.sha256" "${resources_dir}/dependency-artifacts.sha256"
/bin/cp "${cache_dir}/${pymobiledevice_source}" "${source_dir}/${pymobiledevice_source}"
/usr/bin/tar -xzf "${cache_dir}/${pymobiledevice_source}" -C "$expanded_source"
[[ -f "${expanded_source}/pymobiledevice3-${pymobiledevice_version}/LICENSE" ]] || fail "upstream GPL license is missing"
/bin/cp "${expanded_source}/pymobiledevice3-${pymobiledevice_version}/LICENSE" \
  "${notices_dir}/pymobiledevice3-GPL-3.0-or-later.txt"
/bin/cp "${script_dir}/build-location-backend.sh" "${notices_dir}/build-location-backend.sh"
/bin/cp "${script_dir}/verify-location-backend.sh" "${notices_dir}/verify-location-backend.sh"
/bin/chmod 0755 "${notices_dir}/build-location-backend.sh" "${notices_dir}/verify-location-backend.sh"
/bin/chmod 0644 "${notices_dir}/test-yios-location-backend.py"

# Preserve every distribution's own metadata/license files in site-packages,
# and add a concise machine-readable inventory for review.
"$python" - "$packages_dir" "${resources_dir}/LocationBackendManifest.json" <<'PY'
import email
import json
import pathlib
import platform
import sys

root = pathlib.Path(sys.argv[1])
distributions = []
for metadata_path in sorted(root.glob("*.dist-info/METADATA")):
    message = email.message_from_bytes(metadata_path.read_bytes())
    license_value = message.get("License-Expression") or message.get("License") or "not-declared"
    license_summary = license_value.strip().splitlines()[0][:160] if license_value.strip() else "not-declared"
    distributions.append({
        "name": message.get("Name", "unknown"),
        "version": message.get("Version", "unknown"),
        "license": license_summary,
    })

manifest = {
    "backendVersion": "1.2.0",
    "protocolVersion": 1,
    "pythonRuntime": "/usr/bin/python3 3.9",
    "target": "arm64-apple-macos",
    "pymobiledevice3": {
        "version": "10.9.0",
        "license": "GPL-3.0-or-later",
        "wheelSHA256": "dc1ac7e3eb3d12622f9a354b66c1368f2b7145344dd1a145ef191ef47b00bb4b",
        "sourceSHA256": "20785dcd92b4d09277ede37573f0be765a8fa77df021208ee0787138b38526b4",
    },
    "resolvedDistributions": sorted(distributions, key=lambda item: item["name"].lower()),
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

# Sign every native extension/dylib from the inside out. They are re-signed by
# build-app.sh after being copied into the final bundle.
signing_identity="${YIOS_CODESIGN_IDENTITY:--}"
while IFS= read -r native_file; do
  /usr/bin/codesign --force --sign "$signing_identity" "$native_file"
done < <(
  /usr/bin/find "$packages_dir" -type f -print | while IFS= read -r candidate; do
    /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O' && print -- "$candidate"
  done | /usr/bin/awk '{ print length($0), $0 }' | LC_ALL=C /usr/bin/sort -rn | /usr/bin/cut -d' ' -f2-
)
/usr/bin/codesign --force --sign "$signing_identity" "${helpers_dir}/yios-location-backend"

"${script_dir}/verify-location-backend.sh" --write-checksums "$payload_root"

"${script_dir}/verify-location-backend.sh" "$payload_root"

[[ "$vendor_target" == "${project_dir}/Vendor/LocationBackend/arm64" ]] || fail "unsafe vendor target"
/bin/mkdir -p "${vendor_target:h}"
if [[ -e "$vendor_target" ]]; then
  /bin/rm -rf "$vendor_target"
fi
/bin/mv "$payload_root" "$vendor_target"

print -- "Location backend ready: ${vendor_target}"
