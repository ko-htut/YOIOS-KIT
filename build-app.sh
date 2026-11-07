#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
default_destination="${project_dir}/build/YIOS-KIT.app"
legacy_destination="${project_dir}/build/SE2 Recovery Assistant.app"
destination="${1:-${default_destination}}"
developer_dir="/Applications/Xcode.app/Contents/Developer"
module_cache="${project_dir}/build/module-cache"
toolchain="${project_dir}/Vendor/Toolchain/arm64"
location_backend="${project_dir}/Vendor/LocationBackend/arm64"
signing_identity="${YIOS_CODESIGN_IDENTITY:--}"

if [[ ! -d "${developer_dir}" ]]; then
  print -u2 "Xcode is required at /Applications/Xcode.app"
  exit 1
fi

if [[ ! -d "${toolchain}/Helpers/YIOSTools" || ! -d "${toolchain}/Frameworks/YIOSTools" ]]; then
  print -u2 "The built-in mobile-device toolchain is missing."
  print -u2 "Run Scripts/build-bundled-tools.sh before building the app."
  exit 1
fi

if [[ ! -x "${location_backend}/Helpers/YIOSLocation/yios-location-backend" || \
      ! -d "${location_backend}/Resources/YIOSLocation/python-packages" ]]; then
  print -u2 "The built-in Mock Location backend is missing."
  print -u2 "Run Scripts/build-location-backend.sh before building the app."
  exit 1
fi

typeset -a location_source_pairs
location_source_pairs=(
  "${project_dir}/Backend/MockLocation/yios-location-backend|${location_backend}/Helpers/YIOSLocation/yios-location-backend"
  "${project_dir}/Backend/MockLocation/yios_location_backend.py|${location_backend}/Resources/YIOSLocation/yios_location_backend.py"
  "${project_dir}/Backend/MockLocation/PROTOCOL.md|${location_backend}/Resources/YIOSLocation/PROTOCOL.md"
  "${project_dir}/Backend/MockLocation/test_yios_location_backend.py|${location_backend}/Resources/YIOSLocation/ThirdPartyNotices/test-yios-location-backend.py"
  "${project_dir}/Backend/MockLocation/requirements-python39.lock|${location_backend}/Resources/YIOSLocation/requirements-python39.lock"
  "${project_dir}/Backend/MockLocation/dependency-artifacts.sha256|${location_backend}/Resources/YIOSLocation/dependency-artifacts.sha256"
  "${project_dir}/Backend/MockLocation/pymobiledevice3-wifi.patch|${location_backend}/Resources/YIOSLocation/Source/pymobiledevice3-wifi.patch"
  "${project_dir}/Backend/MockLocation/PYMOBILEDEVICE3-PATCH.md|${location_backend}/Resources/YIOSLocation/ThirdPartyNotices/PYMOBILEDEVICE3-PATCH.md"
  "${project_dir}/Scripts/build-location-backend.sh|${location_backend}/Resources/YIOSLocation/ThirdPartyNotices/build-location-backend.sh"
  "${project_dir}/Scripts/verify-location-backend.sh|${location_backend}/Resources/YIOSLocation/ThirdPartyNotices/verify-location-backend.sh"
)
for pair in "${location_source_pairs[@]}"; do
  IFS='|' read -r source_file payload_file <<< "$pair"
  if [[ ! -f "$source_file" || ! -f "$payload_file" ]] || ! /usr/bin/cmp -s "$source_file" "$payload_file"; then
    print -u2 "The built-in Mock Location backend is stale relative to reviewed source."
    print -u2 "Run Scripts/build-location-backend.sh before building the app."
    exit 1
  fi
done

/bin/mkdir -p "${project_dir}/build" "${module_cache}"
staging_root="$(/usr/bin/mktemp -d "${project_dir}/build/app-stage.XXXXXX")"
staged_app="${staging_root}/${destination:t}"
cleanup() {
  if [[ -n "${staging_root:-}" && "${staging_root}" == "${project_dir}/build/app-stage."* ]]; then
    /bin/rm -rf "${staging_root}"
  fi
}
trap cleanup EXIT INT TERM

/bin/mkdir -p \
  "${staged_app}/Contents/MacOS" \
  "${staged_app}/Contents/Helpers" \
  "${staged_app}/Contents/Frameworks" \
  "${staged_app}/Contents/Resources"

