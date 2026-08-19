#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
developer_dir="/Applications/Xcode.app/Contents/Developer"
[[ -d "$developer_dir" ]] || {
  print -u2 "Xcode is required at ${developer_dir}"
  exit 1
}

test_root="$(/usr/bin/mktemp -d /private/tmp/yios-tests.XXXXXX)"
cleanup() {
  if [[ -n "${test_root:-}" && "$test_root" == /private/tmp/yios-tests.* ]]; then
    /bin/rm -rf "$test_root"
  fi
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "${test_root}/module-cache"
source_files=("${project_dir}"/Sources/*.swift)
source_files=("${source_files[@]:#${project_dir}/Sources/SE2RecoveryAssistantApp.swift}")

common_arguments=(
  -target arm64-apple-macosx13.0
  -swift-version 5
  -module-cache-path "${test_root}/module-cache"
  -parse-as-library
  -framework SwiftUI
  -framework AppKit
  -framework Combine
  -framework CryptoKit
  -framework UniformTypeIdentifiers
)

typeset -a test_mains
test_mains=(
  SelfTestMain
  DeviceCenterTestMain
  SupportFeaturesTestMain
  ModelSafetyTestMain
  UIContractTestMain
  ToolchainTestMain
)

for test_name in "${test_mains[@]}"; do
  print -- "Running ${test_name}"
  DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun swiftc \
    "${common_arguments[@]}" \
    "${source_files[@]}" \
    "${project_dir}/Tests/${test_name}.swift" \
    -o "${test_root}/${test_name}"
  "${test_root}/${test_name}"
done

if [[ "${YIOS_RUN_VISUALS:-0}" == "1" ]]; then
  print -- "Running VisualTestMain"
  DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun swiftc \
    "${common_arguments[@]}" \
    "${source_files[@]}" \
    "${project_dir}/Tests/VisualTestMain.swift" \
    -o "${test_root}/VisualTestMain"
  "${test_root}/VisualTestMain" normal 1120 820 light "${test_root}/normal.png"
  "${test_root}/VisualTestMain" restoreos 1120 820 dark "${test_root}/restoreos.png"
fi

print -- "ALL OFFLINE TESTS PASS"
