#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - Enterprise Ultimate Edition (22/23/24 Compatible)
# No config_generate hack | Full UCI Defaults | Procd Standard | Idempotent
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 全局配置
# ------------------------------------------------------------------------------
readonly TARGET_IP="192.168.5.1"
readonly TARGET_HOSTNAME="LEDE"
readonly FILES_DIR="files"

# ------------------------------------------------------------------------------
# GitHub Actions 错误捕获
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 运行环境检查
# ------------------------------------------------------------------------------
[[ -f "scripts/feeds" ]] || { echo "必须在 OpenWrt 源码根目录执行"; exit 1; }

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && \
echo "### 🛠️ OpenWrt 企业级构建报告 (22/23/24 兼容)" > "$GITHUB_STEP_SUMMARY"

# ------------------------------------------------------------------------------
# 构建 Overlay 结构
# ------------------------------------------------------------------------------
mkdir -p "${FILES_DIR}/etc/"{uci-defaults,init.d,hotplug.d/mount,config,crontabs}

# ==============================================================================
# 阶段 1: 使用 UCI-DEFAULTS 注入系统配置（兼容 24）
# ==============================================================================

cat << EOF > "${FILES_DIR}/etc/uci-defaults/99-system-init"
#!/bin/sh

# 设置 LAN IP
uci set network.lan.ipaddr='${TARGET_IP}'

# 设置主机名
uci set system.@system[0].hostname='${TARGET_HOSTNAME}'

uci commit network
uci commit system

# 启用网卡加速服务
/etc/init.d/network-accel enable

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-system-init"

log "系统默认参数已通过 UCI 注入（兼容 22/23/24）"

# ==============================================================================
# 阶段 2: Procd 标准网卡硬件加速服务
# ==============================================================================

cat << 'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start() {
    if command -v ethtool >/dev/null 2>&1; then
        for iface in $(ls /sys/class/net 2>/dev/null | grep -E '^eth|^enp|^enx|^eno'); do
            ethtool -K "$iface" tso on 2>/dev/null
            ethtool -K "$iface" gso on 2>/dev/null
        done
        logger -t "Network-Opt" "网卡硬件加速已启用"
    fi
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/network-accel"

log "Procd 网卡加速服务注入完成"

# ==============================================================================
# 阶段 3: 磁盘自动挂载策略
# ==============================================================================

cat << 'EOF' > "${FILES_DIR}/etc/config/fstab"
config global
        option anon_swap '0'
        option anon_mount '1'
        option auto_swap '1'
        option auto_mount '1'
        option delay_root '5'
        option check_fs '0'
EOF

# ==============================================================================
# 阶段 4: Hotplug 智能磁盘优化 (区分 U盘)
# ==============================================================================

cat << 'EOF' > "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
#!/bin/sh
[ "$ACTION" = "add" ] || exit 0
[ -z "$MOUNTPOINT" ] && exit 0

DEV_NAME=""
if [ -n "$DEVICE" ]; then
    case "$DEVICE" in
        *nvme[0-9]*n[0-9]*p[0-9]* | *mmcblk[0-9]*p[0-9]*) DEV_NAME=$(echo "$DEVICE" | sed 's/p[0-9]*$//') ;;
        *) DEV_NAME=$(basename "$DEVICE" | sed 's/[0-9]*$//') ;;
    esac
fi

IS_REMOVABLE="1"
[ -f "/sys/block/$DEV_NAME/removable" ] && \
    IS_REMOVABLE=$(cat "/sys/block/$DEV_NAME/removable")

FSTYPE=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $3}' /proc/mounts)

if [ "$FSTYPE" = "ext4" ]; then
    if [ "$IS_REMOVABLE" = "0" ]; then
        [ -f "/sys/block/$DEV_NAME/queue/read_ahead_kb" ] && \
            echo 4096 > "/sys/block/$DEV_NAME/queue/read_ahead_kb"
        mount -o remount,rw,noatime,nodiratime,errors=remount-ro,commit=30 "$MOUNTPOINT"
        logger -t "Disk-Opt" "固定硬盘性能模式已启用"
    else
        mount -o remount,rw,noatime,nodiratime "$MOUNTPOINT"
        logger -t "Disk-Opt" "移动设备安全模式已启用"
    fi
fi
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"

log "磁盘智能优化脚本注入完成"

# ==============================================================================
# 阶段 5: SSD 定时 TRIM（幂等）
# ==============================================================================

CRON_FILE="${FILES_DIR}/etc/crontabs/root"
if [[ ! -f "$CRON_FILE" ]] || ! grep -q 'fstrim' "$CRON_FILE"; then
cat << 'EOF' >> "$CRON_FILE"
0 4 * * * for mp in $(awk '$3 == "ext4" {print $2}' /proc/mounts); do fstrim "$mp" 2>/dev/null; done
EOF
fi

# ==============================================================================
# 阶段 6: .config 依赖包幂等注入
# ==============================================================================

inject_config() {
    local key="$1"
    sed -i "/^${key}=/d" .config 2>/dev/null || true
    sed -i "/^# ${key} is not set/d" .config 2>/dev/null || true
    echo "${key}=y" >> .config
}

touch .config

inject_config "CONFIG_PACKAGE_ethtool"
inject_config "CONFIG_PACKAGE_fstrim"
inject_config "CONFIG_PACKAGE_block-mount"
inject_config "CONFIG_PACKAGE_kmod-nvme"

log "依赖组件已无重复注入"

log "🎉 企业级终极脚本执行完成（完全兼容 OpenWrt 22/23/24）"
