#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业终级增强版 (22/23/24 兼容)
# 功能：
#   - 系统初始化 UCI 配置 (彻底修复 fstab 重叠)
#   - 网卡硬件加速 (物理网卡精准匹配)
#   - 磁盘运行时优化 (区分 SSD/HDD、NVMe/eMMC 兼容、智能预读、动态选项)
#   - 扩展型多文件系统 SSD TRIM
#   - .config 依赖包幂等注入
# ==============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# 全局配置 & 错误捕获基建
# --------------------------------------------------------------------------
readonly TARGET_IP="192.168.5.1"
readonly TARGET_HOSTNAME="LEDE"
readonly FILES_DIR="files"

trap 'catch_error $? $LINENO' ERR
catch_error() {
    local exit_code="$1"
    local line_no="$2"
    echo "::error file=${BASH_SOURCE[0]},line=${line_no}::❌ 致命错误于第 ${line_no} 行! 退出码: ${exit_code}"
    [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && \
        echo "❌ DIY 脚本执行失败 (Line: ${line_no})" >> "$GITHUB_STEP_SUMMARY"
    exit "$exit_code"
}

log() { echo -e "\033[36m[INFO]\033[0m $1"; }

[[ -f "scripts/feeds" ]] || { echo "❌ 必须在 OpenWrt 源码根目录执行"; exit 1; }
mkdir -p "${FILES_DIR}/etc/"{uci-defaults,init.d,hotplug.d/mount,config,crontabs}

# ==============================================================================
# 阶段 1: 系统初始化与 fstab 修复
# ==============================================================================
cat << EOF > "${FILES_DIR}/etc/uci-defaults/99-system-init"
#!/bin/sh
# -------------------------------------------------------------------------
# 系统初始化脚本 (UCI 默认执行)
# -------------------------------------------------------------------------

uci set network.lan.ipaddr='${TARGET_IP}'
uci set system.@system[0].hostname='${TARGET_HOSTNAME}'
uci commit network
uci commit system

if command -v uci >/dev/null 2>&1; then
    GLOBAL_SECS=\$(uci -q show fstab | grep '=global' | cut -d. -f2 || true)
    
    # 修复：确保变量不为空时才执行删除遍历，防止 tail 处理空行报错
    if [ -n "\$GLOBAL_SECS" ]; then
        echo "\$GLOBAL_SECS" | tail -n +2 | while read sec; do
            [ -n "\$sec" ] && uci -q delete fstab."\$sec"
        done
    fi

    if [ \$(uci -q show fstab | grep -c '=global' || echo 0) -eq 0 ]; then
        uci add fstab global
    fi

    uci set fstab.@global[0].anon_swap='0'
    uci set fstab.@global[0].anon_mount='1'
    uci set fstab.@global[0].auto_swap='1'
    uci set fstab.@global[0].auto_mount='1'
    uci set fstab.@global[0].delay_root='5'
    uci set fstab.@global[0].check_fs='0'

    for sec in \$(uci -q show fstab | grep '=mount' | cut -d'.' -f2 | cut -d'=' -f1); do
        opts=\$(uci -q get fstab."\$sec".options || echo "")
        if echo "\$opts" | grep -q "relatime"; then
            new_opts=\$(echo "\$opts" | sed 's/relatime/noatime,nodiratime/g')
            uci set fstab."\$sec".options="\$new_opts"
        fi
    done

    uci commit fstab
fi

[ -x /etc/init.d/network-accel ] && /etc/init.d/network-accel enable
exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-system-init"
log "✅ 系统初始化及 fstab 基础修复注入完成"

# ==============================================================================
# 阶段 2: Procd 网卡硬件加速服务
# ==============================================================================
cat << 'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start() {
    if command -v ethtool >/dev/null 2>&1; then
        for iface in /sys/class/net/*; do
            [ -e "$iface" ] || continue
            iface_name=$(basename "$iface")
            case "$iface_name" in
                eth*|enp*|enx*|eno*)
                    ethtool -K "$iface_name" tso on 2>/dev/null || true
                    ethtool -K "$iface_name" gso on 2>/dev/null || true
                    ;;
            esac
        done
        logger -t "Network-Opt" "网卡硬件加速已启用"
    fi
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/network-accel"
log "✅ Procd 网卡硬件加速服务注入完成"

# ==============================================================================
# 阶段 3 & 4: 磁盘运行时优化 & LuCI 配置同步（增强版）
# ==============================================================================
cat << 'EOF' > "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
#!/bin/sh
[ "$ACTION" != "add" ] && exit 0
[ -z "$MOUNTPOINT" ] && exit 0
[ -z "$DEVICE" ] && exit 0

FSTYPE=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $3}' /proc/mounts)

case "$FSTYPE" in
    ext4|btrfs|xfs)
        # 【修复1：精准提取块设备名，完美兼容 NVMe (nvme0n1p1) 与 eMMC (mmcblk0p1)】
        DEV_RAW="${DEVICE##*/}"
        case "$DEV_RAW" in
            nvme*p*|mmcblk*p*) DEV_BASE=$(echo "$DEV_RAW" | sed -E 's/p[0-9]+$//') ;;
            *) DEV_BASE=$(echo "$DEV_RAW" | sed -E 's/[0-9]+$//') ;;
        esac

        # ---------- 1. 智能预读缓存 ----------
        if [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/queue/rotational" ]; then
            rotational=$(cat "/sys/block/$DEV_BASE/queue/rotational")
            if [ "$rotational" = "0" ]; then
                echo 2048 > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && \
                    logger -t "Disk-Opt" "SSD $DEV_BASE 预读缓存设为 2048KB"
            else
                echo 128 > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && \
                    logger -t "Disk-Opt" "HDD $DEV_BASE 预读缓存设为 128KB"
            fi
        fi

        # ---------- 2. 挂载选项动态优化 ----------
        current_opts=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $4}' /proc/mounts | tr ',' '\n')
        keep_opts=""
        for opt in $current_opts; do
            case "$opt" in
                errors=*|rw|ro|sync|dirsync|mand) keep_opts="${keep_opts},${opt}" ;;
            esac
        done
        
        base_opts="noatime,nodiratime"
        if [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/queue/rotational" ]; then
            rotational=$(cat "/sys/block/$DEV_BASE/queue/rotational")
            if [ "$rotational" = "0" ]; then
                base_opts="${base_opts},data=ordered"
            else
                base_opts="${base_opts},data=ordered,commit=30"
            fi
        fi
        
        new_opts="${base_opts}${keep_opts}"
        new_opts=$(echo "$new_opts" | sed 's/^,//;s/,,*/,/g')
        
        if mountpoint -q "$MOUNTPOINT" && [ -w "$MOUNTPOINT" ]; then
            if mount -o remount,"$new_opts" "$MOUNTPOINT" 2>/dev/null; then
                logger -t "Disk-Opt" "已优化 $MOUNTPOINT 挂载选项: $new_opts"
            else
                logger -t "Disk-Opt" "⚠ 无法修改 $MOUNTPOINT 挂载选项"
            fi
        fi

        # ---------- 3. LuCI 配置反向修复（持久化） ----------
        if command -v uci >/dev/null 2>&1 && command -v block >/dev/null 2>&1; then
            UUID=$(block info "$DEVICE" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2 | head -n1)
            if [ -n "$UUID" ]; then
                SEC=$(uci -q show fstab | grep "uuid='$UUID'" | cut -d'.' -f2 | head -n1)
                if [ -n "$SEC" ]; then
                    OPTS=$(uci -q get fstab."$SEC".options || echo "")
                    if echo "$OPTS" | grep -q "relatime"; then
                        NEW_OPTS=$(echo "$OPTS" | sed 's/relatime/noatime,nodiratime/g')
                        uci set fstab."$SEC".options="$NEW_OPTS"
                        uci commit fstab
                        logger -t "Disk-Opt" "已修复 LuCI 生成的 relatime 参数"
                    fi
                fi
            fi
        fi
        ;;
esac
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
log "✅ 磁盘优化与 LuCI 反向劫持（增强版）注入完成"

# ==============================================================================
# 阶段 5: SSD 定时 TRIM（扩展支持 ext4/btrfs/xfs）
# ==============================================================================
CRON_FILE="${FILES_DIR}/etc/crontabs/root"
mkdir -p "$(dirname "$CRON_FILE")"

if [ -f "$CRON_FILE" ]; then
    grep -v 'fstrim' "$CRON_FILE" > "${CRON_FILE}.tmp" || true
else
    touch "${CRON_FILE}.tmp"
fi

cat >> "${CRON_FILE}.tmp" << 'CRONEOF'
0 4 * * * command -v fstrim >/dev/null && for fs in ext4 btrfs xfs; do for mp in $(awk -v fs="$fs" '$3==fs {print $2}' /proc/mounts); do fstrim "$mp" 2>/dev/null; done; done
CRONEOF

sort -u "${CRON_FILE}.tmp" > "$CRON_FILE"
rm -f "${CRON_FILE}.tmp"
log "✅ SSD 定时 TRIM（多文件系统支持）注入完成"

log "🎉 DIY Part 2 脚本（企业增强版）执行完成"
