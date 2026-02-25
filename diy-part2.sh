#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认 IP 为 192.168.5.1
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate

# 2. 修改主机名 (可选)
sed -i 's/OpenWrt/LEDE/g' package/base-files/files/bin/config_generate

# 3. 修复可能出现的 SmartDNS 冲突 (如果有)
# 这一步通常不需要，但如果你编译报错 po2lmo 错误，可以手动处理。

# ================================================================
# 👇 [基础优化] 网络硬件加速
# ================================================================

# 1. 确保 ethtool 被自动编译进固件中
echo "CONFIG_PACKAGE_ethtool=y" >> .config

# 2. rc.local 开机脚本 (只保留和网卡相关的，磁盘相关的交给下面的动态热插拔处理)
sed -i '/exit 0/d' package/base-files/files/etc/rc.local
cat >> package/base-files/files/etc/rc.local <<'EOF'

# 开启网卡 TX 硬件加速 (tso/gso)
ethtool -K eth0 tso on 2>/dev/null
ethtool -K eth0 gso on 2>/dev/null

exit 0
EOF

# ================================================================
# 👇 [磁盘极限动态优化] 自动感知任何硬盘并注入榨干参数
# ================================================================

# 1. 开启系统的全局“自动挂载 (Automount)”
# 这样任何新插入的硬盘都会被自动挂载，不需要手动去写 fstab
mkdir -p package/base-files/files/etc/config
cat > package/base-files/files/etc/config/fstab << 'EOF'
config global
        option anon_swap '0'
        option anon_mount '1'
        option auto_swap '1'
        option auto_mount '1'
        option delay_root '5'
        option check_fs '0'
EOF

# 2. 编写全局 Hotplug (热插拔) 触发脚本 ⭐ (核心黑科技)
# 原理：只要系统挂载了任何存储设备，立刻触发此脚本，动态赋予 4MB 预读和极限参数
mkdir -p package/base-files/files/etc/hotplug.d/mount
cat > package/base-files/files/etc/hotplug.d/mount/99-optimize-disk << 'EOF'
#!/bin/sh

# 只有在挂载动作(mount)时才触发
[ "$ACTION" = "mount" ] || exit 0
[ -z "$MOUNTPOINT" ] && exit 0

# (A) 动态提升物理硬盘的 4MB 预读缓存
# 例如从 $DEVICE (/dev/sdb1) 提取出物理盘符 (sdb)，并修改底层 read_ahead_kb
if [ -n "$DEVICE" ]; then
    DEV_NAME=$(basename "$DEVICE" | sed 's/[0-9]*$//')
    if [ -f "/sys/block/$DEV_NAME/queue/read_ahead_kb" ]; then
        echo 4096 > "/sys/block/$DEV_NAME/queue/read_ahead_kb"
    fi
fi

# (B) 动态甄别并重挂载 ext4 极限参数
# 检查刚刚挂载的这个设备是不是 ext4 格式
FSTYPE=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $3}' /proc/mounts)
if [ "$FSTYPE" = "ext4" ]; then
    # 如果是，立刻在底层无缝“重挂载(remount)”，注入我们的减负参数
    mount -o remount,rw,noatime,nodiratime,errors=remount-ro,commit=60 "$MOUNTPOINT"
    logger -t "Disk-Optimizer" "已自动为 $MOUNTPOINT ($DEVICE) 开启 ext4 极限性能模式"
fi
EOF
chmod +x package/base-files/files/etc/hotplug.d/mount/99-optimize-disk

# 3. 动态智能的计划任务 (定时 TRIM)
# 原理：凌晨 4 点不再傻瓜式地针对某个盘，而是自动扫描系统当下所有挂载的 ext4 设备并逐一回收碎片
mkdir -p package/base-files/files/etc/crontabs
cat >> package/base-files/files/etc/crontabs/root << 'EOF'
0 4 * * * for mp in $(awk '$3 == "ext4" {print $2}' /proc/mounts); do fstrim "$mp"; logger -t "fstrim" "已完成 $mp 的固态硬盘碎片回收"; done
EOF

# ================================================================
# 👆 所有的动态注入结束
# ================================================================
