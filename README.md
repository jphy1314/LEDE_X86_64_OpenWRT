# LEDE_X86_64_OpenWRT

基于 **LEDE** 的 x86_64 固件构建项目，针对 **Intel Atom D525 / Bonnell** 等低功耗平台进行优化。

> **稳定 · 实用 · 轻量 · 自动构建**

## ✨ Features

* **网络**：Firewall4 / nftables / IPv6 / TProxy / BBR
* **代理**：PassWall / Xray / sing-box / Shadowsocks / Trojan / Hysteria / NaiveProxy / TUIC
* **DNS**：SmartDNS / dnsmasq-full / AdBlock
* **VPN**：IPSec / StrongSwan / WireGuard / L2TP
* **系统**：Argon / DDNS / ttyd / USB Printer / 文件传输
* **存储**：EXT4 / Btrfs / XFS / F2FS / NTFS / Samba4 / 自动挂载 / TRIM
* **优化**：Bonnell CPU 优化 / CPUFreq / IRQ Balance / 网卡 Offload

## ⚙️ Build

通过 **GitHub Actions** 自动拉取 LEDE master 并完成配置、依赖下载、缓存及编译。

主要配置：

```text
D525_x86_64.config
diy-part1.sh
diy-part2.sh
.github/workflows/Build LEDE Latest.yml
```

## 🖥️ Default

```text
LAN: 192.168.5.1
```

首次启动后按实际网络环境配置相关服务。

> 本项目面向老旧低功耗 x86 平台，实际固件内容以 `.config`、DIY 脚本及构建结果为准。
## 🙏 Thanks

感谢以下开源项目及所有贡献者：

* [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede?utm_source=chatgpt.com)
* [OpenWrt](https://github.com/openwrt/openwrt?utm_source=chatgpt.com)
* [OpenWrt-Passwall](https://github.com/Openwrt-Passwall?utm_source=chatgpt.com)
* [SmartDNS](https://github.com/pymumu/smartdns?utm_source=chatgpt.com)
* [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon?utm_source=chatgpt.com)
* StrongSwan / WireGuard
* 以及所有开源贡献者

**感谢开源，让技术自由流动。**

如果本项目对你有所帮助，欢迎 ⭐ **Star / Fork / Issue**。
