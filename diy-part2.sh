#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认 IP 为 192.168.5.1
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate

# 2. 修改主机名 (可选)
sed -i 's/OpenWrt/LEDE/g' package/base-files/files/bin/config_generate

# 3. 修复可能出现的 SmartDNS 冲突 (如果有)
# 这一步通常不需要，但如果你编译报错 po2lmo 错误，可以手动处理。

# ----------------------------------------------------------------
# 👇 [硬件极限压榨优化] 注入网卡硬件加速与硬盘 4MB 预读
# ----------------------------------------------------------------

# 第一步：确保 ethtool 被自动编译进固件中
echo "CONFIG_PACKAGE_ethtool=y" >> .config

# 第二步：向开机自启脚本 rc.local 注入优化命令
# (1) 先安全删除系统原带的 exit 0
sed -i '/exit 0/d' package/base-files/files/etc/rc.local

# (2) 将我们的终极优化脚本和新的 exit 0 写入 rc.local
cat >> package/base-files/files/etc/rc.local <<'EOF'

# 开启网卡 TX 硬件加速 (tso/gso), 极大减轻老 CPU 网络分发负担
# (2>/dev/null 用于屏蔽部分老网卡不支持时的无害报错提示)
ethtool -K eth0 tso on 2>/dev/null
ethtool -K eth0 gso on 2>/dev/null

# 智能匹配优化：将所有挂载的物理硬盘(sd*)的底层预读缓存自动提升至 4MB (4096KB)
# 这能大幅减少 D525 的底层 I/O 中断，彻底解决局域网“读取比写入慢”的问题
for dev in /sys/block/sd*/queue/read_ahead_kb; do
    [ -f "$dev" ] && echo 4096 > "$dev"
done

exit 0
EOF

# ----------------------------------------------------------------
# 👆 注入结束
# ----------------------------------------------------------------
