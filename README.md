# iStoreOS 25.12.6 arm64 rootfs for Droidspaces

iStoreOS **25.12.6** (`armsr/armv8`, aarch64) container rootfs built with the
**official iStoreOS ImageBuilder** on GitHub Actions, published as a
[Droidspaces](https://github.com/Droidspaces) custom repository.

## What is this

iStoreOS is an OpenWrt-based router firmware. This repository builds its
`armsr/armv8` root filesystem and adapts it so it can run inside
**Droidspaces** on Android phones:

- **fw3 (`firewall`) + `iptables-legacy`** instead of `firewall4` / nftables.
  Android GKI kernels are built **without `CONFIG_NF_TABLES`**, so anything
  nftables based fails; the legacy iptables backend works (`CONFIG_IP_NF_IPTABLES=y`).
- `/lib/modules` removed: the rootfs is not booted with its own kernel, and its
  6.12 modules don't match the Android kernel.
- `debugfs` mount line removed from `/etc/init.d/boot` (it breaks Android's
  `webview_zygote` inside containers).
- Android AID groups added to `/etc/group` (`aid_inet`, `aid_net_raw`,
  `aid_net_admin`, all with `root` as member).
- Container network defaults:
  - `wan` = `eth0` DHCP (Droidspaces NAT)
  - `wan6` = `eth0` DHCPv6, `sourcefilter 0` (Android kernels lack `IPV6_SUBTREES`)
  - `lan` = `br-lan` (`eth1`, VirtualAP / gateway mode) static `192.168.100.1/24`
  - `net.ipv4.ip_forward=1`

## How to install (Droidspaces App)

1. Open the Droidspaces App → **Settings** (gear icon) → **Custom repository**.
2. Enter a name, e.g. `iStoreOS`, and this URL:

   ```
   https://raw.githubusercontent.com/DeepSeek-Dsh-Agent/istoreos-droidspaces-rootfs/main/rootfs.json
   ```

3. The catalog then shows **iStoreOS 25.12.6 - Minimal (iptables-legacy)** —
   tap install and let Droidspaces download the rootfs from
   [Releases](../../releases).

You can also download the `.tar.xz` from the latest release manually and import
it as a custom rootfs.

## Build information

- ImageBuilder: `fw.koolcenter.com/iStoreOS/ib/armsr/istoreos-imagebuilder-armsr-armv8.Linux-x86_64.tar.zst`
  (`VERSION_NUMBER=25.12.6`)
- Package set: the official iStoreOS armsr manifest (1018 packages), with
  nftables/firewall4 packages removed and `firewall` (fw3) +
  `iptables-zz-legacy` + `ip6tables-zz-legacy` added. The missing fw3/legacy
  iptables packages are taken from the matching official OpenWrt 25.12.6 feeds.
- Workflow: [`.github/workflows/build.yml`](.github/workflows/build.yml),
  manual dispatch only (`workflow_dispatch`). It builds the rootfs, post-processes
  it, creates the release, uploads the asset and commits `rootfs.json`.
- Release assets are named
  `iStoreOS-<ver>-Droidspaces-rootfs-aarch64-<YYYYMMDD>-b<batch>.tar.xz`, where
  `<batch>` is the GitHub Actions run number (fallback: `HHMM` for local runs).
  Same-day rebuilds therefore get a distinct `-bN` suffix instead of colliding
  with an earlier `<date>.tar.xz`; the batch is also mirrored in the
  `rootfs.json` `version` tag and `file` field, so the Droidspaces download name
  stays unique too. The release tag is `v<YYYYMMDD>-<HHMMSS>-b<batch>`.

## Verification (what is checked after build)

Every release artifact is re-checked by the workflow and locally:

- `/sbin/init`, `/usr/bin/apk`, `/etc/config/firewall` present
- `/usr/sbin/iptables` (and `ip6tables`, `-save`/`-restore`) point to the legacy
  multi-call binary, and no `firewall4`/`nft` binaries remain
- `/etc/group` contains the Android AID groups
- `/etc/init.d/boot` has no debugfs mount; `/lib/modules` is absent
- `/run` is a real directory (not a symlink; Droidspaces mounts a tmpfs on it
  before init runs) and `/tmp/run` exists
- `rootfs.json` is valid JSON and its `sha256`/`size_bytes` match the release asset

## Notes / limitations

- iptables **legacy** only: `iptables-nft`, `nft`, `firewall4` are not included.
  LuCI's firewall page still works because it talks to `fw3` via UCI.
- `nftables-json` is pulled in only as a build dependency of `dnsmasq-full`
  (its nftset support); the `nft` userspace binary and libnftables are stripped
  from the final rootfs because the Android kernel can't use them.
- Kernel modules are not shipped, so kernel-feature packages (e.g. `kmod-*`)
  can't be loaded — everything userspace still works.
- UPnP is kept as `miniupnpd-nftables` (package name only; not started by default).
  If you need UPnP with iptables, use an external `miniupnpd-iptables` build.

---

[![](https://img.shields.io/badge/powered_by-dsh-4D6BFE?style=flat-square&logo=deepseek&logoColor=white)](https://github.com/deepseek-ai/deepseek-harness)
