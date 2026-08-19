#!/bin/zsh
set -euo pipefail

# Build the mobile-device helper suite from pinned upstream release archives.
# The produced payload is arm64-only and targets macOS 13. It is independent
# of Homebrew at runtime; pkg-config is only a maintainer-side build tool.

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
cache_dir="${YIOS_TOOLCHAIN_CACHE:-${project_dir}/.build-cache/toolchain-downloads}"
vendor_target="${project_dir}/Vendor/Toolchain/arm64"
deployment_target="13.0"
install_prefix="/YIOS"

typeset -a component_records
component_records=(
  'libplist-2.7.0|libplist-2.7.0.tar.bz2|https://github.com/libimobiledevice/libplist/releases/download/2.7.0/libplist-2.7.0.tar.bz2|7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b'
  'libimobiledevice-glue-1.3.2|libimobiledevice-glue-1.3.2.tar.bz2|https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/1.3.2/libimobiledevice-glue-1.3.2.tar.bz2|6489a3411b874ecd81c87815d863603f518b264a976319725e0ed59935546774'
  'libusbmuxd-2.1.1|libusbmuxd-2.1.1.tar.bz2|https://github.com/libimobiledevice/libusbmuxd/releases/download/2.1.1/libusbmuxd-2.1.1.tar.bz2|5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce'
  'libtatsu-1.0.5|libtatsu-1.0.5.tar.bz2|https://github.com/libimobiledevice/libtatsu/releases/download/1.0.5/libtatsu-1.0.5.tar.bz2|536fa228b14f156258e801a7f4d25a3a9dd91bb936bf6344e23171403c57e440'
  'libimobiledevice-1.4.0|libimobiledevice-1.4.0.tar.bz2|https://github.com/libimobiledevice/libimobiledevice/releases/download/1.4.0/libimobiledevice-1.4.0.tar.bz2|23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d'
  'libirecovery-1.3.1|libirecovery-1.3.1.tar.bz2|https://github.com/libimobiledevice/libirecovery/releases/download/1.3.1/libirecovery-1.3.1.tar.bz2|28a3a521782063c8eb2ee5f4c0f38a517e023853edb55856052cdd7ac400381b'
  'openssl-3.5.7|openssl-3.5.7.tar.gz|https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz|a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8'
)

typeset -a helper_names
helper_names=(
  idevice_id
  ideviceinfo
  idevicepair
  ideviceenterrecovery
  idevicediagnostics
  idevicecrashreport
  irecovery
)

fail() {
  print -u2 -- "Toolchain build failed: $*"
  exit 1
}

require_executable() {
  [[ -x "$1" ]] || fail "required executable not found: $1"
}

sha256_for() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

download_and_verify() {
  local filename="$1"
  local url="$2"
  local expected="$3"
  local destination="${cache_dir}/${filename}"

  if [[ -f "$destination" && "$(sha256_for "$destination")" == "$expected" ]]; then
    print -- "Using cached ${filename}"
    return
  fi

  local partial="${destination}.partial.$$"
  /bin/rm -f "$partial"
  /usr/bin/curl --fail --location --retry 3 --output "$partial" "$url"
  local actual
  actual="$(sha256_for "$partial")"
  [[ "$actual" == "$expected" ]] || fail "checksum mismatch for ${filename}: ${actual}"
  /bin/mv "$partial" "$destination"
}

pkg_config=""
for candidate in /opt/homebrew/bin/pkg-config /usr/local/bin/pkg-config /usr/bin/pkg-config; do
  if [[ -x "$candidate" ]]; then
    pkg_config="$candidate"
    break
  fi
done
[[ -n "$pkg_config" ]] || fail "pkg-config is required to build the bundled tools"

for executable in /usr/bin/curl /usr/bin/make /usr/bin/perl /usr/bin/shasum \
  /usr/bin/tar /usr/bin/xcrun /usr/bin/install_name_tool /usr/bin/otool \
  /usr/bin/codesign /usr/bin/strip; do
  require_executable "$executable"
done

sdk_root="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
cc="$(/usr/bin/xcrun --sdk macosx --find clang)"
cxx="$(/usr/bin/xcrun --sdk macosx --find clang++)"
require_executable "$cc"
require_executable "$cxx"

/bin/mkdir -p "$cache_dir"
for record in "${component_records[@]}"; do
  IFS='|' read -r _ filename url checksum <<< "$record"
  download_and_verify "$filename" "$url" "$checksum"
done

work_root="$(/usr/bin/mktemp -d /private/tmp/yios-bundled-tools.XXXXXX)"
cleanup() {
  if [[ "${YIOS_KEEP_BUILD_ROOT:-0}" == "1" ]]; then
    print -u2 -- "Preserving toolchain work directory: ${work_root:-unknown}"
  elif [[ -n "${work_root:-}" && "$work_root" == /private/tmp/yios-bundled-tools.* ]]; then
    /bin/rm -rf "$work_root"
  fi
}
trap cleanup EXIT INT TERM

