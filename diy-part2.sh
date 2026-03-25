#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业终极版 v4.2 (纯净策略引擎版)
# 设计目标：
# - 零侵入式设计 (不修改任何系统原生源码)
# - Snapshot / 22 / 23 / 24 绝对兼容
# - 挂载参数统一交由 init.d/mount-policy-engine 集中控制
# - 完美绕过 Lean 源码的 cron 洗白与时序陷阱
# ==============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# 全局配置 & CI 环境变量
# --------------------------------------------------------------------------
readonly TARGET_IP="192.168.5.1"
readonly TARGET_HOSTNAME="LEDE"
readonly FILES_DIR="files"

: "${TRIM_SCHEDULE:="0 3 * * *"}"
: "${SSD_READ_AHEAD_KB:="2048"}"
: "${HDD_READ_AHEAD_KB:="128"}"

trap 'echo "::error file=${BASH_SOURCE[0]},line=${LINENO}::❌ 构建失败"; exit 1' ERR
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
# 阶段 2: 网卡硬件加速服务
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common

START=85

start() {
    command -v ethtool >/dev/null || return

    for i in /sys/class/net/*; do
        [ -e "$i" ] || continue          # 确保设备存在
        iface=$(basename "$i")
        case "$iface" in
            lo|br-*|docker*|veth*)
                continue
            ;;
        esac
        ethtool -K "$iface" tso on 2>/dev/null || true
        ethtool -K "$iface" gso on 2>/dev/null || true
    done
}
EOF
chmod 0755 "${FILES_DIR}/etc/init.d/network-accel"
log "✅ 网卡硬件加速服务注入完成"

# ==============================================================================
# 阶段 3: block 热插拔优化（SSD/HDD 物理层 读预取）
# ==============================================================================
cat <<EOF > "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
#!/bin/sh
SSD_READ_AHEAD_KB="${SSD_READ_AHEAD_KB}"
HDD_READ_AHEAD_KB="${HDD_READ_AHEAD_KB}"

[ "\$ACTION" = "add" ] || exit 0
[ -z "\$DEVNAME" ] && exit 0

# 提取主设备名（分区 -> 主设备）
case "\$DEVNAME" in
    *p[0-9]*)
        # NVMe 或 mmcblk 分区（nvme0n1p1, mmcblk0p1）
        dev="\${DEVNAME%p[0-9]*}"
        ;;
    *[0-9])
        # 普通分区（sda1, sdb2）
        dev="\${DEVNAME%%[0-9]*}"
        ;;
    *)
        dev="\$DEVNAME"
        ;;
esac

[ -d "/sys/block/\$dev" ] || exit 0
BASE="/sys/block/\$dev"

[ -f "\$BASE/queue/read_ahead_kb" ] || exit 0

ROT=\$(cat "\$BASE/queue/rotational")
if [ "\$ROT" = 0 ]; then
    echo "\$SSD_READ_AHEAD_KB" > "\$BASE/queue/read_ahead_kb" 2>/dev/null || true
else
    echo "\$HDD_READ_AHEAD_KB" > "\$BASE/queue/read_ahead_kb" 2>/dev/null || true
fi
EOF
chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
log "✅ block 热插拔物理层优化注入完成"

# ==============================================================================
# 阶段 4: TRIM 引擎及动态 Cron 任务 (利用 zz 垫底反杀洗白)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/usr/bin/auto-fstrim"
#!/bin/sh
command -v fstrim >/dev/null || exit 0

# 仅对物理磁盘且支持 TRIM 的文件系统执行
for mp in $(awk '$1 ~ /^\/dev\// && $3 ~ /^(ext4|btrfs|xfs|f2fs)$/ {print $2}' /proc/mounts); do
    [ -d "$mp" ] || continue
    fstrim "$mp" 2>/dev/null
done
EOF
chmod 0755 "${FILES_DIR}/usr/bin/auto-fstrim"

cat <<EOF > "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
#!/bin/sh
mkdir -p /etc/crontabs
touch /etc/crontabs/root

# 删除旧任务，注入新任务
sed -i '/auto-fstrim/d' /etc/crontabs/root 2>/dev/null || true
echo "${TRIM_SCHEDULE} /usr/bin/auto-fstrim" >> /etc/crontabs/root

/etc/init.d/cron restart
exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
log "✅ 独立 TRIM 引擎及防洗白 Cron 任务注入完成"

# ==============================================================================
# 阶段 5: 挂载策略引擎（集中控制，统一 rw,noatime 强制洗脑策略）
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/init.d/mount-policy-engine"
#!/bin/sh /etc/rc.common

START=93

start() {
    command -v mount >/dev/null || return
    command -v uci >/dev/null || return

    # 遍历所有已挂载的物理真实分区
    for mp in $(awk '$1 ~ /^\/dev\// && $3 ~ /^(ext4|btrfs|xfs|f2fs|vfat|exfat|ntfs|fuseblk)$/ {print $2}' /proc/mounts); do
        case "$mp" in
            /|/rom|/overlay|/boot)
                continue
            ;;
        esac

        # 1. 内核级强制洗涤：增量 remount，绝不触发内核报错
        mount -o remount,rw,noatime "$mp" 2>/dev/null || true

        # 2. 配置文件级防欺骗：更新 fstab，防止 LuCI 界面呈现虚假数据
        DEV=$(awk -v mp="$mp" '$2==mp {print $1}' /proc/mounts)
        [ -n "$DEV" ] || continue

        # 优先匹配 device，其次匹配 uuid
        SEC=$(uci -q show fstab | grep "device='$DEV'" | cut -d'.' -f2 | head -n1)
        if [ -z "$SEC" ]; then
            UUID=$(block info "$DEV" 2>/dev/null | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
            [ -n "$UUID" ] && SEC=$(uci -q show fstab | grep "uuid='$UUID'" | cut -d'.' -f2 | head -n1)
        fi
        [ -n "$SEC" ] || continue

        RAW_OPTS=$(uci -q get fstab."$SEC".options || echo "")
        LOWER_OPTS=$(echo "$RAW_OPTS" | tr 'A-Z' 'a-z')
        NEW_OPTS=$(echo ",$LOWER_OPTS," | sed 's/,relatime,/,/g; s/,strictatime,/,/g; s/,defaults,/,/g; s/,,*/,/g; s/^,//; s/,$//')
        uci set fstab."$SEC".options="rw,noatime${NEW_OPTS:+,$NEW_OPTS}"
    done
    uci commit fstab
}
EOF
chmod 0755 "${FILES_DIR}/etc/init.d/mount-policy-engine"
log "✅ 挂载策略集中控制引擎注入完成"

