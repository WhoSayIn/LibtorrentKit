#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$ROOT/.artifacts"
VENDOR="$ROOT/Vendor"
LIBTORRENT_REPOSITORY="https://github.com/arvidn/libtorrent.git"
LIBTORRENT_TAG="v2.1.1"
LIBTORRENT_COMMIT="56ae8caba38bf154ffc210403cb23f91d0ecaa49"
BOOST_VERSION="1.92.0"
BOOST_URL="https://github.com/boostorg/boost/releases/download/boost-1.92.0/boost-1.92.0-cmake.tar.xz"
BOOST_SHA256="9bed76128d4e46755dbe818487788c6fceb6f72b378f4daa49b7e1e600d9088d"
OPENSSL_VERSION="3.6.3000"
OPENSSL_URL="https://github.com/krzyzanowskim/OpenSSL/releases/download/3.6.3000/OpenSSL.xcframework.zip"
OPENSSL_SHA256="6c4b064d12b8de2ae77ac59fbcbbd1c20b4fecfb7fc50b8ab326347c52ecbf0c"
CA_BUNDLE_DATE="2026-08-13"
CA_BUNDLE_URL="https://curl.se/ca/cacert-2026-08-13.pem"
CA_BUNDLE_SHA256="f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9"

for tool in cmake curl git shasum tar unzip xcodebuild xcrun lipo libtool plutil; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done
if command -v ninja >/dev/null; then
  CMAKE_GENERATOR="Ninja"
else
  command -v make >/dev/null || { echo "missing both ninja and make" >&2; exit 1; }
  CMAKE_GENERATOR="Unix Makefiles"
fi

mkdir -p "$ARTIFACTS/downloads" "$ARTIFACTS/build" "$ARTIFACTS/frameworks" "$VENDOR"

verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "checksum mismatch: $file" >&2; exit 1; }
}

fetch() {
  local url="$1" destination="$2" checksum="$3"
  if [[ ! -f "$destination" ]]; then curl --fail --location --retry 3 --output "$destination" "$url"; fi
  verify_sha256 "$destination" "$checksum"
}

if [[ ! -d "$ARTIFACTS/libtorrent/.git" ]]; then
  git clone --filter=blob:none --no-checkout "$LIBTORRENT_REPOSITORY" "$ARTIFACTS/libtorrent"
fi
git -C "$ARTIFACTS/libtorrent" fetch --force --tags origin "$LIBTORRENT_TAG"
resolved_commit="$(git -C "$ARTIFACTS/libtorrent" rev-list -n 1 "$LIBTORRENT_TAG")"
[[ "$resolved_commit" == "$LIBTORRENT_COMMIT" ]] || { echo "libtorrent tag resolved to unexpected commit: $resolved_commit" >&2; exit 1; }
git -C "$ARTIFACTS/libtorrent" checkout --detach "$LIBTORRENT_COMMIT"
git -C "$ARTIFACTS/libtorrent" submodule update --init --recursive --depth 1
[[ "$(git -C "$ARTIFACTS/libtorrent" rev-parse HEAD)" == "$LIBTORRENT_COMMIT" ]]

boost_archive="$ARTIFACTS/downloads/boost-$BOOST_VERSION.tar.xz"
fetch "$BOOST_URL" "$boost_archive" "$BOOST_SHA256"
if [[ ! -d "$ARTIFACTS/boost-$BOOST_VERSION/boost" ]]; then
  if [[ ! -f "$ARTIFACTS/boost-$BOOST_VERSION/bootstrap.sh" ]]; then
    rm -rf "$ARTIFACTS/boost-$BOOST_VERSION"
    mkdir -p "$ARTIFACTS/boost-$BOOST_VERSION"
    tar -xf "$boost_archive" -C "$ARTIFACTS/boost-$BOOST_VERSION" --strip-components=1
  fi
  (cd "$ARTIFACTS/boost-$BOOST_VERSION" && ./bootstrap.sh && ./b2 headers)
fi

