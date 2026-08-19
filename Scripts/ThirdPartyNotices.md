# Third-party mobile-device toolchain

YIOS-KIT includes separate command-line programs and dynamically linked
libraries built from unmodified upstream source from the official releases
below. The packaged Mach-O binaries are stripped, relocated to bundle-relative
load paths, and code signed. They run as child processes; Apple Configurator is
not included. The open-source usbmuxd daemon is also not included because macOS
supplies Apple's device service.

| Component | Version | License | Release tag commit | Official source archive | SHA-256 |
|---|---:|---|---|---|---|
| libimobiledevice | 1.4.0 | LGPL-2.1-or-later | `149f7623c672c1fa73122c7119a12bfc0012f2ac` | https://github.com/libimobiledevice/libimobiledevice/releases/download/1.4.0/libimobiledevice-1.4.0.tar.bz2 | `23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d` |
| libirecovery | 1.3.1 | LGPL-2.1-only | `b59ef4814525f487287da1609864f432cd79e3ed` | https://github.com/libimobiledevice/libirecovery/releases/download/1.3.1/libirecovery-1.3.1.tar.bz2 | `28a3a521782063c8eb2ee5f4c0f38a517e023853edb55856052cdd7ac400381b` |
| libplist | 2.7.0 | LGPL-2.1-or-later | `cf5897a71ea412ea2aeb1e2f6b5ea74d4fabfd8c` | https://github.com/libimobiledevice/libplist/releases/download/2.7.0/libplist-2.7.0.tar.bz2 | `7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b` |
| libimobiledevice-glue | 1.3.2 | LGPL-2.1-or-later | `aef2bf0f5bfe961ad83d224166462d87b1df2b00` | https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/1.3.2/libimobiledevice-glue-1.3.2.tar.bz2 | `6489a3411b874ecd81c87815d863603f518b264a976319725e0ed59935546774` |
| libusbmuxd client library | 2.1.1 | LGPL-2.1-or-later | `adf9c22b9010490e4b55eaeb14731991db1c172c` | https://github.com/libimobiledevice/libusbmuxd/releases/download/2.1.1/libusbmuxd-2.1.1.tar.bz2 | `5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce` |
| libtatsu (build-time prerequisite; bundled only if linked) | 1.0.5 | LGPL-2.1-or-later | `42329cb756682535c7c0f087987b78d1dd5b16c8` | https://github.com/libimobiledevice/libtatsu/releases/download/1.0.5/libtatsu-1.0.5.tar.bz2 | `536fa228b14f156258e801a7f4d25a3a9dd91bb936bf6344e23171403c57e440` |
| OpenSSL | 3.5.7 LTS | Apache-2.0 | `8cf17aaeb4599f8af87fefd810b5b5fee90fe69e` | https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz | `a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8` |

The exact build, relocation, and offline verification procedure is shipped
beside this notice as `build-bundled-tools.sh` and
`verify-bundled-tools.sh`. The same scripts are in the project under
`Scripts/`.
The complete corresponding source is available from the pinned URLs above and
can be fetched with that script. No local changes are applied to those sources.
The bundled LGPL libraries remain separate dynamic libraries. Nothing in the
application license is intended to prohibit reverse engineering solely for
debugging changes to those LGPL components.

The full license texts shipped beside this notice control in case of conflict.
The `COPYING` files included by libimobiledevice and libplist contain GPL text
for GPL-covered source portions; their `COPYING.LESSER` files contain LGPL 2.1.
The selected utilities and libraries are described by those projects as LGPL.
