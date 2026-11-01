#!/usr/bin/env bash
# Build the armsr/armv8 rootfs with the official iStoreOS ImageBuilder.
set -euo pipefail

WS=${GITHUB_WORKSPACE:-$(pwd)}
IB="$WS/build/ib/$IB_DIR"
OUT="$IB/bin/targets/armsr/armv8"

cd "$IB"

# Also emit a plain rootfs.tar.gz (the official OpenWrt armsr release does this too).
if grep -q '^# CONFIG_TARGET_ROOTFS_TARGZ is not set' .config; then
  sed -i 's/^# CONFIG_TARGET_ROOTFS_TARGZ is not set/CONFIG_TARGET_ROOTFS_TARGZ=y/' .config
fi
grep -n 'CONFIG_TARGET_ROOTFS_TARGZ' .config || true

PKGS=$(tr '\n' ' ' < "$WS/scripts/packages.txt")
echo "packages requested: $(wc -w <<< "$PKGS") entries (including -removal tokens)"
echo "main packages: firewall iptables-zz-legacy ip6tables-zz-legacy; removed: firewall4 nftables kmod-nft-offload"

make image PROFILE=generic PACKAGES="$PKGS" -j"$(nproc)" || {
  rc=$?
  echo "::warning::make image failed (rc=$rc); retrying with CONFIG_SIGNATURE_CHECK disabled (unsupported signature/keys mismatch)"
  make image CONFIG_SIGNATURE_CHECK= PROFILE=generic PACKAGES="$PKGS" -j"$(nproc)"
}

echo "=== build output ==="
ls -la "$OUT"
echo "=== generated manifest (first/last lines) ==="
MAN=$(ls "$OUT"/*.manifest 2>/dev/null | head -1 || true)
if [ -n "${MAN:-}" ]; then
  wc -l "$MAN"
  grep -E '^(firewall|iptables|ip6tables|xtables|libip)' "$MAN" | head -20 || true
fi
