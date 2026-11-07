#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_path="${1:-${project_dir}/build/YIOS-KIT.app}"
developer_dir="/Applications/Xcode.app/Contents/Developer"

[[ -d "$app_path" ]] || {
  print -u2 -- "App integration verification failed: app not found at ${app_path}"
  exit 1
}

test_root="$(/usr/bin/mktemp -d /private/tmp/yios-app-integration.XXXXXX)"
cleanup() {
  if [[ -n "${test_root:-}" && "$test_root" == /private/tmp/yios-app-integration.* ]]; then
    /bin/rm -rf "$test_root"
  fi
}
trap cleanup EXIT INT TERM
/bin/mkdir -p "${test_root}/module-cache"

DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun swiftc \
  -target arm64-apple-macosx13.0 \
  -swift-version 5 \
  -module-cache-path "${test_root}/module-cache" \
  -parse-as-library \
  "${project_dir}/Sources/Toolchain.swift" \
  "${project_dir}/Tests/BundleIntegrationTestMain.swift" \
  -o "${test_root}/BundleIntegrationTest"

"${test_root}/BundleIntegrationTest" "$app_path"
