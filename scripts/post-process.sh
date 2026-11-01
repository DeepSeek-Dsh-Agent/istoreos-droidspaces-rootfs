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

# 4b) nftables-json comes in only as a build dependency of dnsmasq-full (nftset support).
# nft cannot work on Android kernels (no CONFIG_NF_TABLES), so strip the nft userspace.
rm -f usr/sbin/nft usr/sbin/nftables
rm -f usr/lib/libnftables.so*
rm -rf usr/share/nftables.d
rm -f etc/modules.d/nft-core
echo "nft userspace stripped: $(command -v nft >/dev/null 2>&1 && echo nft-present || echo nft-absent)"

# 4c) Droidspaces mkdir()s proc/sys/run/tmp and mounts a tmpfs on each before
# any init script runs. iStoreOS/OpenWrt images ship /run as a symlink to
# /tmp/run, and /tmp/run only appears when /etc/init.d/boot runs -- too late:
# mount("tmpfs", "run") resolves the symlink to a missing target and fails with
# ENOENT ("Failed to mount tmpfs at /run: No such file or directory").
# The official Droidspaces OpenWrt rootfs ships no /run entry at all. Do the
# same: a real, empty directory, plus /tmp/run for anything that expects it.
if [ -L run ]; then rm -f run; fi
mkdir -p -m 0755 run tmp/run
test -d run && test ! -L run && echo "/run is a real directory OK"

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

# 5b) iStoreOS' first-boot NIC rescan (/usr/libexec/rescan_nic.sh, called from
# 09_istoreos) rewrites /etc/config/network from board.json: a container with a
# single eth0 gets lan=br-lan(eth0) dhcp and our wan/wan6 are deleted. Keep the
# packaged layout (wan=eth0 DHCP, lan=br-lan/eth1 for Droidspaces gateway mode).
cat > usr/libexec/rescan_nic.sh <<'RESCAN'
#!/bin/sh
# Disabled by istoreos-droidspaces-rootfs: keep the packaged network config.
exit 0
RESCAN
chmod 755 usr/libexec/rescan_nic.sh

# 5c) Droidspaces NAT subnet may reach router services (LuCI/SSH/ping).
cat >> etc/config/firewall <<'FWRULE'

config rule
	option name		Allow-Droidspaces-NAT
	option src		wan
	option src_ip		172.28.0.0/16
	option proto		tcp udp
	option target		ACCEPT

config rule
	option name		Allow-Droidspaces-Ping
	option src		wan
	option src_ip		172.28.0.0/16
	option proto		icmp
	option icmp_type	echo-request
	option target		ACCEPT
FWRULE

# 6) dhcp: lan range follows the new lan subnet
if [ -f etc/config/dhcp ]; then
  sed -i -E 's/(option[[:space:]]+start)[[:space:]]+100/\1 10/; s/(option[[:space:]]+limit)[[:space:]]+150/\1 200/' etc/config/dhcp || true
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

# 8b) Network bootstrap / DHCP safety net.
# Observed in Droidspaces: netifd runs but never configures eth0 (the iStoreOS
# first-boot rescan had rewritten /etc/config/network); the container then boots
# with no IPv4 at all. This rcS script runs after the network service and makes
# sure eth0 ends up with an address:
#   netifd DHCP -> direct udhcpc -> static NAT IP from Droidspaces -> 172.28.1.1
cat > usr/sbin/droidspaces-net <<'NETBOOT'
#!/bin/sh
# Make sure eth0 has an IPv4 address inside a Droidspaces container.
GW=172.28.0.1
LOG=/tmp/droidspaces-net.log

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

has_ip() {
	ip -4 addr show 2>/dev/null | grep -q 'inet 172\.28\.'
}

ensuredns() {
	mkdir -p /tmp/resolv.conf.d
	printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /tmp/resolv.conf.d/resolv.conf.auto
	ln -sf /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf
}

allow_fw() {
	iptables -C INPUT -i eth0 -p tcp --dport 80 -j ACCEPT 2>/dev/null ||
		iptables -I INPUT -i eth0 -p tcp --dport 80 -j ACCEPT 2>/dev/null
	iptables -C INPUT -i eth0 -p tcp --dport 22 -j ACCEPT 2>/dev/null ||
		iptables -I INPUT -i eth0 -p tcp --dport 22 -j ACCEPT 2>/dev/null
}

log "start; interfaces: $(ip -4 -o addr show 2>/dev/null | tr '\n' '|')"
i=0
while [ $i -lt 12 ]; do
	if has_ip; then
		log "netifd/DHCP already configured an address"
		allow_fw; ensuredns; exit 0
	fi
	i=$((i + 1)); sleep 1