DEVELOPER_DIR="${developer_dir}" /usr/bin/xcrun swiftc \
  -target arm64-apple-macosx13.0 \
  -swift-version 5 \
  -module-cache-path "${module_cache}" \
  -parse-as-library \
  "${project_dir}"/Sources/*.swift \
  -o "${staged_app}/Contents/MacOS/SE2RecoveryAssistant" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -framework CryptoKit \
  -framework UniformTypeIdentifiers

/bin/cp "${project_dir}/Info.plist" "${staged_app}/Contents/Info.plist"
/usr/bin/ditto "${toolchain}/Helpers/YIOSTools" "${staged_app}/Contents/Helpers/YIOSTools"
/usr/bin/ditto "${toolchain}/Frameworks/YIOSTools" "${staged_app}/Contents/Frameworks/YIOSTools"
/bin/cp "${toolchain}/Resources/ToolchainManifest.plist" "${staged_app}/Contents/Resources/ToolchainManifest.plist"
/usr/bin/ditto "${toolchain}/Resources/ThirdPartyNotices" "${staged_app}/Contents/Resources/ThirdPartyNotices"
/bin/cp "${project_dir}/Scripts/ThirdPartyNotices.md" \
  "${staged_app}/Contents/Resources/ThirdPartyNotices/README.md"
/usr/bin/ditto "${location_backend}/Helpers/YIOSLocation" "${staged_app}/Contents/Helpers/YIOSLocation"
/usr/bin/ditto "${location_backend}/Resources/YIOSLocation" "${staged_app}/Contents/Resources/YIOSLocation"
/bin/cp "${location_backend}/Resources/LocationBackendPayload.sha256" \
  "${staged_app}/Contents/Resources/LocationBackendPayload.sha256"

# Sign nested code from the inside out. The outer app is signed once, without
# using --deep as a signing shortcut.
for dylib in "${staged_app}/Contents/Frameworks/YIOSTools"/*.dylib; do
  /usr/bin/codesign --force --sign "${signing_identity}" "$dylib"
done
for helper in "${staged_app}/Contents/Helpers/YIOSTools"/*; do
  /usr/bin/codesign --force --sign "${signing_identity}" "$helper"
done
/usr/bin/codesign --force --sign "${signing_identity}" \
  "${staged_app}/Contents/Helpers/YIOSLocation/yios-location-backend"

# Python extension modules and their private dylibs are nested code. Sign all
# Mach-O files before sealing and signing the outer application.
while IFS= read -r native_file; do
  if /usr/bin/file -b "$native_file" | /usr/bin/grep -q 'Mach-O'; then
    /usr/bin/codesign --force --sign "${signing_identity}" "$native_file"
  fi
done < <(
  /usr/bin/find "${staged_app}/Contents/Resources/YIOSLocation/python-packages" -type f -print \
    | /usr/bin/awk '{ print length($0), $0 }' \
    | LC_ALL=C /usr/bin/sort -rn \
    | /usr/bin/cut -d' ' -f2-
)
/usr/bin/codesign --force --sign "${signing_identity}" "${staged_app}/Contents/MacOS/SE2RecoveryAssistant"

"${project_dir}/Scripts/verify-location-backend.sh" --write-checksums "${staged_app}/Contents"

(
  cd "${staged_app}/Contents"
  : > "Resources/ToolchainPayload.sha256"
  while IFS= read -r relative; do
    /usr/bin/shasum -a 256 "$relative" >> "Resources/ToolchainPayload.sha256"
  done < <(/usr/bin/find Helpers Frameworks -type f -print | LC_ALL=C /usr/bin/sort)
)

"${project_dir}/Scripts/verify-bundled-tools.sh" "${staged_app}/Contents"
"${project_dir}/Scripts/verify-location-backend.sh" "${staged_app}/Contents"
/usr/bin/codesign --force --sign "${signing_identity}" "${staged_app}"
/usr/bin/codesign --verify --deep --strict --all-architectures --verbose=2 "${staged_app}"
"${project_dir}/Scripts/verify-app-integration.sh" "${staged_app}"

if [[ -e "${destination}" ]]; then
  [[ "${destination}" == "${project_dir}/build/"*.app ]] || {
    print -u2 "Refusing to replace an app outside the project build directory: ${destination}"
    exit 1
  }
  /bin/rm -rf "${destination}"
fi
/bin/mv "${staged_app}" "${destination}"

# The product was originally emitted under the SE2-only filename. Once the
# default YIOS-KIT build succeeds, remove that ignored legacy build artifact so
# Spotlight and Finder do not surface two copies of the same bundle.
if [[ "${destination}" == "${default_destination}" && -e "${legacy_destination}" ]]; then
  /bin/rm -rf "${legacy_destination}"
fi

print "Built: ${destination}"
