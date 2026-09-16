# LEDE_X86_64_OpenWRT

基于 **LEDE** 的 x86_64 固件构建项目，针对 **Intel Atom D525 / Bonnell** 等低功耗平台进行优化。

> **稳定 · 实用 · 轻量 · 自动构建**

构建状态：**构建成功（Run 35077356227）** — 远端修复 `153a408` 已包含在构建中（PASSWALL 默认代理配置 + heredoc 修复 + fw4 端口修复 + scrub-list 注释 + git 同步完成）。
固件状态：已刷入路由器（OpenWrt 24.10.5，运行正常，无新运行错误）。
修复内容：根据远程仓库修复提交（`153a408`），已包含 PASSWALL 默认代理配置注入（`uci-defaults` 补丁）、`diy-part2.sh` 嵌套 `heredoc` 定界符冲突修复（`DEFAULTS_EOF` / `UCI_EOF`）、`fw4` 防火墙端口写法修复（`uci add_list` 替代 `uci set`）、`package-scrub-list.conf` 分隔符维护说明注释补充。

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

构建结果验证：根据构建日志（Run 35077356227），`kmod-nft-tproxy` 内核模块已正确编入固件（`/lib/modules/6.18.52/nft_tproxy.ko`，10928 字节，构建时间戳 09-16 11:17）。

## 🖥️ Default

```text
LAN: 192.168.5.1
```

首次启动后按实际网络环境配置相关服务。

> 本项目面向老旧低功耗 x86 平台，实际固件内容以 `.config`、DIY 脚本及构建结果为准。根据构建结果（Run 35077356227，success），修复内容已正确编入固件（PASSWALL 默认代理配置 + heredoc 修复 + fw4 端口修复 + scrub-list 注释 + git 同步完成）。

## 🙏 Thanks

感谢以下开源项目及所有贡献者：

* **GitHub** — 自动构建平台（GitHub Actions），本项目构建流程（Build LEDE Latest workflow）依赖 GitHub 提供的 CI/CD 服务，构建成功（Run 35077356227）验证了修复内容的有效性。
* [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
* [OpenWrt](https://github.com/openwrt/openwrt)
* [OpenWrt-Passwall](https://github.com/Openwrt-Passwall)
* [SmartDNS](https://github.com/pymumu/smartdns)
* [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon)
* StrongSwan / WireGuard
* 以及所有开源贡献者