# ==============================================================================
# 阶段 6: fstab 全局清洗（删除冗余 global 节点，保持 Snapshot 安全）
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/uci-defaults/96-fstab-clean"
#!/bin/sh
command -v uci >/dev/null || exit 0

# 删除所有 global 节点，重新注入单一的最小 global
GLOBAL_SECS=$(uci -q show fstab | grep '=global' | sed -n 's/^fstab\.\([^=]*\)=.*/\1/p')
for sec in $GLOBAL_SECS; do uci -q delete fstab."$sec"; done

uci add fstab global
uci set fstab.@global[-1].anon_swap='0'
uci set fstab.@global[-1].anon_mount='1'
uci set fstab.@global[-1].auto_swap='1'
uci set fstab.@global[-1].auto_mount='1'
uci set fstab.@global[-1].delay_root='5'
uci set fstab.@global[-1].check_fs='0'
uci commit fstab
exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/96-fstab-clean"
log "✅ fstab 全局节点清洗完成"

# ==============================================================================
# 阶段 7: hotplug Policy Hook（确保插入新磁盘或修改挂载时，策略引擎瞬间生效）
# ==============================================================================
# 【架构师核心修复】：必须放在 hotplug.d/mount 目录！因为只有挂载成功后，/proc/mounts 才有数据供策略引擎扫描！
cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/mount/95-policy-hotplug"
#!/bin/sh

[ "$ACTION" = "add" ] || exit 0
[ -x /etc/init.d/mount-policy-engine ] || exit 0

/etc/init.d/mount-policy-engine start
EOF
chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/95-policy-hotplug"
log "✅ hotplug 挂载触发钩子注入完成"

log "🎉 Part 2 挂载策略引擎版 v4.2 (完美时序修正) 彻底完成！"
