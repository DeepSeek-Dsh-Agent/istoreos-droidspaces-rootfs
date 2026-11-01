#!/usr/bin/env bash
# Turn the ImageBuilder rootfs into a Droidspaces/Android-friendly container rootfs.
set -euo pipefail

WS=${GITHUB_WORKSPACE:-$(pwd)}
IB="$WS/build/ib/$IB_DIR"
OUT="$IB/bin/targets/armsr/armv8"
WORK="$WS/build/rootfs"
FINAL_DIR="$WS/build/out"
mkdir -p "$WORK" "$FINAL_DIR"

ROOTFS_TGZ=$(ls "$OUT"/*rootfs.tar.gz 2>/dev/null | head -1 || true)
if [ -n "${ROOTFS_TGZ:-}" ]; then
  echo "source rootfs: $ROOTFS_TGZ"
  tar -xzf "$ROOTFS_TGZ" -C "$WORK"
else
  ROOTFS_IMG_GZ=$(ls "$OUT"/*rootfs.img.gz 2>/dev/null | head -1 || true)
  test -n "${ROOTFS_IMG_GZ:-}" || { echo "ERROR: no rootfs.tar.gz / rootfs.img.gz produced"; exit 1; }
  echo "source rootfs: $ROOTFS_IMG_GZ (squashfs, extracting)"
  gunzip -c "$ROOTFS_IMG_GZ" > "$WS/build/rootfs.img"
  unsquashfs -f -d "$WORK" "$WS/build/rootfs.img"
fi

cd "$WORK"

echo "=== sanity: base rootfs ==="
ls -la
test -x sbin/init
test -x usr/bin/apk || test -x bin/apk || true

# 1) kernel modules are useless inside a container (and don't match the Android kernel)
rm -rf lib/modules

# 2) debugfs mount breaks Android's webview_zygote when the rootfs runs as a container
sed -i '/grep -q debugfs \/proc\/filesystems/d' etc/init.d/boot
grep -n 'debugfs' etc/init.d/boot || echo "debugfs line removed"

# 3) Android AID groups, root is a member
for grp in 'aid_inet:x:3003:root' 'aid_net_raw:x:3004:root' 'aid_net_admin:x:3005:root'; do
  name=${grp%%:*}
  grep -q "^${name}:" etc/group || echo "$grp" >> etc/group
done
grep -E '^aid_' etc/group

# 4) make sure iptables/ip6tables are the LEGACY flavor (android kernel has no nf_tables)
for pair in "iptables:xtables-legacy-multi" "ip6tables:xtables-legacy-multi" \
            "iptables-save:xtables-legacy-multi" "iptables-restore:xtables-legacy-multi" \
            "ip6tables-save:xtables-legacy-multi" "ip6tables-restore:xtables-legacy-multi"; do
  link=${pair%%:*}; target=${pair##*:}
  if [ -e "usr/sbin/$link" ] && [ ! -L "usr/sbin/$link" ]; then
    rm -f "usr/sbin/$link"
  fi
  if [ ! -e "usr/sbin/$link" ]; then
    ln -sf "$target" "usr/sbin/$link"
    echo "created usr/sbin/$link -> $target"
  fi
done
ls -la usr/sbin/ | grep -E 'iptables|xtables' || true
/sbin/fw3 -q 2>/dev/null || true
ls -la sbin/fw3 etc/config/firewall 2>/dev/null || true

# 5) container network config (wan = eth0 DHCP via Droidspaces NAT, lan = br-lan for VirtualAP / gateway mode)
cat > etc/config/network <<'NET'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'fd00:1234:5678::/48'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth1'

config interface 'wan'
	option device 'eth0'
	option proto 'dhcp'

config interface 'wan6'
	option device 'eth0'
	option proto 'dhcpv6'
	option sourcefilter '0'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.100.1'
	option netmask '255.255.255.0'
	option ip6assign '64'
NET

# 6) dhcp: lan range follows the new lan subnet
if [ -f etc/config/dhcp ]; then
  sed -i "s/option start '100'/option start '10'/; s/option limit '150'/option limit '200'/" etc/config/dhcp || true
fi

# 7) forwarding for gateway mode
mkdir -p etc/sysctl.d
echo 'net.ipv4.ip_forward=1' > etc/sysctl.d/30-droidspaces.conf

# 8) build marker
cat > etc/droidspaces <<'MARK'
iStoreOS 25.12.6 (armsr/armv8) rootfs built by official iStoreOS ImageBuilder on GitHub Actions.
Adapted for Android/Droidspaces containers: fw3 + iptables-legacy (no nf_tables in Android GKI kernels),
/lib/modules removed, Android AID groups added, debugfs mount removed.
Repository: https://github.com/DeepSeek-Dsh-Agent/istoreos-droidspaces-rootfs
MARK

# 9) drop device nodes, keep the (empty) directories
find dev \( -type b -o -type c \) -delete 2>/dev/null || true

echo "=== final sanity ==="
ls -la sbin/init usr/bin/apk etc/config/firewall etc/config/network etc/config/dhcp 2>/dev/null || true
ls sbin/fw3 2>/dev/null; ls -la usr/sbin/iptables usr/sbin/ip6tables 2>/dev/null || true
test ! -d lib/modules && echo "lib/modules absent OK"
grep -E '^aid_inet' etc/group

# 10) repack
cd "$WORK"
OUTFILE="$FINAL_DIR/iStoreOS-$IB_VERSION-Droidspaces-rootfs-aarch64-$(date -u +%Y%m%d).tar.xz"
echo "packing $OUTFILE ..."
XZ_OPT="-T0 -6" tar -cJf "$OUTFILE" --numeric-owner -C "$WORK" .
ls -la "$OUTFILE"
sha256sum "$OUTFILE"
