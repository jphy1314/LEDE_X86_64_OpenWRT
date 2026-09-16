# LEDE_X86_64_OpenWRT

基于 [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) 构建的 **x86_64 OpenWrt/LEDE 固件项目**，主要面向 **Intel Atom D525 / Bonnell** 等低功耗 x86 软路由平台。

项目以 **稳定性、实用性和资源占用** 为核心，在保留 LEDE 原生网络能力的基础上，集成透明代理、DNS、VPN、存储及硬件优化等常用功能，并通过 **GitHub Actions** 实现自动化构建与 Release 发布。

> **Stable · Practical · Lightweight · Automated**

## ✨ Features

### Network & DNS

* Firewall4 / nftables
* IPv4 / IPv6
* TProxy
* BBR
* ipset
* dnsmasq-full
* SmartDNS
* DNSSEC
* Adblock Fast

### Proxy & VPN

* PassWall
* Xray / sing-box
* Shadowsocks / Trojan
* Hysteria / NaiveProxy
* TCPing
* IPSec / StrongSwan
* WireGuard
* L2TP

### Management & Monitoring

* Argon Web UI
* DDNS
* ttyd
* File transfer
* Automatic reboot
* Bandwidth monitoring
* CPUFreq

### Storage & NAS

* EXT4 / Btrfs / XFS / F2FS
* NTFS / FAT
* Samba4
* DiskMan
* Automatic mount
* TRIM
* S.M.A.R.T.

### Hardware Optimization

针对低功耗 x86 平台进行针对性优化，包括：

* Intel Atom Bonnell CPU 编译优化
* CPUFreq
* IRQ Balance
* `ethtool` 网卡 Offload
* 存储 I/O 优化
* TRIM
* S.M.A.R.T.

> 具体功能及最终固件内容以 `D525_x86_64.config`、DIY 脚本、`package-scrub-list.conf` 以及实际 GitHub Actions 构建结果为准。

## ⚙️ Build

项目采用 **GitHub Actions 自动化构建**。

每次构建主要执行以下流程：

```text
Clone LEDE
   ↓
Apply custom feeds
   ↓
Apply DIY configuration
   ↓
Resolve & download dependencies
   ↓
Restore ccache / DL cache
   ↓
Compile firmware
   ↓
Upload firmware artifacts
   ↓
Create GitHub Release
   ↓
Clean up old workflow runs
```

构建过程中使用 `ccache` 与下载缓存减少重复编译和依赖下载时间。

### Core Build Files

```text
D525_x86_64.config
diy-part1.sh
diy-part2.sh
package-scrub-list.conf
.github/workflows/Build LEDE Latest.yml
```

固件版本标签根据构建日期自动生成，例如：

```text
R26.09.16
```

## 🖥️ Default Configuration

首次启动后的基础配置：

```text
LAN
  Address: 192.168.5.1/24
  Hostname: LEDE

Firewall
  IPSec:     UDP 500 / 4500
  WireGuard: UDP 51820

PassWall
  SOCKS:     Enabled
  TCP/UDP:   Proxy enabled
```

以上为项目默认配置及预置规则。

首次启动后，请根据实际网络环境配置：

* WAN / PPPoE
* IPv6
* DNS / SmartDNS
* DDNS
* IPSec / WireGuard
* PassWall 节点及代理策略

## 🎯 Target Platform

本项目重点针对：

* Intel Atom D525
* Intel Bonnell 系列低功耗 CPU
* x86_64 软路由
* 老旧低功耗 PC / 工控机
* 多网口软路由设备

编译参数针对 Bonnell 架构进行优化：

```text
-O2
-pipe
-march=bonnell
-mtune=bonnell
-fomit-frame-pointer
```

项目不以追求最大软件包数量为目标，而是优先考虑 **老旧硬件上的稳定运行、资源占用和实际使用价值**。

## 📁 Project Structure

```text
.
├── D525_x86_64.config
├── diy-part1.sh
├── diy-part2.sh
├── package-scrub-list.conf
└── .github/
    └── workflows/
        └── Build LEDE Latest.yml
```

其中：

| 文件                        | 作用                     |
| ------------------------- | ---------------------- |
| `D525_x86_64.config`      | 固件目标及软件包配置             |
| `diy-part1.sh`            | feeds、软件包及源码相关调整       |
| `diy-part2.sh`            | 系统配置、网络、防火墙、存储及硬件优化    |
| `package-scrub-list.conf` | 构建过程中需要清理或排除的软件包       |
| `Build LEDE Latest.yml`   | GitHub Actions 自动化构建流程 |

## ⚠️ Notes

本项目属于个人定制构建，**不保证适用于所有 x86_64 设备**。

实际固件功能、软件包版本及最终配置，以对应构建提交中的：

```text
D525_x86_64.config
diy-part1.sh
diy-part2.sh
package-scrub-list.conf
.github/workflows/Build LEDE Latest.yml
```

以及 GitHub Actions 的实际构建结果为准。

使用前请根据自身硬件和网络环境进行测试，尤其是 **IPv6、SmartDNS、PassWall、IPSec 和 WireGuard** 等功能。

## 🙏 Thanks

感谢以下开源项目、平台及所有贡献者：

* [GitHub](https://github.com) — 代码托管与 GitHub Actions
* [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede) — LEDE 源码
* [OpenWrt](https://github.com/openwrt/openwrt) — OpenWrt 项目
* [Openwrt-Passwall](https://github.com/Openwrt-Passwall) — PassWall
* [SmartDNS](https://github.com/pymumu/smartdns) — SmartDNS
* [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon) — Argon 主题
* StrongSwan
* WireGuard
* 以及所有参与开源项目建设的贡献者

**感谢开源，让技术自由流动。**

如果本项目对你有所帮助，欢迎 ⭐ **Star / Fork / Issue**。
