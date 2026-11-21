#!/bin/sh
# Build pinned ngtcp2 (GnuTLS crypto backend) and nghttp3 as static libs into
# deps/out. Needs: git, cmake, a C compiler, pkg-config, GnuTLS >= 3.7.5 dev
# headers (Debian/Ubuntu: libgnutls28-dev; macOS: brew install gnutls).
set -eu
NGTCP2=v1.26.0
NGHTTP3=v1.19.0
here=$(cd "$(dirname "$0")/.." && pwd)
src="$here/deps/src"; out="$here/deps/out"
mkdir -p "$src"
clone() { [ -d "$src/$1" ] || git -c advice.detachedHead=false clone -q --depth 1 --branch "$2" --recurse-submodules --shallow-submodules "https://github.com/ngtcp2/$1" "$src/$1"; }
clone nghttp3 "$NGHTTP3"
clone ngtcp2 "$NGTCP2"
common="-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$out -DENABLE_LIB_ONLY=ON -DENABLE_STATIC_LIB=ON -DENABLE_SHARED_LIB=OFF -DBUILD_TESTING=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON"
cmake -S "$src/nghttp3" -B "$src/nghttp3/build" $common >/dev/null
cmake --build "$src/nghttp3/build" -j >/dev/null && cmake --install "$src/nghttp3/build" >/dev/null
cmake -S "$src/ngtcp2" -B "$src/ngtcp2/build" $common -DENABLE_GNUTLS=ON -DENABLE_OPENSSL=OFF >/dev/null
cmake --build "$src/ngtcp2/build" -j >/dev/null && cmake --install "$src/ngtcp2/build" >/dev/null
echo "installed to $out"
