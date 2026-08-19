#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
payload_root="${1:-${project_dir}/Vendor/Toolchain/arm64}"
helpers_dir="${payload_root}/Helpers/YIOSTools"
frameworks_dir="${payload_root}/Frameworks/YIOSTools"
resources_dir="${payload_root}/Resources"

typeset -a expected_helpers
expected_helpers=(
  idevice_id ideviceinfo idevicepair ideviceenterrecovery
  idevicediagnostics idevicecrashreport irecovery
)

fail() {
  print -u2 -- "Bundled tool verification failed: $*"
  exit 1
}

[[ -d "$helpers_dir" && -d "$frameworks_dir" ]] || fail "payload directories are missing"
[[ -f "${resources_dir}/ToolchainManifest.plist" ]] || fail "manifest is missing"
[[ -f "${resources_dir}/ToolchainPayload.sha256" ]] || fail "payload checksum list is missing"

actual_helpers=("${(@f)$(/usr/bin/find "$helpers_dir" -maxdepth 1 -type f -print | /usr/bin/sed 's#.*/##' | LC_ALL=C /usr/bin/sort)}")
sorted_expected=("${(@f)$(print -l -- "${expected_helpers[@]}" | LC_ALL=C /usr/bin/sort)}")
[[ "${(j:|:)actual_helpers}" == "${(j:|:)sorted_expected}" ]] || fail "helper set is incomplete or unexpected"

all_code=("${helpers_dir}"/* "${frameworks_dir}"/*.dylib)
for file in "${all_code[@]}"; do
  [[ -f "$file" && ! -L "$file" ]] || fail "code item is missing or is a symlink: $file"
  architectures="$(/usr/bin/lipo -archs "$file")"
  [[ "$architectures" == "arm64" ]] || fail "wrong architecture for ${file:t}: ${architectures}"
  minos="$(/usr/bin/otool -l "$file" | /usr/bin/awk '$1=="cmd" && $2=="LC_BUILD_VERSION" {seen=1; next} seen && $1=="minos" {print $2; exit}')"
  [[ -n "$minos" ]] || fail "missing LC_BUILD_VERSION for ${file:t}"
  /usr/bin/awk -v value="$minos" 'BEGIN { if ((value + 0) > 13.0) exit 1 }' || fail "${file:t} requires macOS ${minos}"
  /usr/bin/codesign --verify --strict --all-architectures "$file" || fail "invalid signature on ${file:t}"
  # Skip otool's first line: it is the inspected file path, not a load path.
  if /usr/bin/otool -L "$file" | /usr/bin/tail -n +2 | /usr/bin/grep -E '/opt/homebrew|/usr/local|/private/tmp|/YIOS/' >/dev/null; then
    fail "non-relocatable dependency remains in ${file:t}"
  fi
done

for helper in "${helpers_dir}"/*; do
  rpaths=("${(@f)$(/usr/bin/otool -l "$helper" | /usr/bin/awk '$1=="cmd" && $2=="LC_RPATH" {want=1; next} want && $1=="path" {print $2; want=0}')}" )
  [[ ${#rpaths[@]} -eq 1 && "${rpaths[1]}" == '@executable_path/../../Frameworks/YIOSTools' ]] || fail "wrong rpath in ${helper:t}"
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/*)
        [[ -f "${frameworks_dir}/${dependency:t}" ]] || fail "unresolved helper dependency ${dependency}"
        ;;
      *) fail "unexpected helper dependency ${dependency}" ;;
    esac
  done < <(/usr/bin/otool -L "$helper" | /usr/bin/tail -n +2 | /usr/bin/sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
done

for dylib in "${frameworks_dir}"/*.dylib; do
  identifier="$(/usr/bin/otool -D "$dylib" | /usr/bin/tail -n 1)"
  [[ "$identifier" == "@rpath/${dylib:t}" ]] || fail "wrong dylib identifier for ${dylib:t}"
  if /usr/bin/otool -l "$dylib" | /usr/bin/grep -q 'LC_RPATH'; then
    fail "dylib contains an unexpected LC_RPATH: ${dylib:t}"
  fi
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      @loader_path/*)
        [[ -f "${frameworks_dir}/${dependency:t}" ]] || fail "unresolved dylib dependency ${dependency}"
        ;;
      *) fail "unexpected dylib dependency ${dependency}" ;;
    esac
  # A dylib's first otool entry is its own LC_ID_DYLIB, already verified above.
  done < <(/usr/bin/otool -L "$dylib" | /usr/bin/tail -n +3 | /usr/bin/sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
done

(
  cd "$payload_root"
  /usr/bin/shasum -a 256 -c "Resources/ToolchainPayload.sha256" >/dev/null
)

for helper in "${expected_helpers[@]}"; do
  output="$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C "${helpers_dir}/${helper}" --version 2>&1)" || fail "${helper} --version failed"
  if [[ "$helper" == irecovery ]]; then
    [[ "$output" == *'irecovery 1.3.1'* ]] || fail "unexpected irecovery version: ${output}"
  else
    [[ "$output" == *'1.4.0'* ]] || fail "unexpected ${helper} version: ${output}"
  fi
done

print -- "BUNDLED TOOLCHAIN VERIFY PASS"
