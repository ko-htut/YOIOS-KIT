#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
destination="${1:-${project_dir}/build/SE2 Recovery Assistant.app}"
developer_dir="/Applications/Xcode.app/Contents/Developer"
module_cache="${project_dir}/build/module-cache"

if [[ ! -d "${developer_dir}" ]]; then
  print -u2 "Xcode is required at /Applications/Xcode.app"
  exit 1
fi

/bin/mkdir -p "${destination}/Contents/MacOS" "${destination}/Contents/Resources" "${module_cache}"

DEVELOPER_DIR="${developer_dir}" /usr/bin/xcrun swiftc \
  -target arm64-apple-macosx13.0 \
  -swift-version 5 \
  -module-cache-path "${module_cache}" \
  -parse-as-library \
  "${project_dir}"/Sources/*.swift \
  -o "${destination}/Contents/MacOS/SE2RecoveryAssistant" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -framework CryptoKit \
  -framework UniformTypeIdentifiers

/bin/cp "${project_dir}/Info.plist" "${destination}/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "${destination}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${destination}"

print "Built: ${destination}"