openssl_archive="$ARTIFACTS/downloads/OpenSSL-$OPENSSL_VERSION.xcframework.zip"
fetch "$OPENSSL_URL" "$openssl_archive" "$OPENSSL_SHA256"
if [[ ! -d "$VENDOR/OpenSSL.xcframework" ]]; then unzip -q "$openssl_archive" -d "$VENDOR"; fi

ca_bundle="$VENDOR/cacert-$CA_BUNDLE_DATE.pem"
fetch "$CA_BUNDLE_URL" "$ca_bundle" "$CA_BUNDLE_SHA256"

build_slice() {
  local name="$1" system="$2" sdk="$3" architectures="$4" openssl_slice="$5" deployment="$6"
  local build="$ARTIFACTS/build/$name"
  local framework="$ARTIFACTS/frameworks/$name/LibtorrentNative.framework"
  local openssl_framework="$VENDOR/OpenSSL.xcframework/$openssl_slice/OpenSSL.framework"
  local openssl_include="$ARTIFACTS/build/$name-openssl-include"
  rm -rf "$framework"
  mkdir -p "$build" "$framework/Headers" "$framework/Modules"
  if [[ ! -d "$openssl_include/openssl" ]]; then
    mkdir -p "$openssl_include/openssl"
    cp -R "$openssl_framework/Headers/." "$openssl_include/openssl/"
  fi

  cmake -S "$ROOT/Native" -B "$build" -G "$CMAKE_GENERATOR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME="$system" \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$architectures" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment" \
    -DCMAKE_XCODE_ATTRIBUTE_BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    -DLIBTORRENT_SOURCE_DIR="$ARTIFACTS/libtorrent" \
    -DBoost_INCLUDE_DIR="$ARTIFACTS/boost-$BOOST_VERSION" \
    -DOPENSSL_INCLUDE_DIR="$openssl_include" \
    -DOPENSSL_SSL_LIBRARY="$openssl_framework/OpenSSL" \
    -DOPENSSL_CRYPTO_LIBRARY="$openssl_framework/OpenSSL" \
    -DOPENSSL_USE_STATIC_LIBS=OFF
  cmake --build "$build" --target LibtorrentNative --parallel

  libtool -static -o "$framework/LibtorrentNative" \
    "$build/libLibtorrentNative.a" "$build/libtorrent/libtorrent-rasterbar.a"
  cp "$ROOT/Native/include/LibtorrentNative.h" "$framework/Headers/"
  cp "$ROOT/Native/include/module.modulemap" "$framework/Modules/"
  cp "$ROOT/Native/FrameworkInfo.plist" "$framework/Info.plist"
  plutil -replace MinimumOSVersion -string "$deployment" "$framework/Info.plist"
  lipo -info "$framework/LibtorrentNative"
  local arch
  local -a architecture_list
  IFS=';' read -r -a architecture_list <<< "$architectures"
  for arch in "${architecture_list[@]}"; do
    lipo "$framework/LibtorrentNative" -verify_arch "$arch"
  done
}

build_slice "ios-arm64" "iOS" "iphoneos" "arm64" "ios-arm64" "17.0"
build_slice "ios-simulator" "iOS" "iphonesimulator" "arm64;x86_64" "ios-arm64_x86_64-simulator" "17.0"
build_slice "macos" "Darwin" "macosx" "arm64;x86_64" "macos-arm64_x86_64" "14.0"

rm -rf "$VENDOR/LibtorrentNative.xcframework"
xcodebuild -create-xcframework \
  -framework "$ARTIFACTS/frameworks/ios-arm64/LibtorrentNative.framework" \
  -framework "$ARTIFACTS/frameworks/ios-simulator/LibtorrentNative.framework" \
  -framework "$ARTIFACTS/frameworks/macos/LibtorrentNative.framework" \
  -output "$VENDOR/LibtorrentNative.xcframework"

"$ROOT/Scripts/verify-xcframework.sh"
echo "Built $VENDOR/LibtorrentNative.xcframework"
