#!/usr/bin/env bash
# The official iStoreOS ImageBuilder ships only the packages needed for the
# nftables/firewall4 based images. We additionally need fw3 (firewall) and the
# legacy iptables binaries, so fetch them from the matching official OpenWrt
# 25.12.6 release feeds and drop them into the ImageBuilder package folder.
set -euo pipefail

WS=${GITHUB_WORKSPACE:-$(pwd)}
PKG_DIR="$WS/build/ib/$IB_DIR/packages"
BASE="https://downloads.openwrt.org/releases/25.12.6/packages/aarch64_generic/base"
TGT="https://downloads.openwrt.org/releases/25.12.6/targets/armsr/armv8/packages"

mkdir -p "$PKG_DIR"

FILES=(
  "$BASE/firewall-2025.10.03~3a65fde5-r2.apk"
  "$TGT/iptables-zz-legacy-1.8.10-r3.apk"
  "$TGT/ip6tables-zz-legacy-1.8.10-r3.apk"
  "$TGT/xtables-legacy-1.8.10-r3.apk"
  "$TGT/libip4tc2-1.8.10-r3.apk"
  "$TGT/libip6tc2-1.8.10-r3.apk"
)

for url in "${FILES[@]}"; do
  name=$(basename "$url")
  echo "downloading $name"
  curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 -m 300 -o "$PKG_DIR/$name.part" "$url"
  mv "$PKG_DIR/$name.part" "$PKG_DIR/$name"
done

echo "=== extra packages added to ImageBuilder ==="
ls -la "$PKG_DIR" | grep -E 'firewall-|iptables-zz-legacy|ip6tables-zz-legacy|xtables-legacy|libip4tc2|libip6tc2'
echo "total packages available: $(ls "$PKG_DIR"/*.apk | wc -l)"
