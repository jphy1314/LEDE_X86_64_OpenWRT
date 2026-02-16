#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认 IP 为 192.168.5.1
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate

# 2. 修改主机名 (可选)
sed -i 's/OpenWrt/LEDE/g' package/base-files/files/bin/config_generate

# 3. 拦截 WebRTC 泄漏 (STUN 端口过滤)
# 原理：强制拦截 LAN 口发往 WAN 口的常用 STUN 端口流量 (UDP 3478, 5349, 19302-19308)
# 兼容性：同时支持 IPv4 和 IPv6，且适配 Firewall4 (nftables) 和 Iptables

# 定位防火墙配置文件路径 (LEDE 的默认路径通常如下)
FW_CONF="package/network/config/firewall/files/firewall.config"

# 如果上述路径不存在，则尝试 base-files 路径
[ ! -f "$FW_CONF" ] && FW_CONF="package/base-files/files/etc/config/firewall"

if [ -f "$FW_CONF" ]; then
    echo "Adding WebRTC leak prevention rules to $FW_CONF"
    cat <<EOF >> "$FW_CONF"

config rule
	option name 'Block-WebRTC-STUN-v4'
	option src 'lan'
	option dest 'wan'
	option proto 'udp'
	option dest_port '3478 5349 19302 19305 19307 19308'
	option target 'REJECT'
	option family 'ipv4'

config rule
	option name 'Block-WebRTC-STUN-v6'
	option src 'lan'
	option dest 'wan'
	option proto 'udp'
	option dest_port '3478 5349 19302 19305 19307 19308'
	option target 'REJECT'
	option family 'ipv6'
EOF
else
    echo "Warning: Firewall config file not found, skipping WebRTC rules."
fi

# 4. 修复可能出现的 SmartDNS 冲突 (如果有)
# 这一步通常不需要，但如果你编译报错 po2lmo 错误，可以手动处理。
