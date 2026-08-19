#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
output_dir="${project_dir}/outputs"
cache_dir="${YIOS_TOOLCHAIN_CACHE:-${project_dir}/.build-cache/toolchain-downloads}"
app_name="SE2 Recovery Assistant.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${project_dir}/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${project_dir}/Info.plist")"
release_stem="SE2-Recovery-Assistant-${version}-arm64"

fail() {
  print -u2 -- "Release packaging failed: $*"
  exit 1
}

[[ "$output_dir" == "${project_dir}/outputs" ]] || fail "unsafe output directory"
[[ "$version" != *'/'* && "$build_number" == <-> ]] || fail "invalid app version metadata"

typeset -a source_records
source_records=(
  'libplist-2.7.0.tar.bz2|7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b'
  'libimobiledevice-glue-1.3.2.tar.bz2|6489a3411b874ecd81c87815d863603f518b264a976319725e0ed59935546774'
  'libusbmuxd-2.1.1.tar.bz2|5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce'
  'libtatsu-1.0.5.tar.bz2|536fa228b14f156258e801a7f4d25a3a9dd91bb936bf6344e23171403c57e440'
  'libimobiledevice-1.4.0.tar.bz2|23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d'
  'libirecovery-1.3.1.tar.bz2|28a3a521782063c8eb2ee5f4c0f38a517e023853edb55856052cdd7ac400381b'
  'openssl-3.5.7.tar.gz|a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8'
)

for record in "${source_records[@]}"; do
  IFS='|' read -r archive expected_sha <<< "$record"
  [[ -f "${cache_dir}/${archive}" ]] || fail "missing verified source archive ${archive}; run build-bundled-tools.sh first"
  actual_sha="$(/usr/bin/shasum -a 256 "${cache_dir}/${archive}" | /usr/bin/awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || fail "source archive checksum mismatch: ${archive}"
done

"${script_dir}/run-tests.sh"
"${project_dir}/build-app.sh"

built_app="${project_dir}/build/${app_name}"
[[ -d "$built_app" ]] || fail "the app build was not produced"

stage_root="$(/usr/bin/mktemp -d /private/tmp/yios-release.XXXXXX)"
cleanup() {
  if [[ -n "${stage_root:-}" && "$stage_root" == /private/tmp/yios-release.* ]]; then
    /bin/rm -rf "$stage_root"
  fi
}
trap cleanup EXIT INT TERM

stage_output="${stage_root}/output"
source_tree="${stage_root}/SE2-Recovery-Assistant-Source-${version}"
third_party_tree="${stage_root}/SE2-Recovery-Assistant-Third-Party-Source-${version}"
/bin/mkdir -p "$stage_output" "$source_tree" "$third_party_tree/Archives"

/usr/bin/ditto "$built_app" "${stage_root}/${app_name}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "${stage_root}/${app_name}" \
  "${stage_output}/${release_stem}.zip"
/bin/cp "${project_dir}/README.md" "${stage_output}/Read Me.md"

for item in .gitignore Info.plist README.md build-app.sh Scripts Sources Tests; do
  /usr/bin/ditto "${project_dir}/${item}" "${source_tree}/${item}"
done
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "$source_tree" \
  "${stage_output}/SE2-Recovery-Assistant-${version}-Source.zip"

for record in "${source_records[@]}"; do
  IFS='|' read -r archive _ <<< "$record"
  /bin/cp "${cache_dir}/${archive}" "${third_party_tree}/Archives/${archive}"
done
/bin/cp "${script_dir}/ThirdPartyNotices.md" "${third_party_tree}/ThirdPartyNotices.md"
/bin/cp "${script_dir}/build-bundled-tools.sh" "${third_party_tree}/build-bundled-tools.sh"
/bin/cp "${script_dir}/verify-bundled-tools.sh" "${third_party_tree}/verify-bundled-tools.sh"
/bin/chmod 0755 "${third_party_tree}/build-bundled-tools.sh" "${third_party_tree}/verify-bundled-tools.sh"
/bin/cp "${script_dir}/ToolchainManifest.plist" "${third_party_tree}/ToolchainManifest.plist"
(
  cd "$third_party_tree"
  /usr/bin/find Archives -type f -print | LC_ALL=C /usr/bin/sort | while IFS= read -r archive; do
    /usr/bin/shasum -a 256 "$archive"
  done > SourceArchives.sha256
)
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "$third_party_tree" \
  "${stage_output}/SE2-Recovery-Assistant-${version}-Third-Party-Source.zip"

for archive in "${stage_output}"/*.zip; do
  /usr/bin/unzip -tq "$archive" >/dev/null || fail "archive integrity check failed: ${archive:t}"
done

extracted_app_root="${stage_root}/app-check"
/bin/mkdir -p "$extracted_app_root"
/usr/bin/ditto -x -k "${stage_output}/${release_stem}.zip" "$extracted_app_root"
extracted_app="${extracted_app_root}/${app_name}"
/usr/bin/codesign --verify --deep --strict --all-architectures "$extracted_app"
"${script_dir}/verify-bundled-tools.sh" "${extracted_app}/Contents"
"${script_dir}/verify-app-integration.sh" "$extracted_app"

third_party_check="${stage_root}/third-party-check"
/bin/mkdir -p "$third_party_check"
/usr/bin/ditto -x -k \
  "${stage_output}/SE2-Recovery-Assistant-${version}-Third-Party-Source.zip" \
  "$third_party_check"
third_party_extracted="${third_party_check}/SE2-Recovery-Assistant-Third-Party-Source-${version}"
(
  cd "$third_party_extracted"
  /usr/bin/shasum -a 256 -c SourceArchives.sha256 >/dev/null
)

(
  cd "$stage_output"
  : > RELEASE-SHA256SUMS.txt
  for artifact in *.zip 'Read Me.md'; do
    /usr/bin/shasum -a 256 "$artifact" >> RELEASE-SHA256SUMS.txt
  done
  print -- "Version ${version} (build ${build_number}), arm64, macOS 13+" > RELEASE-METADATA.txt
  if [[ "${YIOS_CODESIGN_IDENTITY:--}" == "-" ]]; then
    print -- "Signing: ad-hoc local build; not notarized" >> RELEASE-METADATA.txt
  else
    print -- "Signing identity: ${YIOS_CODESIGN_IDENTITY}" >> RELEASE-METADATA.txt
    print -- "Notarization is a separate release-owner step." >> RELEASE-METADATA.txt
  fi
)

/bin/mkdir -p "$output_dir"
for artifact in "${stage_output}"/*; do
  /bin/mv -f "$artifact" "${output_dir}/${artifact:t}"
done

print -- "Release artifacts ready: ${output_dir}"
