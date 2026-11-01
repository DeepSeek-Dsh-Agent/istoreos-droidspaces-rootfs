#!/usr/bin/env bash
# Publish the rootfs as a GitHub release and update rootfs.json (Droidspaces custom repo format).
set -euo pipefail

WS=${GITHUB_WORKSPACE:-$(pwd)}
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
ASSET_SRC=$(ls "$WS"/build/out/*.tar.xz | head -1)

TS=$(date -u +%Y%m%d-%H%M%S)
BDATE=$(date -u +%Y%m%d)
TAG="v$TS"
ASSET="iStoreOS-$IB_VERSION-Droidspaces-rootfs-aarch64-$BDATE.tar.xz"
RELDIR="$WS/build/release"
mkdir -p "$RELDIR"
cp "$ASSET_SRC" "$RELDIR/$ASSET"

SHA256=$(sha256sum "$RELDIR/$ASSET" | awk '{print $1}')
SIZE=$(stat -c%s "$RELDIR/$ASSET")
echo "asset:  $ASSET"
echo "sha256: $SHA256"
echo "size:   $SIZE bytes"

cat > "$RELDIR/notes.md" <<NOTES
iStoreOS **$IB_VERSION** (armsr/armv8, aarch64) rootfs for Android/Droidspaces containers.

- Built from the **official iStoreOS ImageBuilder** ($IB_VERSION) on GitHub Actions (run: ${RUN_URL:-see Actions}).
- **fw3 + iptables-legacy** instead of nftables/firewall4 (Android GKI kernels have no \`CONFIG_NF_TABLES\`).
- \`/lib/modules\` removed; Android AID groups (aid_inet / aid_net_raw / aid_net_admin) added for root.
- debugfs mount line removed from \`/etc/init.d/boot\`.
- Container network defaults: \`wan\` = eth0 DHCP (Droidspaces NAT), \`wan6\` = eth0 DHCPv6, \`lan\` = br-lan 192.168.100.1/24 (eth1, VirtualAP/gateway mode), \`net.ipv4.ip_forward=1\`.

Install: add this repository as a custom repo in the Droidspaces App
(\`https://raw.githubusercontent.com/$REPO/main/rootfs.json\`) or download the asset below.

sha256: \`$SHA256\`
size: $SIZE bytes
NOTES

# release (skip if the tag somehow exists)
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "release $TAG already exists, uploading asset"
  gh release upload "$TAG" "$RELDIR/$ASSET" --repo "$REPO" --clobber
else
  gh release create "$TAG" "$RELDIR/$ASSET" --repo "$REPO" \
    --title "iStoreOS $IB_VERSION - Minimal (iptables-legacy) aarch64 rootfs ($BDATE)" \
    --notes-file "$RELDIR/notes.md"
fi

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
echo "download_url: $DOWNLOAD_URL"

python3 "$WS/scripts/gen-rootfs-json.py" \
  --download-url "$DOWNLOAD_URL" \
  --sha256 "$SHA256" \
  --size "$SIZE" \
  --version "$TAG" \
  --build-date "$BDATE" \
  --out "$WS/rootfs.json"
python3 -c "import json; json.load(open('$WS/rootfs.json')); print('rootfs.json valid JSON')"

# commit rootfs.json back as github-actions[bot]
cd "$WS"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add rootfs.json
if git diff --cached --quiet; then
  echo "rootfs.json unchanged, nothing to commit"
else
  git commit -m "release: iStoreOS $IB_VERSION aarch64 rootfs $TAG"
  git push origin "HEAD:${GITHUB_REF_NAME:-main}"
fi
echo "done."
