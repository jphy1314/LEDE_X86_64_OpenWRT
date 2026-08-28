# LEDE_X86_64_OpenWRT

A customized **OpenWrt / LEDE x86_64 firmware build repository** based on the **coolsnowwolf/lede** project.

This project provides an automated GitHub Actions build environment for x86_64 soft routers, integrating commonly used network services, proxy components, DNS optimization, security features, network storage, and hardware performance tuning.

---

# Project Highlights

* Based on the latest LEDE source code
* Automated firmware compilation with GitHub Actions (Ubuntu 24.04 environment)
* Designed for x86_64 soft router platforms
* Optimized for low-power Intel Atom Bonnell platforms
* Complete PassWall dependency & multi-protocol environment
* Integrated SmartDNS high-performance DNS service
* Integrated Argon LuCI theme & modern UI utilities
* IPv4 / IPv6 network dual-stack support
* Storage, filesystem, and SSD optimization features

---

# Supported Hardware

Primary test platform:

| Item         | Specification                   |
| ------------ | ------------------------------- |
| CPU          | Intel Atom D525                 |
| Architecture | x86_64                          |
| Network      | Gigabit soft router environment |
| Storage      | SATA / SSD / USB storage        |
| System       | OpenWrt / LEDE                  |

CPU optimization settings (`.config`):

```bash
-O2 -pipe -march=bonnell -mtune=bonnell -fomit-frame-pointer
```

Optimized specifically for Intel Atom Bonnell architecture.

---

# Included Features

## Proxy & Network Acceleration

* PassWall (with Nftables & Iptables transparent proxy support)
* Xray & Sing-box
* Shadowsocks-Rust & Libev
* Hysteria & NaiveProxy & Tuic
* TCP / UDP forwarding support
* Regional routing rules & geo data

---

## DNS Services & Ad Blocking

* SmartDNS high-performance resolver
* dnsmasq-full (with DNSSEC & nftset support)
* adblock-fast (integrated ad blocking)

---

## Network Features & VPN

* IPv6 helper & dual-stack routing
* WireGuard VPN (kernel mode)
* IPsec VPN (strongSwan with Xauth / libipsec)
* Dynamic DNS (DDNS)
* TCP BBR congestion control
* Network performance & IRQ optimizations

---

## System Management & Themes

* LuCI Web administration interface
* Argon theme (`luci-theme-argon`) & Argon Config
* CPU frequency management (`luci-app-cpufreq`)
* Autoreboot & DiskMan partition management
* ttyd terminal web access
* UnblockNeteaseMusic

---

## Storage & File Sharing

* Filesystem support: EXT4, Btrfs, XFS, VFAT, NTFS (ntfs3), F2FS
* Block device & mount management (`block-mount`)
* SSD TRIM optimization (`fstrim`, `smartmontools`)
* Samba4 Network file sharing (`luci-app-samba4`)
* USB printer server & storage support

---

# Build Environment

This project uses GitHub Actions for automated compilation:

* Runner OS: Ubuntu 24.04
* Upstream: OpenWrt / LEDE Master branch
* Acceleration: `ccache` caching strategy + parallel source pre-downloads

---

# Build Process

## 1. Clone Repository

```bash
git clone https://github.com/jphy1314/LEDE_X86_64_OpenWRT.git
cd LEDE_X86_64_OpenWRT
```

---

## 2. Customize Configuration

Main configuration files:

```text
.config                # Main kernel & package configuration (D525 optimized)
diy-part1.sh           # Feeds source customization & plugin clones
diy-part2.sh           # Custom patches & IP/hostname adjustments
.github/workflows/     # GitHub Actions workflow yml files
```

---

## 3. Start GitHub Actions Build

Open:

```text
GitHub Repository
 → Actions
 → Build LEDE Latest (or Build LEDE)
 → Run workflow
```

The firmware will be compiled automatically with full error log upload on failure and automatic Release publishing.

---

# Firmware Output

After successful compilation, download the firmware from GitHub Actions artifacts or Releases:

* `openwrt-x86-64-generic-squashfs-combined.img.gz`

Supported installation environments:

* Bare metal x86_64 devices
* VMware / ESXi / Proxmox VE (PVE)
* UEFI boot systems

---

# Repository Structure

```text
.
├── .github
│   └── workflows
│       ├── Build LEDE.yml
│       └── Build LEDE Latest.yml
├── D525_x86_64.config
├── diy-part1.sh
├── diy-part2.sh
├── LICENSE
└── README.md
```

---

# Notes

1. This is a personal customized firmware project tailored for Intel Atom D525 soft routers.
2. It is recommended to reset configurations after the first boot before production deployment.
3. VPN, proxy, and network acceleration features should be configured according to local laws and regulations.
4. Firmware features and package feeds may change as upstream sources update.

---

# Credits

Special thanks to the following open-source projects:

* coolsnowwolf/lede
* OpenWrt Project
* PassWall development team
* SmartDNS development team
* Argon Theme development team

---

# License

This project follows the licenses of the original open-source projects.