source_root="${work_root}/src"
dest_root="${work_root}/dest"
stage_prefix="${dest_root}${install_prefix}"
payload_root="${work_root}/payload"
helpers_dir="${payload_root}/Helpers/YIOSTools"
frameworks_dir="${payload_root}/Frameworks/YIOSTools"
resources_dir="${payload_root}/Resources"
notices_dir="${resources_dir}/ThirdPartyNotices"
/bin/mkdir -p "$source_root" "$stage_prefix" "$helpers_dir" "$frameworks_dir" "$notices_dir"

for record in "${component_records[@]}"; do
  IFS='|' read -r _ filename _ _ <<< "$record"
  /usr/bin/tar -xf "${cache_dir}/${filename}" -C "$source_root"
done

export SDKROOT="$sdk_root"
export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
export CC="$cc"
export CXX="$cxx"
export CFLAGS="-arch arm64 -mmacosx-version-min=${deployment_target} -O2"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I${stage_prefix}/include"
export LDFLAGS="-arch arm64 -mmacosx-version-min=${deployment_target} -L${stage_prefix}/lib"
export PKG_CONFIG="$pkg_config"
export PKG_CONFIG_PATH="${stage_prefix}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${stage_prefix}/lib/pkgconfig:${sdk_root}/usr/lib/pkgconfig"
export DYLD_LIBRARY_PATH="${stage_prefix}/lib"
export PATH="${pkg_config:h}:/usr/bin:/bin:/usr/sbin:/sbin"
# Old generated libtool scripts ask sysctl for kern.argmax. Supplying the
# conservative cache value avoids a sandbox-dependent empty result.
export lt_cv_sys_max_cmd_len=262144

jobs="$(/usr/sbin/sysctl -n hw.logicalcpu 2>/dev/null || print 4)"
[[ "$jobs" == <-> && "$jobs" -gt 0 ]] || jobs=4

