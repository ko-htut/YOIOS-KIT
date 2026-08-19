#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
destination="${1:-${project_dir}/build/SE2 Recovery Assistant.app}"
developer_dir="/Applications/Xcode.app/Contents/Developer"
module_cache="${project_dir}/build/module-cache"
toolchain="${project_dir}/Vendor/Toolchain/arm64"
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

# Sign nested code from the inside out. The outer app is signed once, without
# using --deep as a signing shortcut.
for dylib in "${staged_app}/Contents/Frameworks/YIOSTools"/*.dylib; do
  /usr/bin/codesign --force --sign "${signing_identity}" "$dylib"
done
for helper in "${staged_app}/Contents/Helpers/YIOSTools"/*; do
  /usr/bin/codesign --force --sign "${signing_identity}" "$helper"
done
/usr/bin/codesign --force --sign "${signing_identity}" "${staged_app}/Contents/MacOS/SE2RecoveryAssistant"

(
  cd "${staged_app}/Contents"
  : > "Resources/ToolchainPayload.sha256"
  while IFS= read -r relative; do
    /usr/bin/shasum -a 256 "$relative" >> "Resources/ToolchainPayload.sha256"
  done < <(/usr/bin/find Helpers Frameworks -type f -print | LC_ALL=C /usr/bin/sort)
)

"${project_dir}/Scripts/verify-bundled-tools.sh" "${staged_app}/Contents"
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

print "Built: ${destination}"
