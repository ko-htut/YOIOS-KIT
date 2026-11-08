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
test_support_files=("${project_dir}/Tests/DashboardTestSupport.swift")

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
  SupportedDeviceCatalogTestMain
  DeviceCenterTestMain
  SupportFeaturesTestMain
  ModelSafetyTestMain
  GenericDFURestoreTestMain
  UIContractTestMain
  ToolchainTestMain
  MockLocationTestMain
  RecoveryTransitionTestMain
  DFUAssistantTestMain
  CompanionTestMain
)

if [[ -n "${YIOS_TEST_FILTER:-}" ]]; then
  requested_tests=("${(@s:,:)YIOS_TEST_FILTER}")
  for test_name in "${requested_tests[@]}"; do
    if (( ${test_mains[(Ie)$test_name]} == 0 )); then
      print -u2 -- "Unknown test name: ${test_name}"
      exit 64
    fi
  done
  test_mains=("${requested_tests[@]}")
fi

for test_name in "${test_mains[@]}"; do
  print -- "Running ${test_name}"
  DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun swiftc \
    "${common_arguments[@]}" \
    "${source_files[@]}" \
    "${test_support_files[@]}" \
    "${project_dir}/Tests/${test_name}.swift" \
    -o "${test_root}/${test_name}"
  "${test_root}/${test_name}"
done

if [[ "${YIOS_RUN_VISUALS:-0}" == "1" ]]; then
  print -- "Running VisualTestMain"
  if [[ -n "${YIOS_VISUAL_OUTPUT_DIR:-}" ]]; then
    visual_output_dir="${YIOS_VISUAL_OUTPUT_DIR:A}"
    /bin/mkdir -p "$visual_output_dir"
  else
    visual_output_dir="$(/usr/bin/mktemp -d /private/tmp/yios-visuals.XXXXXX)"
  fi
  DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun swiftc \
    "${common_arguments[@]}" \
    "${source_files[@]}" \
    "${test_support_files[@]}" \
    "${project_dir}/Tests/VisualTestMain.swift" \
    -o "${test_root}/VisualTestMain"
  "${test_root}/VisualTestMain" "${visual_output_dir}/normal-overview-reference-light.png" normal 1562 1007 light top overview
  "${test_root}/VisualTestMain" "${visual_output_dir}/normal-overview-wide-dark.png" normal 1420 880 dark top overview
  "${test_root}/VisualTestMain" "${visual_output_dir}/normal-overview-compact-dark.png" normal 1040 820 dark top overview
  "${test_root}/VisualTestMain" "${visual_output_dir}/devices-wide-light.png" devices 1420 880 light top overview
  "${test_root}/VisualTestMain" "${visual_output_dir}/no-device-overview-light.png" no-device 1420 880 light top overview
  "${test_root}/VisualTestMain" "${visual_output_dir}/no-device-compact-light.png" no-device 1040 700 light top overview
  "${test_root}/VisualTestMain" "${visual_output_dir}/restoreos-guide-light.png" restoreos-dfu-expanded 1420 880 light top recovery
  "${test_root}/VisualTestMain" "${visual_output_dir}/recovery-workspace-light.png" recovery 1420 880 light top recovery
  "${test_root}/VisualTestMain" "${visual_output_dir}/dfu-workspace-dark.png" dfu 1420 880 dark top recovery
  "${test_root}/VisualTestMain" "${visual_output_dir}/generic-dfu-factory-restore-light.png" generic-dfu 1420 880 light top recovery
  "${test_root}/VisualTestMain" "${visual_output_dir}/kis-dfu-factory-restore-dark.png" kis-dfu 1420 880 dark top recovery
  "${test_root}/VisualTestMain" "${visual_output_dir}/post-reset-review-light.png" post-reset-review 1420 880 light top recovery
  "${test_root}/VisualTestMain" "${visual_output_dir}/operation-running-recovery-light.png" operation-running 1420 880 light top recovery
  "${test_root}/VisualTestMain" "${visual_output_dir}/operation-failed-activity-light.png" operation-failed 1420 880 light top activity
  "${test_root}/VisualTestMain" "${visual_output_dir}/crash-review-activity-dark.png" crash-review 1420 880 dark top activity
  "${test_root}/VisualTestMain" "${visual_output_dir}/settings-light.png" settings 1420 880 light top overview
  "${test_root}/VisualTestMain" "${visual_output_dir}/mock-location-idle-light.png" mock-location-idle 1420 880 light top activity
  "${test_root}/VisualTestMain" "${visual_output_dir}/mock-location-idle-compact-light.png" mock-location-idle 1040 700 light top activity
  "${test_root}/VisualTestMain" "${visual_output_dir}/mock-location-review-dark.png" mock-location-review 1420 880 dark top activity
  "${test_root}/VisualTestMain" "${visual_output_dir}/mock-location-persistent-dark.png" mock-location-persistent 1420 880 dark top activity
  "${test_root}/VisualTestMain" "${visual_output_dir}/multiple-device-recovery-light.png" multiple 1040 700 light top recovery
  "${test_root}/VisualTestMain" "${visual_output_dir}/usb-unavailable-recovery-dark.png" usb-unavailable 1040 700 dark top recovery
  "${test_root}/VisualTestMain" "${visual_output_dir}/normal-log-expanded-light.png" normal-log-expanded 1420 1300 light full recovery

  # Every sidebar destination receives an explicit wide/light and compact/dark
  # screenshot. State-specific captures above remain separate from navigation
  # coverage so a route cannot silently reuse another destination's content.
  for page_scenario in dashboard devices reports history recovery dfu-restore mock-location-idle more-tools guides logs settings; do
    "${test_root}/VisualTestMain" "${visual_output_dir}/screen-${page_scenario}-wide-light.png" "$page_scenario" 1420 880 light top
    "${test_root}/VisualTestMain" "${visual_output_dir}/screen-${page_scenario}-compact-dark.png" "$page_scenario" 1040 820 dark top
  done
  "${test_root}/VisualTestMain" "${visual_output_dir}/guides-monitoring-compact-light.png" guides-monitoring 1040 820 light top
  "${test_root}/VisualTestMain" "${visual_output_dir}/dfu-restore-monitoring-wide-dark.png" dfu-restore-monitoring 1420 880 dark top
  print -- "Visual snapshots: ${visual_output_dir}"
fi

print -- "ALL OFFLINE TESTS PASS"
