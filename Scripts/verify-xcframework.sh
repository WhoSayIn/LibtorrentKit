#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/Vendor/LibtorrentNative.xcframework"
OPENSSL="$ROOT/Vendor/OpenSSL.xcframework"
CA="$ROOT/Vendor/cacert-2026-08-13.pem"
CA_SHA256="f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9"

[[ -d "$NATIVE" ]] || { echo "missing $NATIVE" >&2; exit 1; }
[[ -d "$OPENSSL" ]] || { echo "missing $OPENSSL" >&2; exit 1; }
[[ -s "$CA" ]] || { echo "missing CA bundle" >&2; exit 1; }
[[ "$(shasum -a 256 "$CA" | awk '{print $1}')" == "$CA_SHA256" ]] || { echo "CA checksum mismatch" >&2; exit 1; }

device="$NATIVE/ios-arm64/LibtorrentNative.framework/LibtorrentNative"
simulator="$NATIVE/ios-arm64_x86_64-simulator/LibtorrentNative.framework/LibtorrentNative"
macos="$NATIVE/macos-arm64_x86_64/LibtorrentNative.framework/LibtorrentNative"
lipo "$device" -verify_arch arm64
lipo "$simulator" -verify_arch arm64 x86_64
lipo "$macos" -verify_arch arm64 x86_64

# Static archives retain their linkable symbol table. The visibility check that
# matters is that the public header only exposes the repo-owned C ABI; hidden
# C++ symbols remain hidden when the archive is linked into an application.
nm -gU "$device" | awk '{print $3}' | grep '^_ltkit_' >/dev/null
if grep -Ev '^(LTKIT_API |typedef |struct |enum |#|$|[[:space:]])' \
    "$NATIVE/ios-arm64/LibtorrentNative.framework/Headers/LibtorrentNative.h" \
    | grep -qE 'libtorrent|boost::|std::'; then
  echo "C++ implementation detail leaked through the public header" >&2
  exit 1
fi

for binary in \
  "$OPENSSL/ios-arm64/OpenSSL.framework/OpenSSL" \
  "$OPENSSL/ios-arm64_x86_64-simulator/OpenSSL.framework/OpenSSL" \
  "$OPENSSL/macos-arm64_x86_64/OpenSSL.framework/Versions/A/OpenSSL"; do
  otool -L "$binary"
done

echo "XCFramework verification passed"
