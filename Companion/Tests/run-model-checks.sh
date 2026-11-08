#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h:h}"
test_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/yios-companion-models.XXXXXX")"
cleanup() { /bin/rm -rf "$test_dir"; }
trap cleanup EXIT INT TERM
/usr/bin/xcrun swiftc -target arm64-apple-macosx13.0 -swift-version 5 -parse-as-library \
  -framework Foundation -framework MapKit -framework CoreLocation -framework Combine \
  "${project_dir}/Companion/YIOSKitCompanion/CompanionModel.swift" \
  "${project_dir}/Companion/Tests/ModelChecks.swift" -o "${test_dir}/ModelChecks"
"${test_dir}/ModelChecks"
