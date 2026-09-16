# LEDE_X86_64_OpenWRT

基于 **LEDE / coolsnowwolf** 的 x86_64 固件构建项目，针对 **Intel Atom D525 / Bonnell** 等低功耗软路由平台进行优化。

> **稳定 · 实用 · 轻量 · GitHub Actions 自动构建**

## ✨ Features

* **基础网络**：Firewall4 / nftables / IPv6 / TProxy / BBR / ipset
* **智能解析**：SmartDNS / dnsmasq-full / DNSSEC / Adblock Fast
* **透明代理**：PassWall / Xray / sing-box / Shadowsocks / Trojan / Hysteria / NaiveProxy / TCPing
* **VPN 共存**：IPSec / StrongSwan / WireGuard / L2TP
* **管理与监控**：Argon / DDNS / ttyd / 文件传输 / 自动重启 / 带宽监控 / CPUFreq
* **存储与 NAS**：EXT4 / Btrfs / XFS / F2FS / NTFS / FAT / Samba4 / DiskMan / 自动挂载 / TRIM
* **硬件优化**：Bonnell CPU 优化 / CPUFreq / IRQ Balance / ethtool 网卡 Offload / S.M.A.R.T.

## ⚙️ Build

通过 **GitHub Actions** 手动触发拉取 LEDE master，并完成自定义 feeds、依赖下载、ccache/dl 缓存、固件编译、Release 发布和旧运行记录清理。

主要文件：

```text
D525_x86_64.config
diy-part1.sh
diy-part2.sh
package-scrub-list.conf
.github/workflows/Build LEDE Latest.yml
```

版本标签由构建日期生成，例如 `R26.09.16`。

## 🖥️ Default

```text
LAN: 192.168.5.1
Hostname: LEDE
Firewall:
  IPSec UDP 500 / 4500
  WireGuard UDP 51820
PassWall:
  SOCKS enabled
  TCP / UDP proxy mode
```

首次启动后按实际网络环境配置 WAN、DNS、VPN 和代理节点。

> 本项目面向老旧低功耗 x86 平台；实际固件内容以 `D525_x86_64.config`、DIY 脚本、`package-scrub-list.conf` 和 GitHub Actions 构建结果为准。

## 🙏 Thanks

感谢以下开源项目、平台及所有贡献者：

* [GitHub](https://github.com) — 代码托管与 GitHub Actions 自动构建
* [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
* [OpenWrt](https://github.com/openwrt/openwrt)
* [Openwrt-Passwall](https://github.com/Openwrt-Passwall)
* [SmartDNS](https://github.com/pymumu/smartdns)
* [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)
* StrongSwan / WireGuard
* 以及所有开源贡献者

**感谢开源，让技术自由流动。**

如果本项目对你有所帮助，欢迎 ⭐ **Star / Fork / Issue**。
