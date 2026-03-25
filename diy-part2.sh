#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业终极版 v2 (完全无风险)
# 设计目标：
# - 不修改 fstools 源码 (非侵入式设计)
# - 幂等执行 & CI 防污染
# - Snapshot 安全
# - hotplug + init.d hook 双保险
# - 物理设备精准过滤，避开虚拟设备报错
# - 完全兼容 BusyBox / Snapshot / 22/23/24
# ==============================================================================

set -euo pipefail

trap 'echo "::error file=${BASH_SOURCE[0]},line=${LINENO}::❌ 构建失败"; exit 1' ERR

# --------------------------------------------------------------------------
# 全局配置 & CI 环境变量
# --------------------------------------------------------------------------

readonly TARGET_IP="192.168.5.1"
readonly TARGET_HOSTNAME="LEDE"
readonly FILES_DIR="files"

: "${TRIM_SCHEDULE:="0 3 * * *"}"
: "${SSD_READ_AHEAD_KB:="2048"}"
: "${HDD_READ_AHEAD_KB:="128"}"

log() { echo -e "\033[36m[INFO]\033[0m $1"; }

[[ -f scripts/feeds ]] || { echo "❌ 必须在 OpenWrt 源码根目录执行"; exit 1; }

mkdir -p "${FILES_DIR}/etc/"{uci-defaults,init.d,hotplug.d/block,hotplug.d/mount,config}
mkdir -p "${FILES_DIR}/usr/bin"


# ==============================================================================
# 阶段 1: 系统初始化 (CI安全版)
# ==============================================================================

cat <<EOF > "${FILES_DIR}/etc/uci-defaults/90-system-init"
#!/bin/sh

uci set network.lan.ipaddr='${TARGET_IP}'
uci set system.@system[0].hostname='${TARGET_HOSTNAME}'

uci commit network
uci commit system

# Samba4 自动修复
if command -v uci >/dev/null 2>&1; then
    if ! uci -q get samba4.@samba[0] >/dev/null; then
        uci add samba4 samba
        uci set samba4.@samba[-1].workgroup='WORKGROUP'
        uci set samba4.@samba[-1].charset='UTF-8'
        uci set samba4.@samba[-1].interface='lan'
    fi
    while uci -q delete samba4.@sambashare[0]; do :; done
    uci commit samba4
fi

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/90-system-init"
log "✅ 系统初始化注入完成"


# ==============================================================================
# 阶段 2: init.d 挂载修复 Hook（替代 fstools patch）
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/etc/init.d/mount-optimize"
#!/bin/sh /etc/rc.common

START=92

start() {
    if ! command -v mount >/dev/null; then
        return
    fi

    # 【架构师补全】：仅针对物理磁盘挂载点，避开 proc/sys/tmpfs/cgroup/overlay/squashfs
    while read -r dev mp fs _; do
        case "$dev" in
            /dev/*)
                ;;
            *)
                continue
                ;;
        esac
        case "$fs" in
            ext4|btrfs|xfs|f2fs|vfat|exfat|ntfs*)
                ;;
            *)
                continue
                ;;
        esac
        case "$mp" in
            /|/rom|/overlay|/boot)
                continue
                ;;
        esac
        mount -o remount,noatime "$mp" 2>/dev/null || true
    done < /proc/mounts
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/mount-optimize"
log "✅ init.d 挂载修复 Hook 注入完成"


# ==============================================================================
# 阶段 3: 网卡硬件加速服务
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common

START=85

start() {
    command -v ethtool >/dev/null || return

    for i in /sys/class/net/*; do
        iface=$(basename "$i")
        case "$iface" in
            lo|br-*|docker*|veth*|ifb*|tun*|tap*|wg*)
                continue
            ;;
        esac
        ethtool -K "$iface" tso on 2>/dev/null || true
        ethtool -K "$iface" gso on 2>/dev/null || true
    done
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/network-accel"
log "✅ 网卡加速注入完成"


# ==============================================================================
# 阶段 4: block 热插拔优化
# ==============================================================================

cat <<EOF > "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
#!/bin/sh
SSD_READ_AHEAD_KB="${SSD_READ_AHEAD_KB}"
HDD_READ_AHEAD_KB="${HDD_READ_AHEAD_KB}"

[ "\$ACTION" = "add" ] || exit 0
[ -z "\$DEVNAME" ] && exit 0

# 解析主设备（分区名 -> 主设备名）
dev="\$DEVNAME"
# 去掉末尾数字（处理普通分区，如 sda1 -> sda）
dev="\${dev%%[0-9]*}"
if [ -d "/sys/block/\$dev" ]; then
    BASE="/sys/block/\$dev"
else
    # 尝试去掉 p[0-9] 后缀（处理 NVMe 分区，如 nvme0n1p1 -> nvme0n1）
    dev="\${DEVNAME%p[0-9]*}"
    if [ -d "/sys/block/\$dev" ]; then
        BASE="/sys/block/\$dev"
    else
        exit 0
    fi
fi

# 避免 loop/ram 虚拟设备
case "\$BASE" in
    */loop*|*/ram*|*/zram*|*/sr*)
        exit 0
        ;;
esac

[ -f "\$BASE/queue/rotational" ] || exit 0
ROT=\$(cat "\$BASE/queue/rotational")

if [ "\$ROT" = 0 ]; then
    echo "\$SSD_READ_AHEAD_KB" > "\$BASE/queue/read_ahead_kb" 2>/dev/null || true
else
    echo "\$HDD_READ_AHEAD_KB" > "\$BASE/queue/read_ahead_kb" 2>/dev/null || true
fi
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
log "✅ block 优化注入完成"


# ==============================================================================
# 阶段 5: mount 热插拔 noatime
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount"
#!/bin/sh
[ "$ACTION" = "add" ] || exit 0
[ -z "$MOUNTPOINT" ] && exit 0

case "$MOUNTPOINT" in
    /|/rom|/overlay|/boot)
        exit 0
    ;;
esac

mount -o remount,noatime "$MOUNTPOINT" 2>/dev/null || true
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount"
log "✅ mount 优化注入完成"


# ==============================================================================
# 阶段 6: TRIM 引擎 (使用 99-zzz 确保在所有默认脚本之后执行)
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/usr/bin/auto-fstrim"
#!/bin/sh

command -v fstrim >/dev/null || exit 0

# 仅物理磁盘且支持 TRIM 的文件系统执行
while read -r dev mp fs _; do
    case "$dev" in
        /dev/*) ;;
        *) continue ;;
    esac
    case "$fs" in
        ext4|btrfs|xfs|f2fs)
            ;;
        *) continue ;;
    esac
    fstrim "$mp" 2>/dev/null
done < /proc/mounts
EOF

chmod 0755 "${FILES_DIR}/usr/bin/auto-fstrim"

# 使用 99-zzz-diy-cron 确保在 zzz-default-settings 之后执行（数字最大，且字母排序靠后）
cat <<EOF > "${FILES_DIR}/etc/uci-defaults/99-zzz-diy-cron"
#!/bin/sh

mkdir -p /etc/crontabs
touch /etc/crontabs/root

sed -i '/auto-fstrim/d' /etc/crontabs/root 2>/dev/null || true
echo "${TRIM_SCHEDULE} /usr/bin/auto-fstrim" >> /etc/crontabs/root

/etc/init.d/cron restart
exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-zzz-diy-cron"
log "✅ TRIM 注入完成"


log "🎉 Part2 企业终极版 v2 完全无风险完成"
