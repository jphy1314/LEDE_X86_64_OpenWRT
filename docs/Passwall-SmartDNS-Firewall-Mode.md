# Passwall + SmartDNS 防火墙模式说明

## 结论

当前 `D525_x86_64.config` 没有明显漏配。固件已经同时包含 `nftables`、`iptables-nft`、`ipset`、`dnsmasq-full`、Passwall 的 iptables 透明代理、Passwall 的 nftables 透明代理、SmartDNS 等关键组件。

当 Passwall 与 SmartDNS 联用时，如果 DNS 在 Passwall 页面显示红色（`NOT RUNNING`），而将 Passwall 高级设置中的首选防火墙工具切换为 `iptables` 后恢复正常，这说明问题更可能出在 **Passwall 的 nftables 原生执行路径兼容性**，而不是仓库 config 漏选基础模块。

## 当前仓库状态

仓库：`jphy1314/LEDE_X86_64_OpenWRT`

当前 config：`D525_x86_64.config`

已确认存在：

- `CONFIG_PACKAGE_firewall4=y`
- `CONFIG_PACKAGE_nftables=y`
- `CONFIG_PACKAGE_iptables-nft=y`
- `CONFIG_PACKAGE_ip6tables-nft=y`
- `CONFIG_PACKAGE_ipset=y`
- `CONFIG_PACKAGE_kmod-ipt-ipset=y`
- `CONFIG_PACKAGE_kmod-ipt-nat=y`
- `CONFIG_PACKAGE_kmod-ipt-tproxy=y`
- `CONFIG_PACKAGE_kmod-nf-tproxy=y`
- `CONFIG_PACKAGE_kmod-nft-core=y`
- `CONFIG_PACKAGE_kmod-nft-nat=y`
- `CONFIG_PACKAGE_kmod-nft-socket=y`
- `CONFIG_PACKAGE_kmod-nft-tproxy=y`
- `CONFIG_PACKAGE_dnsmasq-full=y`
- `CONFIG_PACKAGE_dnsmasq_full_ipset=y`
- `CONFIG_PACKAGE_dnsmasq_full_nftset=y`
- `CONFIG_PACKAGE_luci-app-passwall=y`
- `CONFIG_PACKAGE_luci-app-passwall_Iptables_Transparent_Proxy=y`
- `CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y`
- `CONFIG_PACKAGE_luci-app-smartdns=y`
- `CONFIG_PACKAGE_smartdns=y`

结论：这不是“没选 iptables”的问题，而是双栈并存后，Passwall 在 nftables 原生路径上执行不稳定。

## 现象与判断

现象：

- Passwall + SmartDNS 开启 DNS 分流后，Passwall 首页 DNS 状态显示红色 / `NOT RUNNING`。
- 将 Passwall 高级设置中的首选防火墙工具从 `nftables` 改为 `iptables` 后，DNS 状态恢复正常。

判断：

- `NOT RUNNING` 是 Passwall 前端状态展示，不等同于内核或系统真实 DNS 服务崩溃。
- Passwall 实际有 `iptables` 与 `nftables` 两套执行脚本/逻辑。
- 当前更稳妥的路径是 `iptables`，因为它通过成熟兼容层运行，兼容性优于当前 Passwall 的 nftables 原生路径。

## 源码证据

参考仓库：

- `Openwrt-Passwall/openwrt-passwall`
- `Openwrt-Passwall/openwrt-passwall-packages`
- `pymumu/openwrt-smartdns`

关键线索：

1. `luci-app-passwall` 的 `Makefile` 中：
   - `Iptables_Transparent_Proxy` 依赖 `ipset`、`kmod-ipt-nat` 等。
   - `Nftables_Transparent_Proxy` 依赖 `kmod-nft-socket`、`kmod-nft-tproxy`、`kmod-nft-nat` 等。

2. Passwall 运行时同时存在：
   - `root/usr/share/passwall/iptables.sh`
   - `root/usr/share/passwall/nftables.sh`

   这说明两套防火墙模式是分开实现的，不是简单开关切换。

3. Passwall 状态页显示逻辑位于：
   - `luasrc/view/passwall/global/status.htm`

   其中 `dns_mode_status` 为真时显示 `RUNNING`，否则显示 `NOT RUNNING`。

4. SmartDNS 的 dnsmasq 集成通过：
   - `luci-app-smartdns/root/usr/share/smartdns/helper_dnsmasq.lua`

   将 SmartDNS 接入系统 DNS 转发链路。

## 为什么 iptables 更稳

虽然现代 OpenWrt 底层已经转向 `fw4 + nftables`，但 Passwall 这类高频动态分流插件还依赖大量集合/规则操作：

- IP/域名集合写入
- DNS 重定向
- TPROXY
- 客户端流量劫持
- 分流链路联动

`iptables` 路径通过 `iptables-nft` 兼容层翻译成内核规则，兼容性和历史稳定性更高。`nftables` 原生路径理论上更现代，但对 Passwall 版本、内核模块组合、`nftset` 写法、`dnsmasq-full` 配置模式的一致性要求更高。

因此，在本仓库当前固件组合下：

> 推荐 Passwall 使用 `iptables` 模式，而不是继续依赖原生 `nftables` 模式。

## 推荐配置

当前仓库 config 建议保持现状，不建议为了追求“纯 nftables”删除 `iptables-nft`、`ipset`、Passwall iptables 透明代理等兼容组件。

Passwall Web 配置建议：

- 首选防火墙工具：`iptables`
- DNS 模式：根据实际分流需求选择 SmartDNS / Dnsmasq
- SmartDNS：确保 `china`、`bootstrap`、`proxy` 出站组配置与实际订阅一致
- 若启用 IPv6 分流，需同时检查 Passwall 中是否启用了 `filter_proxy_ipv6`

## 快速验证命令

SSH 到路由器后执行：

```sh
uci get passwall.@global[0].firewall
netstat -tulnp | grep -E ':(53|6053)'
ps | grep -E 'smartdns|dnsmasq'
nslookup -type=AAAA suteng.dns.army 127.0.0.1
```

Passwall UI 中确认：

- DNS 状态为 `RUNNING`
- SmartDNS 进程存在
- dnsmasq 进程存在
- `127.0.0.1:53` 由 dnsmasq 监听
- `127.0.0.1:6053` 由 smartdns 监听

## 风险提示

- 如果为了“纯净 nftables”删除 `iptables-nft` / `ipset`，Passwall 的成熟兼容路径会被削弱，DNS 分流可能重新不稳定。
- 如果 Passwall 选 `nftables` 但内核 nft 模块组合、`nftset` 写法或 dnsmasq 模式不一致，仍可能出现 DNS 红灯。
- 如果后续 Passwall 升级，建议重新验证 DNS 分流、`filter_proxy_ipv6` 与 DDNS 的 AAAA 链路。
