# LEDE_X86_64_OpenWRT

基于 **LEDE（coolsnowwolf）** 构建的 x86_64 OpenWrt 固件项目，针对 **Intel Atom D525（Bonnell）** 等低功耗软路由平台进行优化。

> 稳定、实用、轻量；GitHub Actions 手动触发构建。

## ✨ Features

* **基础网络**：Firewall4 / nftables / IPv6 / TProxy / BBR / ipset
* **智能解析**：SmartDNS / dnsmasq-full / DNSSEC / Adblock Fast
* **透明代理**：PassWall / Xray / sing-box / Shadowsocks / Trojan / Hysteria / NaiveProxy / TCPing
* **VPN**：IPSec / StrongSwan / WireGuard / L2TP
* **管理与监控**：Argon / DDNS / ttyd / 文件传输 / 自动重启 / 带宽监控 / CPUFreq
* **存储与 NAS**：EXT4 / Btrfs / XFS / F2FS / NTFS / FAT / Samba4 / DiskMan / 存储优化 / 定时 TRIM
* **硬件优化**：Bonnell CPU 优化 / CPUFreq / IRQ Balance / ethtool 网卡 Offload / S.M.A.R.T.

## ⚙️ Build

通过 **GitHub Actions** 手动触发构建：拉取 LEDE Master 源码，完成自定义 Feeds、依赖下载、ccache / dl 缓存、固件编译、Release 发布及旧运行记录清理。

默认采用针对 **Intel Atom D525（Bonnell）** 的优化编译参数，并结合缓存机制减少重复编译时间。

主要文件：

```text
D525_x86_64.config
diy-part1.sh
diy-part2.sh
package-scrub-list.conf
.github/workflows/Build LEDE Latest.yml
```

版本标签由构建日期自动生成，例如：

```text
R26.09.16
```

## 🖥️ Default

```text
LAN: 192.168.5.1
Hostname: LEDE

Firewall:
  IPSec UDP 500 / 4500
  WireGuard UDP 51820

PassWall:
  SOCKS Enabled
  TCP / UDP Proxy Mode
```

首次启动后，请根据实际网络环境配置：

* WAN / PPPoE
* IPv6
* DNS / SmartDNS
* DDNS
* IPSec / WireGuard
* PassWall 节点及代理策略

## 🎯 Target Platform

本项目主要面向以下设备：

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

项目以稳定运行、资源占用和长期使用体验为优先目标，不以堆叠软件包数量为导向。

## 📁 Project Structure

```text
.
├── D525_x86_64.config
├── diy-part1.sh
├── diy-part2.sh
├── package-scrub-list.conf
└── .github
    └── workflows
        └── Build LEDE Latest.yml
```

| 文件                        | 说明                  |
| ------------------------- | ------------------- |
| `D525_x86_64.config`      | 固件目标及软件包配置          |
| `diy-part1.sh`            | Feeds、软件包及源码相关调整    |
| `diy-part2.sh`            | 系统配置、网络、防火墙、存储及硬件优化 |
| `package-scrub-list.conf` | 构建过程中清理或排除的软件包      |
| `Build LEDE Latest.yml`   | GitHub Actions 构建流程 |

## ⚠️ Notes

本项目属于个人定制固件，不保证适用于所有 x86_64 设备。

实际固件功能、软件包版本及最终配置，以对应构建提交中的：

```text
D525_x86_64.config
diy-part1.sh
diy-part2.sh
package-scrub-list.conf
.github/workflows/Build LEDE Latest.yml
```

以及 GitHub Actions 实际构建结果为准。

使用前建议根据自身硬件及网络环境进行测试，尤其是 IPv6、SmartDNS、PassWall、IPSec 和 WireGuard 等相关功能。

## 🙏 Thanks

感谢以下开源项目、平台及所有贡献者：

* [GitHub](https://github.com) — 代码托管与 GitHub Actions
* [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
* [OpenWrt](https://github.com/openwrt/openwrt)
* [OpenWrt-PassWall](https://github.com/OpenWrt-PassWall)
* [SmartDNS](https://github.com/pymumu/smartdns)
* [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)
* StrongSwan
* WireGuard
* 以及所有开源贡献者

**感谢开源，让技术自由流动。**

如果本项目对你有所帮助，欢迎 ⭐ **Star / Fork / Issue**。
