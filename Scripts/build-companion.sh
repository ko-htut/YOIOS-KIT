#!/bin/zsh
set -euo pipefail
umask 077

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
mode="Simulator"
development_team="${YIOS_COMPANION_TEAM:-}"
allow_provisioning_updates=0
while (( $# > 0 )); do
  case "$1" in
    --simulator) mode="Simulator"; shift ;;
    --device) mode="Device"; shift ;;
    --team)
      (( $# >= 2 )) || { print -u2 -- "--team requires a development team identifier."; exit 64; }
      development_team="$2"; shift 2 ;;
    --allow-provisioning-updates) allow_provisioning_updates=1; shift ;;
    --help|-h)
      print -- "Usage: Scripts/build-companion.sh [--simulator | --device --team TEAM] [--allow-provisioning-updates]"
      print -- "Simulator builds never sign or contact a physical device."
      print -- "Device builds need an explicitly selected team; YIOS_COMPANION_TEAM is also supported."
      print -- "Provisioning changes are disabled unless --allow-provisioning-updates is supplied."
      exit 0 ;;
    *) print -u2 -- "Unknown option: $1"; exit 64 ;;
  esac
done

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -x "${developer_dir}/usr/bin/xcodebuild" ]] || {
  print -u2 -- "Xcode is required to build the iPhone companion."
  exit 1
}
if [[ "$mode" == "Device" ]]; then
  [[ "$development_team" =~ '^[A-Z0-9]{10}$' ]] || {
    print -u2 -- "Select your own signing team with --team TEAM or YIOS_COMPANION_TEAM. No credentials are collected by this script."
    exit 64
  }
elif (( allow_provisioning_updates )); then
  print -u2 -- "--allow-provisioning-updates applies only to a signed --device build."
  exit 64
fi

output_root="${project_dir}/build/Companion"
derived_data="${output_root}/DerivedData-${mode}"
output_dir="${output_root}/${mode}"
log_path="${output_root}/build-${mode:l}.log"
/bin/mkdir -p "$output_dir"
typeset -a build_arguments
build_arguments=(
  -project "${project_dir}/Companion/YIOSKitCompanion.xcodeproj"
  -scheme YIOSKitCompanion
  -configuration Release
  -derivedDataPath "$derived_data"
  -quiet
)
if [[ "$mode" == "Simulator" ]]; then
  build_arguments+=( -sdk iphonesimulator -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO )
  product_path="${derived_data}/Build/Products/Release-iphonesimulator/YIOS-KIT Companion.app"
else
  build_arguments+=( -sdk iphoneos -destination "generic/platform=iOS" "DEVELOPMENT_TEAM=${development_team}" )
  if (( allow_provisioning_updates )); then
    build_arguments+=( -allowProvisioningUpdates )
  fi
  product_path="${derived_data}/Build/Products/Release-iphoneos/YIOS-KIT Companion.app"
fi
if ! DEVELOPER_DIR="$developer_dir" /usr/bin/xcodebuild "${build_arguments[@]}" build > "$log_path" 2>&1; then
  print -u2 -- "Companion build failed. Review the local build log: ${log_path}"
  print -u2 -- "Signing logs can contain account or device identifiers; keep them private."
  exit 1
fi

[[ -d "$product_path" ]] || { print -u2 -- "Xcode did not produce the expected companion app."; exit 1; }
destination="${output_dir}/YIOS-KIT Companion.app"
staging_dir="$(/usr/bin/mktemp -d "${output_root}/companion-stage.XXXXXX")"
cleanup() {
  [[ "${staging_dir:-}" == "${output_root}/companion-stage."* ]] && /bin/rm -rf "$staging_dir"
}
trap cleanup EXIT INT TERM
/usr/bin/ditto "$product_path" "${staging_dir}/YIOS-KIT Companion.app"
if [[ "$mode" == "Device" ]]; then
  "${script_dir}/verify-companion.sh" "${staging_dir}/YIOS-KIT Companion.app"
fi
[[ ! -e "$destination" ]] || /bin/rm -rf "$destination"
/bin/mv "${staging_dir}/YIOS-KIT Companion.app" "$destination"
print -- "Built ${mode} companion: ${destination}"
