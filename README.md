# LEDE_X86_64_OpenWRT

基于 [coolsnoowolf/lede](https://github.com/coolsnoowolf/lede) 的 **x86_64 软路由固件构建仓库**，面向 Intel Atom D525 / Bonnell 级别旧平台优化。

仓库本身不是完整 OpenWrt 源码，而是用于驱动 GitHub Actions 编译流程的配置文件集合：主配置、feeds 调整脚本、LuCI/网络/VPN/存储初始化脚本和 GitHub Actions workflow。编译时 workflow 会拉取 LEDE 上游源码，再应用本仓库中的配置。

---

## 主要固件组件

### 网络与防火墙

- `firewall4` + `nftables`：当前防火墙主栈
- `iptables-nft` / `ip6tables-nft`：iptables 兼容层，降低插件兼容性风险
- `ipset` + `kmod-ipt-ipset`：分流和策略路由依赖
- `kmod-nf-tproxy`：透明代理转发支持
- IPSec / WireGuard 防火墙默认规则：
  - IPSec IKE/NAT-T：UDP `500`、`4500`
  - IPSec ESP：协议 `50`
  - WireGuard：UDP `51820`

### IPSec VPN

- `luci-app-ipsec-vpnd`：LuCI 配置界面
- `strongswan`：IPSec 核心服务
- `strongswan-mod-xauth-generic`：XAUTH 支持
- `strongswan-mod-kernel-libipsec`：内核态 IPsec 支持
- `strongswan-mod-stroke`：兼容传统 `ipsec` 配置方式
- `strongswan-mod-updown`：路由上下线脚本支持
- `xl2tpd`：保留 L2TP 兼容能力

> 当前配置刻意不启用 `strongswan-swanctl` 和 `strongswan-mod-vici`，避免 `swanctl` 与 `ipsec-vpnd` 同时占用 UDP `500/4500` 导致服务互相抢占。

### WireGuard VPN

- `kmod-wireguard`：内核态 WireGuard 模块
- `wireguard-tools`：命令行工具
- `luci-app-wireguard`：LuCI 管理界面
- `luci-proto-wireguard`：接口协议下拉框支持
- 启用 `chacha20poly1305` 所需内核加密依赖：`poly1305`、`chacha20poly1305`

### PassWall 代理环境

已启用 PassWall 主插件和常见多协议代理组件：

- `luci-app-passwall`
- Xray / Sing-Box
- Shadowsocks-Rust / Shadowsocks-Libev
- Trojan-Plus
- Hysteria
- NaiveProxy
- TUIC
- Xray Plugin
- V2Ray GeoData
- Nftables / Iptables 透明代理模式

### DNS 与广告拦截

- `dnsmasq-full`：替换默认 dnsmasq，启用完整功能
- DNSSEC / auth / ipset / conntrack / noid / nftset 支持
- `luci-app-smartdns`：SmartDNS LuCI 管理界面
- SmartDNS 源码在构建时从 `pymumu/openwrt-smartdns` 拉取
- `adblock-fast`：轻量广告拦截
- `luci-app-adblock-fast`：LuCI 管理界面

### LuCI 与系统工具

- `luci-theme-argon`：Argon 主题
- `luci-app-argon-config`：Argon 主题配置
- `luci-compat`：LuCI 兼容层
- `luci-app-uhttpd`：HTTP 服务
- `luci-app-ttyd`：Web 终端
- `luci-app-autoreboot`：计划重启
- `luci-app-filetransfer`：文件传输
- `luci-app-usb-printer`：USB 打印服务器
- `luci-app-unblockneteasemusic`：网易云音乐解锁

### 监控与网络工具

- `luci-app-statistics`：系统统计
- `lm-sensors`：传感器支持
- `luci-app-nlbwmon`：带宽监控
- `ethtool`：网卡诊断与硬件加速配置
- `curl`、`jq`、`gawk`、`sed`、`grep`：常用命令行工具
- `ca-bundle` / `ca-certificates`：证书环境

### 存储、NAS 与文件共享

- 文件系统支持：EXT4、Btrfs、XFS、VFAT、NTFS3、F2FS
- `block-mount` / `blockd`：块设备挂载管理
- `luci-app-diskman`：磁盘管理
- `fstrim`：SSD TRIM
- `samba4-server` + `luci-app-samba4`：Samba4 文件共享
- `wsdd2`：Windows 网络发现支持
- 默认排除 ksmbd / samba3，降低服务冲突和体积

---

## 构建产物

成功编译后，固件会发布到 GitHub Release。当前最新成功版本：

- Release：`R26.09.09`
- 对应 GitHub Actions Run：`34250746124`
- 产物文件：`openwrt-x86-64-generic-squashfs-combined.img.gz`

可安装环境：

- 裸机 x86_64 软路由
- VMware / ESXi
- Proxmox VE
- UEFI 引导系统

---

## 适用硬件

主要测试平台：

| 项目 | 规格 |
| --- | --- |
| CPU | Intel Atom D525 |
| 架构 | x86_64 / Bonnell |
| 用途 | 千兆软路由、代理网关、NAS 基础环境 |
| 存储 | SATA / SSD / USB 存储 |
| 系统 | LEDE / OpenWrt x86_64 |

编译器优化参数：

```bash
-O2 -pipe -march=bonnell -mtune=bonnell -fomit-frame-pointer
```

---

## 仓库结构

```text
.
├── .github
│   └── workflows
│       ├── Build LEDE.yml
│       └── Build LEDE Latest.yml
├── D525_x86_64.config      # x86_64 主配置，按 D525/Bonnell 优化
├── diy-part1.sh            # feeds 调整、插件替换和额外包拉取
├── diy-part2.sh            # LuCI/VPN/存储/网卡/监控初始化脚本注入
├── LICENSE
└── README.md
```

---

## 构建流程

1. 打开 GitHub 仓库 Actions。
2. 选择 `Build LEDE Latest`。
3. 点击 `Run workflow`。
4. 等待 workflow 完成。
5. 到 Releases 页面下载最新 `RYY.MM.DD` 固件包。

推荐日常使用 `Build LEDE Latest`；`Build LEDE.yml` 作为备用构建流程保留。

---

## 常用修改点

### 修改固件组件

编辑：

```text
D525_x86_64.config
```

例如取消某个包：

```bash
CONFIG_PACKAGE_tcping=n
```

启用一个包：

```bash
CONFIG_PACKAGE_tcping=y
```

### 修改 feeds 或额外插件

编辑：

```text
diy-part1.sh
```

适合处理：

- 删除上游冲突包
- 拉取维护中的插件 fork
- 替换 PassWall、SmartDNS、Argon 等组件来源

### 修改开机注入配置

编辑：

```text
diy-part2.sh
```

适合处理：

- LAN IP、主机名
- IPSec / WireGuard 防火墙规则
- 挂载优化
- 网卡硬件加速
- TRIM、read-ahead
- Samba4 初始配置
- 监控服务配置

---

## 注意事项

- 首次启动后建议检查 `/etc/config/network`、防火墙规则和 DNS 配置。
- PassWall 需要自行配置节点、协议参数和分流规则。
- IPSec / WireGuard 需要自行配置服务端、客户端和证书/密钥。
- 广告拦截、DNS 优化、代理功能应遵守当地法律法规。
- 上游 LEDE 和 feeds 持续变化，升级配置时建议先小范围验证。
- 当前仓库中的 `openwrt/` 本地源码目录仅用于本地检查，不应提交到 Git。

---

## 致谢

- [coolsnoowolf/lede](https://github.com/coolsnoowolf/lede)
- OpenWrt Project
- PassWall development team
- SmartDNS development team
- Argon Theme development team
- GitHub Actions

---

## License

本仓库保留原始开源项目各自许可证；使用、修改和分发时请遵守相应上游许可。
