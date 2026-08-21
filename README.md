# LEDE_X86_64_OpenWRT

A customized **OpenWrt / LEDE x86_64 firmware build repository** based on the **coolsnowwolf/lede** project.

This project provides an automated GitHub Actions build environment for x86_64 soft routers, integrating commonly used network services, proxy components, DNS optimization, security features, and hardware performance tuning.

---

# Project Highlights

* Based on the latest LEDE source code
* Automated firmware compilation with GitHub Actions
* Designed for x86_64 soft router platforms
* Optimized for low-power Intel platforms
* Complete PassWall dependency environment
* Integrated SmartDNS high-performance DNS service
* Integrated Argon LuCI theme
* IPv4 / IPv6 network support
* Storage and SSD optimization features

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

CPU optimization settings:

```bash
-O2 -pipe -march=bonnell -mtune=bonnell -fomit-frame-pointer
```

Optimized specifically for Intel Atom Bonnell architecture.

---

# Included Features

## Proxy & Network Acceleration

* PassWall
* Xray
* Sing-box
* TCP / UDP forwarding support
* Regional routing rules
* Proxy traffic management

---

## DNS Services

* SmartDNS
* DNS cache optimization
* Smart DNS forwarding
* DNSSEC support
* dnsmasq-full

---

## Network Features

* IPv6 support
* WireGuard VPN
* IPsec VPN
* Dynamic DNS (DDNS)
* TCP BBR congestion control
* Network performance optimization

---

## System Management

* LuCI Web administration interface
* Argon theme
* CPU frequency management
* IRQ optimization
* Package management

---

## Storage Support

* EXT4 filesystem
* Btrfs filesystem
* XFS filesystem
* NVMe storage
* USB storage support
* SSD TRIM optimization

---

## Additional Services

* USB printer server
* KMS service
* Network diagnostic tools

---

# Build Environment

This project uses GitHub Actions for automated compilation.

Environment:

* Ubuntu 24.04 Runner
* OpenWrt / LEDE Master branch
* ccache compilation acceleration
* Automated firmware artifact upload

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
.config
diy-part1.sh
diy-part2.sh
.github/workflows/*.yml
```

Modify these files according to your hardware and feature requirements.

---

## 3. Start GitHub Actions Build

Open:

```text
GitHub Repository
 → Actions
 → Build LEDE Latest TEST
 → Run workflow
```

The firmware will be compiled automatically.

---

# Firmware Output

After successful compilation, download the firmware from GitHub Actions artifacts:

```text
openwrt-x86-64-generic-squashfs-combined.img.gz
```

Supported installation environments:

* Bare metal x86_64 devices
* VMware
* ESXi
* Proxmox VE (PVE)
* UEFI boot systems

---

# Repository Structure

```text
.
├── .github
│   └── workflows
│       └── build.yml
│
├── diy-part1.sh
├── diy-part2.sh
├── .config
└── README.md
```

---

# Notes

1. This is a personal customized firmware project and may not work perfectly on every device.
2. It is recommended to reset configurations after the first boot before production deployment.
3. VPN, proxy, and network acceleration features should be configured according to local laws and regulations.
4. Firmware features may change as upstream sources are updated.

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

For personal learning, research, and soft router deployment purposes only.
