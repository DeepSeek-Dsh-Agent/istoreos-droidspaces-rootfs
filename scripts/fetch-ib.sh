#!/usr/bin/env bash
# Download the official iStoreOS ImageBuilder and extract it.
# Primary source: a GitHub release "cache" asset in this repo (fast, stable for CI).
# Fallback: fw.koolcenter.com upstream (timing + sha256 are logged).
set -euo pipefail

WS=${GITHUB_WORKSPACE:-$(pwd)}
BUILD_DIR="$WS/build"
TARBALL="$BUILD_DIR/$IB_TARBALL"
CACHE_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${IB_CACHE_TAG}/${IB_TARBALL}"
UPSTREAM_URL="https://fw.koolcenter.com/iStoreOS/ib/armsr/istoreos-imagebuilder-armsr-armv8.Linux-x86_64.tar.zst"

mkdir -p "$BUILD_DIR"

download() {
  local url=$1 out=$2
  echo "::group::download ${url}"
  local start end size dur speed
  start=$(date +%s)
  # abort if throughput stays below 150 KiB/s for 120 s: an IB mirror that slow is not worth waiting for
  curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 1800 \
       --speed-limit 150000 --speed-time 120 -o "$out.part" "$url"
  end=$(date +%s); size=$(stat -c%s "$out.part"); dur=$(( end - start )); [ "$dur" -eq 0 ] && dur=1
  speed=$(( size / dur / 1024 ))
  echo "downloaded ${size} bytes in ${dur}s (~${speed} KiB/s)"
  mv "$out.part" "$out"
  echo "::endgroup::"
}

used_cache=false
if [ "${FORCE_UPSTREAM:-false}" != "true" ]; then
  echo "checking GitHub cache asset: ${CACHE_URL}"
  if curl -fsIL --retry 2 --connect-timeout 20 -m 60 "$CACHE_URL" >/dev/null 2>&1; then
    download "$CACHE_URL" "$TARBALL"
    used_cache=true
  else
    echo "cache asset not available; falling back to upstream (fw.koolcenter.com)"
  fi
fi
if [ "$used_cache" != "true" ]; then
  download "$UPSTREAM_URL" "$TARBALL"
fi

echo "verifying sha256 ..."
echo "${IB_SHA256}  ${TARBALL}" | sha256sum -c -
echo "IB sha256: $(sha256sum "$TARBALL" | awk '{print $1}')"
echo "IB size:   $(stat -c%s "$TARBALL") bytes"

echo "extracting ImageBuilder ..."
rm -rf "$BUILD_DIR/ib"
mkdir -p "$BUILD_DIR/ib"
zstd -dc --long=31 "$TARBALL" | tar -xf - -C "$BUILD_DIR/ib"
test -f "$BUILD_DIR/ib/$IB_DIR/include/version.mk"
echo "ImageBuilder version:"
grep -E '^(VERSION_NUMBER|REVISION|KERNEL_VERSION)' "$BUILD_DIR/ib/$IB_DIR/include/version.mk" || true