done

ip link set eth0 up 2>/dev/null
log "no IPv4 after 12s, trying direct udhcpc on eth0"
udhcpc -i eth0 -f -t 4 -T 2 -s /usr/share/udhcpc/default.script \
	-p /tmp/udhcpc-eth0.pid >>"$LOG" 2>&1
sleep 1
if has_ip; then
	log "direct udhcpc got a lease"
	allow_fw; ensuredns; exit 0
fi

# Droidspaces persists the resolved NAT IP in /run/droidspaces/container.config
IP=$(awk -F= '/^static_nat_ip=/{print $2; exit}' /run/droidspaces/container.config 2>/dev/null)
[ -z "$IP" ] && IP=172.28.1.1
log "DHCP unavailable, applying static $IP/16 via $GW"
ip addr add "$IP/16" dev eth0 2>/dev/null
ip route add default via "$GW" dev eth0 2>/dev/null
allow_fw
ensuredns
log "done; eth0: $(ip -4 -o addr show dev eth0 2>/dev/null)"
NETBOOT
chmod 755 usr/sbin/droidspaces-net

cat > etc/init.d/droidspaces-net <<'NETINIT'
#!/bin/sh /etc/rc.common
START=99
start() {
	( /usr/sbin/droidspaces-net >/tmp/droidspaces-net.log 2>&1 ) &
}
NETINIT
chmod 755 etc/init.d/droidspaces-net
ln -sf ../init.d/droidspaces-net etc/rc.d/S99droidspaces-net

# 9) drop device nodes, keep the (empty) directories
find dev \( -type b -o -type c \) -delete 2>/dev/null || true

echo "=== final sanity ==="
ls -la sbin/init usr/bin/apk etc/config/firewall etc/config/network etc/config/dhcp 2>/dev/null || true
ls sbin/fw3 2>/dev/null; ls -la usr/sbin/iptables usr/sbin/ip6tables 2>/dev/null || true
test ! -d lib/modules && echo "lib/modules absent OK"
grep -E '^aid_inet' etc/group

# hard checks: these break container boot / firewall on Android, never ship them
[ -d run ] && [ ! -L run ] || { echo "ERROR: /run must be a real directory (Droidspaces mounts a tmpfs on it)"; exit 1; }
[ -d tmp/run ] || { echo "ERROR: /tmp/run missing"; exit 1; }
[ ! -e usr/sbin/nft ] || { echo "ERROR: nft userspace still present"; exit 1; }
[ ! -e sbin/fw4 ] || { echo "ERROR: firewall4 still present"; exit 1; }
[ -x usr/sbin/droidspaces-net ] || { echo "ERROR: droidspaces-net helper missing"; exit 1; }
[ -x etc/init.d/droidspaces-net ] || { echo "ERROR: droidspaces-net init missing"; exit 1; }
[ -L etc/rc.d/S99droidspaces-net ] || { echo "ERROR: droidspaces-net not enabled"; exit 1; }
echo "/run: $(ls -ld run | awk '{print $1}')  tmp/run: $(ls -ld tmp/run | awk '{print $1}')"

# 10) repack
# Name: iStoreOS-<ver>-Droidspaces-rootfs-aarch64-<YYYYMMDD>-b<batch>.tar.xz
# The batch (= GitHub run number, or HHMM locally) keeps rebuilds of the same
# day distinguishable, instead of several identical "<date>.tar.xz" files.
cd "$WORK"
BDATE=$(date -u +%Y%m%d)
BATCH=${GITHUB_RUN_NUMBER:-$(date -u +%H%M)}
BASENAME="iStoreOS-$IB_VERSION-Droidspaces-rootfs-aarch64-$BDATE-b$BATCH"
OUTFILE="$FINAL_DIR/$BASENAME.tar.xz"
echo "$BASENAME" > "$FINAL_DIR/asset_name.txt"
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "ASSET_BASENAME=$BASENAME" >> "$GITHUB_ENV"
  echo "BUILD_BATCH=$BATCH" >> "$GITHUB_ENV"
fi
echo "packing $OUTFILE ..."
# CI runners unpack as uid 1001; force root:root in the archive headers so the
# rootfs matches every other Droidspaces rootfs tarball (0/0).
XZ_OPT="-T0 -6" tar -cJf "$OUTFILE" --numeric-owner --owner=0 --group=0 -C "$WORK" .
ls -la "$OUTFILE"
sha256sum "$OUTFILE"
