#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业终级版 v2 (完全无风险)
# 设计目标：
# - 不修改 fstools 源码 (非侵入式设计)
# - 幂等执行 & CI 防污染
# - Snapshot 安全
# - hotplug + init.d hook 双保险
# - 物理设备精准正则过滤 (防虚拟设备报错)
# - 兼容 FUSE (ntfs-3g) 及极端早期引导日志保护
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

# 分离环境变量注入，防转义地狱
cat <<EOF > "${FILES_DIR}/etc/uci-defaults/90-system-init"
#!/bin/sh
TARGET_IP='${TARGET_IP}'
TARGET_HOSTNAME='${TARGET_HOSTNAME}'
EOF

# 追加原生路由器逻辑 (使用单引号 'EOF'，内部彻底免转义，杜绝所有语法陷阱！)
cat <<'EOF' >> "${FILES_DIR}/etc/uci-defaults/90-system-init"
uci set network.lan.ipaddr="$TARGET_IP"
uci set system.@system[0].hostname="$TARGET_HOSTNAME"

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
# 阶段 2: init.d 挂载修复 Hook（非侵入式内核 Remount）
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/etc/init.d/mount-optimize"
#!/bin/sh /etc/rc.common

START=92

start() {
    if ! command -v mount >/dev/null; then
        return
    fi

    # 架构师补全: 仅针对物理真实挂载盘进行 remount，彻底避开虚拟文件系统
    # 兼容 fuseblk 以完美支持 ntfs-3g 的 noatime 提速
    while read -r dev mp fs _; do
        case "$dev" in
            /dev/*) ;;
            *) continue ;;
        esac
        
        case "$fs" in
            ext4|btrfs|xfs|f2fs|vfat|exfat|ntfs*|fuseblk) ;;
            *) continue ;;
        esac
        
        case "$mp" in
            /|/rom|/overlay|/boot) continue ;;
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
# 阶段 4: block 热插拔优化 (精准白名单设备解析)
# ==============================================================================

# 分段注入 CI 变量
cat <<EOF > "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
#!/bin/sh
SSD_READ_AHEAD_KB="${SSD_READ_AHEAD_KB}"
HDD_READ_AHEAD_KB="${HDD_READ_AHEAD_KB}"
EOF

# 追加原生逻辑
cat <<'EOF' >> "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
[ "$ACTION" = "add" ] || exit 0
[ -z "$DEVNAME" ] && exit 0

# 提取主设备名逻辑 (兼容 NVMe, mmcblk, sdX, vdX 等虚拟块设备)
# 【架构师修复】：拆分 sd* 和 vd*，彻底避免上古版 BusyBox 对合并模式的不兼容解析失败
case "$DEVNAME" in
    nvme*)   dev="${DEVNAME%p[0-9]*}" ;;
    mmcblk*) dev="${DEVNAME%p[0-9]*}" ;;
    sd*)     dev="${DEVNAME%%[0-9]*}" ;;
    vd*)     dev="${DEVNAME%%[0-9]*}" ;;
    hd*)     dev="${DEVNAME%%[0-9]*}" ;;
    xvd*)    dev="${DEVNAME%%[0-9]*}" ;;
    *)       exit 0 ;;
esac

BASE="/sys/block/$dev"
[ -d "$BASE" ] || exit 0

# 提取旋转介质标识 (0 为 SSD, 1 为 HDD)
ROT=$(cat "$BASE/queue/rotational" 2>/dev/null || echo 1)

# 安全预检 read_ahead_kb 节点是否存在，防止老内核或精简版内核报错
if [ -f "$BASE/queue/read_ahead_kb" ]; then
    if [ "$ROT" = "0" ]; then
        echo "$SSD_READ_AHEAD_KB" > "$BASE/queue/read_ahead_kb" 2>/dev/null || true
    else
        echo "$HDD_READ_AHEAD_KB" > "$BASE/queue/read_ahead_kb" 2>/dev/null || true
    fi
fi
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
log "✅ block I/O 优化注入完成"


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

# 拦截热插拔动态挂载，暴力覆盖性能参数
mount -o remount,noatime "$MOUNTPOINT" 2>/dev/null || true

EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount"
log "✅ mount 优化注入完成"


# ==============================================================================
# 阶段 6: TRIM 引擎
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/usr/bin/auto-fstrim"
#!/bin/sh

command -v fstrim >/dev/null || exit 0

# 仅对物理磁盘且支持 TRIM 的文件系统执行物理块回收
# 绝对禁止对 tmpfs(内存盘) 或 squashfs(只读包) 发送无意义的 discard 指令
while read -r dev mp fs _; do
    case "$dev" in
        /dev/*) ;;
        *) continue ;;
    esac
    
    case "$fs" in
        ext4|btrfs|xfs|f2fs) ;;
        *) continue ;;
    esac
    
    fstrim "$mp" 2>/dev/null || true
done < /proc/mounts

EOF

chmod 0755 "${FILES_DIR}/usr/bin/auto-fstrim"

# 使用 99-zz- 命名，确保它排在 99-default-settings 后面执行以防洗白
cat <<EOF > "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
#!/bin/sh

mkdir -p /etc/crontabs
touch /etc/crontabs/root

sed -i '/auto-fstrim/d' /etc/crontabs/root 2>/dev/null || true
echo "${TRIM_SCHEDULE} /usr/bin/auto-fstrim" >> /etc/crontabs/root

/etc/init.d/cron restart 2>/dev/null || true

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
log "✅ TRIM 引擎注入完成"


log "🎉 CI终极稳定版 Part2 彻底无风险完成！"