print -- "Building OpenSSL 3.5.7 for arm64 macOS ${deployment_target}"
(
  cd "${source_root}/openssl-3.5.7"
  ./Configure darwin64-arm64 \
    --prefix="$install_prefix" \
    --openssldir="${install_prefix}/etc/ssl" \
    --libdir=lib \
    shared no-tests no-apps no-docs no-autoload-config \
    "CC=${cc}" \
    "CXX=${cxx}" \
    "CFLAGS=-O2 -isysroot ${sdk_root} -mmacosx-version-min=${deployment_target}" \
    "CXXFLAGS=-O2 -isysroot ${sdk_root} -mmacosx-version-min=${deployment_target}" \
    "LDFLAGS=-isysroot ${sdk_root} -mmacosx-version-min=${deployment_target}"
  /usr/bin/make -j "$jobs"
  /usr/bin/make install_sw DESTDIR="$dest_root"
)
for metadata in "${stage_prefix}/lib/pkgconfig"/*.pc(N); do
  /usr/bin/sed -i '' "s#${install_prefix}#${stage_prefix}#g" "$metadata"
done

build_autotools() {
  local source_name="$1"
  shift
  print -- "Building ${source_name}"
  (
    cd "${source_root}/${source_name}"
    ./configure --prefix="$stage_prefix" --enable-shared --disable-static "$@"
    /usr/bin/make -j "$jobs"
    /usr/bin/make install
  )
}

build_autotools libplist-2.7.0 --without-cython --without-tools
build_autotools libimobiledevice-glue-1.3.2
build_autotools libusbmuxd-2.1.1

export libcurl_CFLAGS="-I${sdk_root}/usr/include"
export libcurl_LIBS="-lcurl"
build_autotools libtatsu-1.0.5

build_autotools libimobiledevice-1.4.0 \
  --without-cython \
  --without-readline \
  --with-openssl \
  --without-gnutls \
  --without-mbedtls \
  --disable-wireless-pairing

export ac_cv_header_readline_readline_h=no
build_autotools libirecovery-1.3.1 --with-tools --with-iokit --without-udev

for helper in "${helper_names[@]}"; do
  source_helper="${stage_prefix}/bin/${helper}"
  [[ -x "$source_helper" ]] || fail "build did not produce ${helper}"
  /bin/cp "$source_helper" "${helpers_dir}/${helper}"
  /bin/chmod 0755 "${helpers_dir}/${helper}"
done

# Resolve and copy the complete non-system dylib closure from the isolated
# prefix. This includes libtatsu only if the selected helpers actually link it.
typeset -A copied_dylibs
typeset -a dependency_queue
dependency_queue=("${helpers_dir}"/*)
queue_index=1
while (( queue_index <= ${#dependency_queue[@]} )); do
  current="${dependency_queue[$queue_index]}"
  (( queue_index++ ))
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /usr/lib/*|/System/Library/*) continue ;;
    esac
    basename="${dependency:t}"
    [[ -n "${copied_dylibs[$basename]:-}" ]] && continue
    source_dylib="${stage_prefix}/lib/${basename}"
    [[ -e "$source_dylib" ]] || fail "unresolved non-system dependency ${dependency}"
    /bin/cp -L "$source_dylib" "${frameworks_dir}/${basename}"
    /bin/chmod 0755 "${frameworks_dir}/${basename}"
    copied_dylibs[$basename]=1
    dependency_queue+=("${frameworks_dir}/${basename}")
  done < <(/usr/bin/otool -L "$current" | /usr/bin/tail -n +2 | /usr/bin/sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
done

(( ${#copied_dylibs[@]} > 0 )) || fail "no dylib closure was discovered"

for dylib in "${frameworks_dir}"/*.dylib; do
  /usr/bin/strip -x "$dylib"
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /usr/lib/*|/System/Library/*) continue ;;
    esac
    basename="${dependency:t}"
    [[ -f "${frameworks_dir}/${basename}" ]] || fail "missing bundled dependency ${basename}"
    /usr/bin/install_name_tool -change "$dependency" "@loader_path/${basename}" "$dylib"
  # A dylib's first otool entry is its own LC_ID_DYLIB, not a dependency.
  done < <(/usr/bin/otool -L "$dylib" | /usr/bin/tail -n +3 | /usr/bin/sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
  /usr/bin/install_name_tool -id "@rpath/${dylib:t}" "$dylib"
done

for helper in "${helpers_dir}"/*; do
  /usr/bin/strip -x "$helper"
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /usr/lib/*|/System/Library/*) continue ;;
    esac
    basename="${dependency:t}"
    [[ -f "${frameworks_dir}/${basename}" ]] || fail "missing bundled dependency ${basename}"
    /usr/bin/install_name_tool -change "$dependency" "@rpath/${basename}" "$helper"
  done < <(/usr/bin/otool -L "$helper" | /usr/bin/tail -n +2 | /usr/bin/sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')
  /usr/bin/install_name_tool -add_rpath '@executable_path/../../Frameworks/YIOSTools' "$helper"
done

/bin/cp "${script_dir}/ToolchainManifest.plist" "${resources_dir}/ToolchainManifest.plist"
/bin/cp "${script_dir}/ThirdPartyNotices.md" "${notices_dir}/README.md"
/bin/cp "${script_dir}/build-bundled-tools.sh" "${notices_dir}/build-bundled-tools.sh"
/bin/chmod 0755 "${notices_dir}/build-bundled-tools.sh"
/bin/cp "${script_dir}/verify-bundled-tools.sh" "${notices_dir}/verify-bundled-tools.sh"
/bin/chmod 0755 "${notices_dir}/verify-bundled-tools.sh"
/bin/cp "${script_dir}/ToolchainManifest.plist" "${notices_dir}/ToolchainManifest.plist"
/bin/cp "${source_root}/libimobiledevice-1.4.0/COPYING" "${notices_dir}/libimobiledevice-GPL-2.0.txt"
/bin/cp "${source_root}/libimobiledevice-1.4.0/COPYING.LESSER" "${notices_dir}/libimobiledevice-LGPL-2.1.txt"
/bin/cp "${source_root}/libplist-2.7.0/COPYING" "${notices_dir}/libplist-GPL-2.0.txt"
/bin/cp "${source_root}/libplist-2.7.0/COPYING.LESSER" "${notices_dir}/libplist-LGPL-2.1.txt"
/bin/cp "${source_root}/libimobiledevice-glue-1.3.2/COPYING" "${notices_dir}/libimobiledevice-glue-LGPL-2.1.txt"
/bin/cp "${source_root}/libusbmuxd-2.1.1/COPYING" "${notices_dir}/libusbmuxd-LGPL-2.1.txt"
/bin/cp "${source_root}/libtatsu-1.0.5/COPYING" "${notices_dir}/libtatsu-LGPL-2.1.txt"
/bin/cp "${source_root}/libirecovery-1.3.1/COPYING" "${notices_dir}/libirecovery-LGPL-2.1.txt"
/bin/cp "${source_root}/openssl-3.5.7/LICENSE.txt" "${notices_dir}/OpenSSL-Apache-2.0.txt"

# Relocation changes Mach-O signatures. Sign nested code before hashing it.
signing_identity="${YIOS_CODESIGN_IDENTITY:--}"
for dylib in "${frameworks_dir}"/*.dylib; do
  /usr/bin/codesign --force --sign "$signing_identity" "$dylib"
done
for helper in "${helpers_dir}"/*; do
  /usr/bin/codesign --force --sign "$signing_identity" "$helper"
done

(
  cd "$payload_root"
  : > "${resources_dir}/ToolchainPayload.sha256"
  while IFS= read -r relative; do
    /usr/bin/shasum -a 256 "$relative" >> "${resources_dir}/ToolchainPayload.sha256"
  done < <(/usr/bin/find Helpers Frameworks -type f -print | LC_ALL=C /usr/bin/sort)
)

"${script_dir}/verify-bundled-tools.sh" "$payload_root"

[[ "$vendor_target" == "${project_dir}/Vendor/Toolchain/arm64" ]] || fail "unsafe vendor target"
/bin/mkdir -p "${vendor_target:h}"
/bin/rm -rf "$vendor_target"
/bin/mv "$payload_root" "$vendor_target"

print -- "Bundled toolchain ready: ${vendor_target}"
