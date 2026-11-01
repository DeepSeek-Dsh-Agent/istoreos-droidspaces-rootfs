#!/usr/bin/env python3
"""Generate rootfs.json in the format used by Droidspaces/Droidspaces-rootfs-builder."""
import argparse
import json


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--download-url", required=True)
    ap.add_argument("--sha256", required=True)
    ap.add_argument("--size", required=True, type=int)
    ap.add_argument("--version", required=True)
    ap.add_argument("--build-date", required=True)
    ap.add_argument("--file", default="iStoreOS-25.12.6-Minimal")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    entry = {
        "author": "DeepSeek-Dsh-Agent",
        "name": "iStoreOS 25.12.6 - Minimal (iptables-legacy)",
        "distro": "iStoreOS",
        "description": (
            "iStoreOS 25.12.6 (OpenWrt-based) aarch64 rootfs for Android/Droidspaces containers, "
            "built from the official iStoreOS ImageBuilder: nftables/firewall4 stripped out in favor "
            "of fw3 + iptables-legacy (Android GKI kernels have no CONFIG_NF_TABLES), kernel modules "
            "removed, Android AID groups added, wan=eth0 DHCP / lan=br-lan 192.168.100.1/24."
        ),
        "architecture": "aarch64",
        "file": args.file,
        "download_url": args.download_url,
        "sha256": args.sha256,
        "size_bytes": args.size,
        "version": args.version,
        "build_date": args.build_date,
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump([entry], fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
