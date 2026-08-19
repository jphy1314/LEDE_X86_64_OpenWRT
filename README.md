# LEDE_X86_64_OpenWRT

基于 **coolsnowwolf/lede** 开源项目定制的 OpenWrt / LEDE x86_64 固件编译仓库。

本项目主要面向 x86_64 软路由设备，通过 GitHub Actions 自动化编译，集成常用网络服务、科学上网组件、DNS 优化、安全功能以及硬件性能优化配置。

---

## 项目特点

* 基于 LEDE 最新源码持续更新
* GitHub Actions 云端自动编译
* 支持 x86_64 通用设备
* 针对低功耗 Intel 平台进行优化
* 保留 PassWall 完整依赖环境
* 集成 SmartDNS 高性能 DNS 服务
* 集成 Argon Web 管理主题
* 支持 IPv4 / IPv6 网络环境
* 支持硬盘、SSD、USB 存储优化

---

## 支持硬件

主要测试环境：

| 项目  | 配置                  |
| --- | ------------------- |
| CPU | Intel Atom D525     |
| 架构  | x86_64              |
| 网络  | 千兆软路由环境             |
| 存储  | SATA / SSD / USB 存储 |
| 系统  | OpenWrt / LEDE      |

编译参数针对 Atom Bonnell 架构优化：

```
-O2 -pipe -march=bonnell -mtune=bonnell -fomit-frame-pointer
```

---

# 已集成功能

## 网络代理

* PassWall
* Xray
* Sing-box
* TCP/UDP 转发支持
* 国内外分流规则支持

## DNS 服务

* SmartDNS
* DNS 缓存优化
* DNS 分流
* DNSSEC 支持
* dnsmasq-full

## 网络功能

* IPv6 支持
* WireGuard
* IPsec VPN
* DDNS 动态域名
* TCP BBR
* 网络性能优化

## 系统管理

* LuCI Web 管理界面
* Argon 主题
* CPU 频率管理
* IRQ 优化
* 软件包管理

## 存储支持

* EXT4
* Btrfs
* XFS
* NVMe
* USB 存储
* TRIM 优化

## 其他服务

* USB 打印服务器
* KMS 服务
* 网络诊断工具

---

# 编译环境

GitHub Actions:

* Ubuntu 24.04 Runner
* OpenWrt / LEDE Master 分支
* ccache 编译缓存优化
* 自动上传固件文件

---

# 编译流程

## 1. 获取源码

```bash
git clone https://github.com/jphy1314/LEDE_X86_64_OpenWRT.git
cd LEDE_X86_64_OpenWRT
```

## 2. 修改配置

根据需求修改：

```
.config
diy-part1.sh
diy-part2.sh
.github/workflows/*.yml
```

## 3. 启动 GitHub Actions

进入：

```
Actions
 → Build LEDE Latest TEST
 → Run workflow
```

等待自动完成编译。

---

# 固件输出

编译完成后可在 GitHub Actions Artifact 中下载：

```
openwrt-x86-64-generic-squashfs-combined.img.gz
```

支持：

* VMware
* ESXi
* PVE
* 裸机安装
* UEFI 启动

---

# 项目目录

```
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

# 注意事项

1. 本项目属于个人定制固件，不保证适用于所有设备。
2. 首次启动建议恢复默认配置后再进行网络设置。
3. 使用代理、VPN 等功能时，请根据当地法律法规配置。
4. 固件功能会随着源码更新持续调整。

---

# 致谢

感谢以下开源项目：

* coolsnowwolf/lede
* OpenWrt 官方项目
* PassWall 开发团队
* SmartDNS 开发团队
* Argon Theme 开发团队

---

# License

本项目遵循相关开源项目许可证协议。

仅用于学习、研究和个人软路由部署。
